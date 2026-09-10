# 01. 全体アーキテクチャ

## 1.1 ディレクトリ構成

```
src/
  main.cpp              エントリポイント。デバイス生成、ImGui パネル、メインループ
  VkNRCState.{hpp,cpp}  NRC の永続状態 (重み / オプティマイザ状態 / 蓄積画像) と定数の一元定義
  Scene.{hpp,cpp}       OBJ ローダ。頂点を [-1,1] 正規化する
  VkScene*.{hpp,cpp}    GPU 側シーン (バッファ / テクスチャ / BLAS / TLAS)
  Camera.{hpp,cpp}      カメラ操作
  rg/                   myvk_rg レンダーグラフのパス定義
    NRCRenderGraph.*      グラフ全体の組み立てとリソース宣言
    VBufferPass.*         Visibility Buffer 生成 (ラスタライズ)
    PathTracerPass.*      パストレース + レコード生成
    NNInference.*         MLP 推論パス
    NNTrain.*             prepare → gradient → optimizer の 3 パス群
    NNDispatch.hpp        count バッファから indirect dispatch を生成する汎用ラッパ
    NNInferenceShader.*   subgroupSize に応じた SPIR-V の選択
    NNGradientShader.*    同上 (gradient 側)
    ScreenPass.*          蓄積 + トーンマップ + 画面出力
    {NRC,Scene}Resources.hpp リソースハンドルの受け渡し構造体

shader/src/
  vbuffer.{vert,frag}   V-Buffer
  path_tracer.comp      パストレーサ
  nrc_inference.comp    MLP 推論
  nrc_gradient.comp     MLP forward + backward (勾配計算)
  nrc_optimize.comp     Adam + EMA による重み更新
  nrc_train_prepare.comp 学習カウントのクランプ、indirect cmd 生成、オプティマイザ状態の更新
  nrc_indirect.comp     count → dispatch サイズの変換のみ
  screen.{vert,frag}    蓄積 / トーンマップ
  NN_nv.glsl            Fully-Fused MLP 本体 (cooperative matrix)
  NRCRecord.glsl        レコード構造体とエンコーディング
  Constant.glsl         シェーダ側の定数
  Scene.glsl / CookTorranceBRDF.glsl / LambertBRDF.glsl / Sample.glsl / RNG.glsl

test/                   MLP 単体の検証用 (Eigen で CPU リファレンス実装 + vuda)
```

`test/` は CMake から外されている (`CMakeLists.txt:29` でコメントアウト)。`test/main.cpp` は Eigen による CPU 版 forward / backward を持ち、GPU カーネルの数値を突き合わせるための検証コード。`test/mlp_learning_an_image/` は tiny-cuda-nn の同名サンプルの移植で、MLP 単体の学習が回るかを見るためのもの。

## 1.2 デバイス要件 (`src/main.cpp:30-73`)

物理デバイスの選択は「`VK_NV_cooperative_matrix` をサポートする最初のデバイス」(`main.cpp:30-39`)。無ければエラー終了。

有効化する機能:

| 機能 | 用途 |
|---|---|
| `VK_NV_cooperative_matrix` | Fully-Fused MLP の MMA |
| `VK_KHR_ray_query` + `VK_KHR_acceleration_structure` | compute shader からのレイトレース |
| `VK_EXT_shader_atomic_float` (`shaderBufferFloat32AtomicAdd`) | 勾配バッファへの fp32 atomic 加算 |
| `vk11.storageBuffer16BitAccess`, `vk12.shaderFloat16` | fp16 重み / 活性値 |
| `vk12.vulkanMemoryModel` + `DeviceScope` | `gl_ScopeQueueFamily` 付き atomic / memory semantics |
| `vk13.subgroupSizeControl`, `vk13.computeFullSubgroups` | subgroup サイズを固定して MLP のタイル分割を成立させる |
| `vk12.bufferDeviceAddress`, `vk12.hostQueryReset` | AS ビルド等 |

コマンドライン引数に OBJ ファイルを1つ渡す。ウィンドウは 1280×720、`kFrameCount = 3` でレンダーグラフを 3 つ作り、フレームごとに切り替える (`main.cpp:89-91`)。

## 1.3 レンダーグラフ

