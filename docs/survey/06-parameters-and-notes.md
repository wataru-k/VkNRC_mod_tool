# 06. パラメータ一覧・論文との差異・実装上の論点

## 6.1 ハイパーパラメータ全表

### ネットワーク

| 項目 | 値 | 定義場所 |
|---|---|---|
| 入力次元 | 64 | `NRCRecord.glsl` (`NRCInputEncode`) / `NN_nv.glsl` `FP_X` |
| 隠れ層数 | 5 | `Constant.glsl` `NRC_HIDDEN_LAYERS`, `VkNRCState.hpp` `kNNHiddenLayers` |
| 隠れ層幅 | 64 | `VkNRCState.hpp` `kNNWidth` |
| 出力次元 | 3 | `VkNRCState.hpp` `kNNOutWidth` |
| 活性化関数 | ReLU (出力層は線形、推論時のみ `max(・,0)`) | `NN_nv.glsl` |
| バイアス項 | **なし** (入力末尾の定数 1 が 2 本のみ) | `NRCRecord.glsl:93-94` |
| 重み総数 | 64·64·5 + 64·3 = **20,672** | `VkNRCState.hpp` `kNNWeighCount` |
| 初期化 | He / Kaiming `N(0, sqrt(2/64))` | `VkNRCState.cpp` |
| 精度 | forward/backward fp16、マスター重み fp32、dW 集約 fp32 | — |

### 学習

| 項目 | 値 | 定義場所 |
|---|---|---|
| 学習率 | 0.002 (定数、スケジュールなし) | `nrc_optimize.comp:10` |
| オプティマイザ | Adam (β1=0.9, β2=0.999, ε=1e-8, weight decay なし) | `Constant.glsl`, `nrc_optimize.comp` |
| 損失 | 相対 L2 輝度損失 (分母 `Y(predict)² + 0.01`) | `NN_nv.glsl:178-196` |
| `LOSS_SCALE` | 1.0 (実質 no-op) | `Constant.glsl:8` |
| 重み EMA | α = 0.99、debias 付き | `Constant.glsl:13`, `nrc_optimize.comp:46-47` |
| バッチサイズ | 16384 | `Constant.glsl:7`, `VkNRCState.hpp` `kTrainBatchSize` |
| 1 フレームのバッチ数 | 4 (直列 = Adam 4 ステップ/フレーム) | `Constant.glsl:6` |
| 学習経路の生成確率 | 0.03 (subgroup 単位) | `VkNRCState.hpp` `kDefaultTrainProbability` |

### パストレース

| 項目 | 値 | 定義場所 |
|---|---|---|
| 最大バウンス | 8 | `path_tracer.comp:11` |
| 面積ヒューリスティック `C` | 0.01 | `path_tracer.comp:14` |
| `T_MIN` / `T_MAX` | 1e-6 / 4.0 | `path_tracer.comp:12-13` |
| BRDF | Cook-Torrance (Beckmann + Walter G1 + Schlick) | `CookTorranceBRDF.glsl` |
| 環境光 | 定数 `vec3(10)` | `path_tracer.comp:142` |
| MIS / NEE | **なし** (BRDF サンプリングのみ) | — |
| ロシアンルーレット | **なし** | — |
| トーンマップ | Hejl 2015 filmic (exposure 3.2) + gamma 2.2 | `screen.frag` |

### 実行環境

| 項目 | 値 | 定義場所 |
|---|---|---|
| MLP workgroup | 128 (固定、`#error` で強制) | `NN_nv.glsl:12` |
| 対応 subgroupSize | 16 / 32 (64 は無効化) | `shader/CMakeLists.txt` |
| 解像度 | 1280×720 | `main.cpp` `kWidth/kHeight` |
| フレームバッファ数 | 3 | `main.cpp` `kFrameCount` |
| 物理デバイス選択 | `VK_NV_cooperative_matrix` を持つ最初のデバイス | `main.cpp` |

### メモリ (1280×720、フレームリソースは 3 重)