`rg::NRCRenderGraph` のコンストラクタ (`src/rg/NRCRenderGraph.cpp:23-98`) がグラフ全体を宣言する。myvk_rg は「パスの入出力エイリアスを繋ぐと依存とバリアが自動導出される」形のレンダーグラフライブラリ。

```
                    ┌──────────────┐
                    │ vbuffer_pass │  ラスタライズ: (primitive_id, instance_id) の R32G32_UINT
                    └──────┬───────┘
                           v
                    ┌──────────────────┐
                    │ path_tracer_pass │  1次ヒットから経路を追跡
                    └──────┬───────────┘  出力: bias_factor_r (RGBA32F), factor_gb (RG32F),
                           │              eval_count, eval_records, batch_train_{count,records}[4]
                           v
                    ┌──────────────────────────────┐
                    │ nn_inference_pass            │  NNDispatch<NNInference>
                    │  ├ gen_pass  (indirect cmd)  │  eval_records を全件 MLP 推論
                    │  └ pass      (推論本体)      │  → 画面 or 学習レコードへ加算
                    └──────┬───────────────────────┘
                           │
        ┌──────────────────┴──────────────────┐
        v                                     v
┌──────────────────────┐              ┌─────────────┐
│ nn_train_pass 0..3   │              │ screen_pass │  蓄積 + トーンマップ
│  ├ clear_pass        │  勾配 0 埋め  └──────┬──────┘
│  ├ prepare_pass      │  count clamp,       v
│  ├ gradient_pass     │  fwd+bwd     ┌────────────┐
│  └ optimizer_pass    │  Adam + EMA  │ imgui_pass │ → present
└──────────────────────┘              └────────────┘
```

学習パスは 4 個 (`kTrainBatchCount`) を**直列に鎖状に**繋ぐ (`NRCRenderGraph.cpp:57-80`)。バッチ `b` のパスは、`b-1` のパスが出力した weights / optimizer_entries / optimizer_state を入力に取る。つまり 1 フレームで 4 回の勾配ステップが順番に実行される。最後のバッチ (`b == 3`) だけが `use_weights` (= レンダラが次フレームで使う重み) を書き出す (`NRCRenderGraph.cpp:66-68`)。

グラフ末端の `AddResult` (`NRCRenderGraph.cpp:93-97`) が weights / use_weights / optimizer_entries / optimizer_state を外部リソースへの書き戻しとして宣言し、これによって永続バッファ (`VkNRCState` 所有) が次フレームへ引き継がれる。

## 1.4 リソース一覧

### 永続リソース (`VkNRCState` が所有、`src/VkNRCState.cpp:46-88`)

| 名前 | 型 / サイズ | 内容 |
|---|---|---|
| `m_weights` | fp16 × 20672 = 41,344 B | 学習中の重み (Adam 出力そのまま) |
| `m_use_weights` | fp16 × 20672 | レンダラが推論に使う重み。EMA or 生の重みを選択 |
| `m_optimizer_state` | 20 B | `{uint t, float beta1_t, beta2_t, alpha_t, alpha_t_1}` |
| `m_optimizer_entries` | 16 B × 20672 = 330,752 B | 重みごとの `{float m, v, weight, ema_weight}` (fp32 マスタ重み) |
| `m_accumulate_view` | RGBA32F, 画面サイズ | プログレッシブ蓄積用 |

重みは fp32 で He (Kaiming) 初期化 `N(0, sqrt(2/64))` され (`VkNRCState.cpp:39-44`)、fp16 版と fp32 マスタ版 (`optimizer_entries.weight` / `.ema_weight`) の両方に書かれる。バイアス項は存在しない。

### フレーム内リソース (`NRCRenderGraph::create_nrc_resources`, `NRCRenderGraph.cpp:139-175`)

| 名前 | サイズ | 内容 |
|---|---|---|
| `eval_records` | `(W*H + 16384*4) × 16 B` | 推論すべきクエリのリスト。画面用 + 学習用の最大数を確保 |
| `eval_count` | 4 B (host mapped) | 上のカウンタ。CPU から毎フレーム 0 クリア |
| `batch_train_records[4]` | `16384 × 40 B` 各 | 学習サンプル (bias/factor/入力) |
| `batch_train_count[4]` | 4 B 各 (host mapped) | 上のカウンタ。CPU から毎フレーム 0 クリア |
| `gradients` (train パス内) | fp32 × 20672 | 勾配。各バッチの先頭で `BufferFillPass` により 0 埋め |
| `bias_factor_r` | RGBA32F | `rgb` = キャッシュ以前に確定した放射輝度、`a` = throughput の R |
| `factor_gb` | RG32F | throughput の G, B |
| `v_buffer` | R32G32_UINT | `(primitive_id, instance_id)`。クリア値は `(-1,-1)` |
| `depth` | D24_UNORM_S8_UINT | V-Buffer 用 |