| リソース | サイズ | 永続 |
|---|---|---|
| `m_weights` / `m_use_weights` | 41 KB × 2 | ○ |
| `m_optimizer_entries` | 16 B × 20672 = 331 KB | ○ |
| `m_optimizer_state` | 20 B | ○ |
| `m_accumulate_view` (RGBA32F) | 14.7 MB | ○ |
| `eval_records` | (921600 + 65536) × 16 B = 15.8 MB | フレーム毎 |
| `batch_train_records[4]` | 16384 × 40 B × 4 = 2.6 MB | フレーム毎 |
| `gradients` (fp32) | 82.7 KB | フレーム毎 |
| `v_buffer` (R32G32_UINT) | 7.4 MB | フレーム毎 |
| `bias_factor_r` (RGBA32F) + `factor_gb` (RG32F) | 14.7 + 7.4 MB | フレーム毎 |

## 6.2 論文との差異

| 項目 | 論文 (Müller et al. 2021) | 本実装 |
|---|---|---|
| 実装基盤 | CUDA (tiny-cuda-nn) | GLSL + `VK_NV_cooperative_matrix` |
| MMA アキュムレータ | fp32 | **fp16** |
| 位置エンコーディング | 正弦波 (multi-resolution) | **三角波** (`_nrc_tri`) — `sin` 回避の高速化 |
| One-Blob カーネル | ガウシアン | **四次カーネル (quartic)** — `exp` 回避 |
| 相対 L2 損失 | チャンネルごとの相対化 | **輝度 (Rec.601) で相対化** |
| 重み EMA | なし | **あり** (α=0.99、切り替え可) |
| 学習経路の抽出 | 画素単位の確率抽出 | **subgroup 単位** (発散回避) |
| 経路延長 | 学習経路を延長 | 面積予算をもう 1 回分使う実装 |
| 自己学習の教師 | 経路末端でキャッシュ推論 | 同じ (`bias += factor * predict`) |
| MIS / NEE | あり (光源サンプリング) | **なし** (BRDF サンプリングのみ、環境光は定数) |
| キャッシュのフレーム間再利用 | あり | 重みは持続するが空間データ構造は持たない (MLP のみ) |
| 時間的フィルタ / デノイズ | あり | **なし** (progressive accumulation のみ) |

論文と比べると、**ネットワークと学習ループは忠実、レンダリング側は簡略化**という切り分けになっている。NRC 部分の再現が目的で、プロダクションのパストレーサを作るのが目的ではないという設計判断が明確。

## 6.3 実装上の論点・気付いた点

### 設計として巧いところ

1. **`_nn_act_64_relu_mask_t` の NaN トリック** (§04.4)。MMA のアキュムレータ初期値に「ReLU の微分マスク」を NaN として埋め込み、MMA 後に `isnan → 0` で解決する。ゼロ初期化パスと ReLU 微分パスを 1 パスに融合しており、fully-fused backward の要になっている。
2. **row-major 重み / column-major 活性値の組み合わせ** で、forward (`W·A`) と backward (`dA^T·W`) の両方で**同じ重みブロックを転置せずに使える**。coopmat に転置命令がないので、これが効く。
3. **`PackedNRCInput` 16 B** に頂点 ID + バリセントリック + 散乱方向だけを詰め、位置 / 法線 / アルベドは推論時にシーンから引き直す。レコードバッファの帯域を 1/3 以下に削っている (16 B vs 位置3+法線2+rough1+albedo6 を float で持つと 48 B)。
4. **bias / factor 分解** で、パストレーサがキャッシュ推論の完了を待たずに済む。推論パスは 1 回の read-modify-write で画面と学習レコードの両方に結果を配れる。
5. **1 経路まとめて 1 バッチに atomic 予約** (`atomicAdd(count, bounce)`)。経路内の全頂点が連続スロットに入るので、終端キャッシュ値を `[l,r]` の範囲エンコード 1 つで全頂点に配れる。
6. **subgroup 単位の学習経路抽出**。学習経路は通常経路よりレジスタ消費もループ構造も大きく違うので、画素単位で混ぜると発散コストが重い。

### 注意点・改善余地

1. **fp16 アキュムレータ**。64 項の内積を fp16 で累積するので、tiny-cuda-nn (fp32 アキュムレータ) より精度が低い。He 初期化と入力の `[0,1]` 正規化が前提で成立している。`nrc_optimize.comp` が NaN/Inf を 0 に落としているのは、この構成で inf が実際に発生し得るという認識の表れと読める。
2. **勾配シェーダのパディングレーンが学習に混入する** (§05.3)。バッチ末尾の最大 127 レーンが `inputs=0, target=0` として実際に勾配を出す。寄与は 0.8% 以下だが、`NNLoadDA3_*` の前にレーンマスクを入れれば消せる。
3. **EMA の debias 式の第 2 項に `/η_t` が抜けている** (§05.6)。`t` が小さいうちは EMA 重みがやや小さめに出る。1 フレーム 4 ステップなので数フレームで解消する。
4. **`LOSS_SCALE = 1.0` で loss scaling が無効**。fp16 勾配のアンダーフロー対策の仕組みは入っているが使われていない。dW 集約が subgroup 間から fp32 なので効果は限定的という判断だと思われる。
5. **画面分割の境界 subgroup が未定義値になる** (§02.2)。`subgroupAll(...)` で手法を分岐しているため、左右の手法が混在する 1 subgroup 幅だけどちらの分岐も実行されない。比較 UI としては実害なしと割り切られている。
6. **`EncodeNRCEvalDstTrain` の 14 bit が `NRC_TRAIN_BATCH_SIZE = 16384` にハードコード結合**。`Constant.glsl` の定数を変えてもビット幅は追随しないので、バッチサイズを変えるならエンコーダも直す必要がある (同様に batch は 2 bit = 4 バッチ固定)。
7. **`factor` が使われずに捨てられる経路がある** (§02.4)。環境光ミスで終端した場合、`factor` は 0 でないまま書かれるが推論クエリが立たないので使われない。挙動は正しいが読み手を混乱させる。
8. **`nrc_gradient.comp` の `predict` はクランプしない一方、`nrc_inference.comp` は `max(・,0)` する**。損失の分母だけ `max(predict,0)` を使う。負出力に勾配を流して押し戻すためで意図的と読めるが、コメントがないので意図が読み取りづらい。
9. **`PathTracerPass` の binding 10, 11 が空き**。以前あったリソースの削除跡。
10. **CPU / GLSL で構造体定義が二重管理**。`VkNRCState.cpp` の `nrc::PackedNRCInput` / `NRCEvalRecord` / `NRCTrainRecord` / `OptimizerEntry` / `OptimizerState` と `NRCRecord.glsl` / `nrc_optimize.comp` の定義が手動で一致させられている。サイズ不一致は静かに壊れる。
11. **subgroupSize=64 未対応** (`5a783e0`: "compile error on windows glslc. Idk why")。AMD (wave64) では動かない。もっとも `VK_NV_cooperative_matrix` 自体が NVIDIA 専用なので実害はない。
12. **subgroupSize=16 の勾配シェーダは shared memory が 64 KB になり上限超過** (§04.2)。NVIDIA は 32 なので実行時には選ばれず、コンパイルは通るが動かないパスが残っている。
13. **`test/` が `CMakeLists.txt` でコメントアウトされている**。`test/main.cpp` の Eigen CPU リファレンス実装 (forward/backward の検証用) と `test/mlp_learning_an_image/` (tiny-cuda-nn サンプルの移植) はビルド対象外。GPU カーネルの回帰テストとして残しておく価値はある。
14. **レジスタ圧が高い** (§04.5)。`nrc_gradient.comp` は 6 層分の活性値をレジスタに常駐させ、subgroupSize=32 で 1 レーン 192 レジスタ相当。occupancy は 1〜2 warp/SM 程度に落ちるはずで、スピルの有無は要プロファイル。

## 6.4 ファイルマップ

### ホスト側 (`src/`)