`eval_count` / `batch_train_count` は host-mapped で、`PreExecute()` (`NRCRenderGraph.cpp:100-113`) で CPU が直接 0 を書き込む。GPU 側の追加クリアパスは無い。

### レコード構造体 (`src/VkNRCState.cpp:12-31` / `shader/src/NRCRecord.glsl:6-38`)

```cpp
struct PackedNRCInput {          // 16 B
    uint32_t primitive_id;
    uint32_t flip_bit_instance_id;   // bit31 = 法線反転フラグ, bit0-30 = instance_id
    uint32_t barycentric_2x16U;      // packUnorm2x16
    uint32_t scattered_dir_2x16U;    // 球面座標を packUnorm2x16
};
struct NRCEvalRecord {           // 16 B
    uint32_t dst;                    // 出力先のエンコード (後述)
    PackedNRCInput packed_input;
};
struct NRCTrainRecord {          // 40 B
    float bias_r, bias_g, bias_b;    // キャッシュ寄与を除いた既知放射輝度
    float factor_r, factor_g, factor_b; // キャッシュ推論値に掛ける throughput
    PackedNRCInput packed_input;
};
```

CPU 側 (`VkNRCState.cpp`) と GLSL 側 (`NRCRecord.glsl`) の構造体定義が二重管理になっている。CPU 側はバッファサイズ計算にしか使われないが、レイアウトがずれると壊れる箇所。

## 1.5 1フレームの実行フロー

`main.cpp:99-173` のメインループと、そこから呼ばれるレンダーグラフの実行。

1. **CPU**: ImGui パネル処理、カメラ操作。カメラが動いたら蓄積カウントをリセット。`nrc_lock` なら `train_probability = 0` に落とす (`main.cpp:155-158`)。
2. **CPU (`PreExecute`)**: TLAS / 永続バッファのハンドルを差し替え。インスタンス変換行列を mapped バッファに書く。`eval_count` と `batch_train_count[0..3]` を 0 にする。
3. **vbuffer_pass**: シーン全インスタンスをラスタライズし、`(primitive_id, instance_id)` を書く。primitive_id は `gl_PrimitiveID + primitive_base` (インスタンスごとの push constant)。
4. **path_tracer_pass**: 8×8 workgroup で全画素をディスパッチ。V-Buffer から1次ヒットを復元 → 経路追跡 → `eval_records` / `batch_train_records` を atomic で積む。`bias_factor_r` / `factor_gb` を書く。
5. **nn_inference_pass**: `eval_count` から indirect dispatch サイズ (`(count+127)/128`) を作り、`eval_records` を 128 件/workgroup で MLP 推論。結果を `dst` に従って画面画像に加算するか、学習レコードの `bias` に加算する。
6. **nn_train_pass 0..3** (直列):
   - `clear_pass`: 勾配バッファを 0 埋め。
   - `prepare_pass`: `count = min(count, 16384)` にクランプ、indirect cmd を生成、`count > 0` なら Adam の `t` / `beta^t` / EMA の `alpha^t` を進める。
   - `gradient_pass`: forward + backward を融合実行。dW を fp32 atomic add で `gradients` に集約。
   - `optimizer_pass`: 20672 個の重みを 64 スレッド/workgroup × 323 workgroup で Adam 更新 + EMA 更新。最終バッチのみ `use_weights` も書く。
7. **screen_pass**: `bias_factor_r` を input attachment として読み、蓄積とトーンマップ (Hejl 2015) + ガンマ 2.2 を適用してスワップチェインへ。
8. **imgui_pass** → present。
9. **CPU**: `NextFrame()` で蓄積カウントを進め、`m_seed` を更新。

推論パスと学習パスは、どちらも `batch_train_records` に依存関係を持つため、グラフ上では inference → train の順序が保証される。一方 `screen_pass` は inference の出力画像にのみ依存するので、train パスとは並列に走り得る。