| ファイル | 役割 |
|---|---|
| `main.cpp` | 初期化、物理デバイス選択、ImGui UI、メインループ |
| `VkNRCState.{hpp,cpp}` | NRC の全定数、重み / オプティマイザバッファ、He 初期化、UI 状態 |
| `Scene.{hpp,cpp}` | glTF/OBJ ロード、AABB 正規化 (`Scene.cpp:33-41`) |
| `VkScene.{hpp,cpp}` | シーンデータの GPU バッファ / テクスチャ化 |
| `VkSceneBLAS.{hpp,cpp}` / `VkSceneTLAS.{hpp,cpp}` | 加速構造の構築 |
| `AABB.hpp` | AABB ユーティリティ |
| `Camera.{hpp,cpp}` | カメラ操作、push constant データ生成 |
| `rg/NRCRenderGraph.{hpp,cpp}` | レンダーグラフ全体の組み立て、フレーム頭のカウンタゼロ化 |
| `rg/NRCResources.hpp` | フレームリソースの型と生成 |
| `rg/VBufferPass.{hpp,cpp}` | V-Buffer ラスタライズ |
| `rg/PathTracerPass.{hpp,cpp}` | パストレース compute パス |
| `rg/NNInference.{hpp,cpp}` | 推論パス (indirect dispatch) |
| `rg/NNInferenceShader.cpp` | subgroupSize 別 SPIR-V の選択 |
| `rg/NNTrain.{hpp,cpp}` | clear / prepare / gradient / optimizer の 4 パス群 |
| `rg/NNGradientShader.cpp` | subgroupSize 別 SPIR-V の選択 |
| `rg/NNDispatch.hpp` | 汎用の「カウンタ → indirect command」パスラッパ |
| `rg/ScreenPass.{hpp,cpp}` | 累積 + トーンマップ |
| `rg/SceneResources.hpp` | シーン側リソースのディスクリプタ束 |

### シェーダ (`shader/src/`)

| ファイル | 役割 |
|---|---|
| `NN_nv.glsl` | **Fully-Fused MLP 本体** (forward / backward / dW) |
| `NRCRecord.glsl` | レコード構造体、入力エンコーディング、`dst` ビットパッキング、シーンからのアンパック |
| `Constant.glsl` | 共通定数 (層数・バッチ・Adam・EMA) |
| `path_tracer.comp` | パストレース、経路終端、self-training |
| `nrc_inference.comp` | 推論 (画面 / 学習レコードへの書き戻し) |
| `nrc_gradient.comp` | forward + backward + dW atomic |
| `nrc_optimize.comp` | Adam + EMA + fp16 書き出し (`WRITE_USE_WEIGHTS` 版と 2 種) |
| `nrc_train_prepare.comp` | count クランプ、indirect command、optimizer state 更新 |
| `nrc_indirect.comp` | 汎用 count → indirect command |
| `vbuffer.{vert,frag}` | V-Buffer 出力 |
| `screen.{vert,frag}` | 累積 + Hejl 2015 トーンマップ |
| `Scene.glsl` | シーンバッファアクセサ |
| `CookTorranceBRDF.glsl` | BRDF 評価とサンプリング (実際に使われる方) |
| `LambertBRDF.glsl` | Lambert BRDF (現在 `path_tracer.comp` からは未参照) |
| `Sample.glsl` | 半球 / GGX サンプリング補助 |
| `RNG.glsl` | PCG |

### 依存 (`dep/`)

`MyVK` (自作 Vulkan ラッパ + render graph)、`glm`、`imgui`、`spdlog`、`half`、`assimp` 系。

## 6.5 参考コミット

実装の意思決定が読み取れるコミット:

| コミット | 内容 |
|---|---|
| `78fb661` | Kaiming Initialization; Make MLP Work! ← これで初めて学習が回った |
| `763b670` | Use Relative L2 Luminance Loss; Use Faster Encoding Methods (sin→三角波、gauss→quartic) |
| `fd760d8` | Split Base and Extra components in Radiance (bias/factor 分解の導入) |
| `8a3226c` | Enable inference pass to write to train records |
| `47f4ab5` | Better Inference Record Encoding (16 B パック + シーン再引き) |
| `5b7ccc5` | Exponential moving average weights |
| `3532c90` | Use global state for adam optimizer (β^t を GPU 上で更新) |
| `874e1a9` | fix subgroup glitches |
| `5a783e0` | Remove support for warpSize=64 due to compile error on windows glslc |
| `36aa4f3` / `48c8e46` | Runnable NRC / NRC Done |
| `e3cafe6` | Choose optimal physical device |
| `1687ff2` | Fix the Runtime crash for MSVC |
