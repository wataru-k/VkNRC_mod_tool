# 05. 学習 (損失・勾配集約・オプティマイザ)

対象: `shader/src/nrc_gradient.comp`, `nrc_optimize.comp`, `nrc_train_prepare.comp`, `src/rg/NNTrain.{hpp,cpp}`

## 5.1 教師データはどこから来るか

§02.6 の self-training。学習経路 1 本 (最大 8 頂点) から、各頂点に対する `NRCTrainRecord` が 1 件ずつ作られる。

```cpp
struct NRCTrainRecord {          // 40 B
    PackedNRCInput packed_input; // 16 B: 頂点の識別情報 + 散乱方向
    float bias_r, bias_g, bias_b;    // 12 B: その頂点以降で確定した放射輝度
    float factor_r, factor_g, factor_b; // 12 B: その頂点から終端までの throughput
};
```

パストレーサが `bias` / `factor` を書き、推論パスが終端頂点のキャッシュ値 `predict` を使って

```glsl
bias += factor * predict;   // nrc_inference.comp:68-71
```

と `bias` を上書きする。この時点で `bias` が**その頂点の教師放射輝度**そのものになる。`factor` は勾配シェーダでは読まれない (使い終わったフィールド)。

つまり教師値は「経路後半の実測 + 打ち切り点の自己予測」であり、論文の self-training そのまま。ネットワークの出力が教師の一部に入る形なので、初期は当然バイアスがあり、学習が進むにつれ整合していく。

## 5.2 1 フレームで 4 バッチ、逐次に学習

```
gradients=0 → train_prepare → nrc_gradient (indirect) → nrc_optimize   … batch 0
gradients=0 → train_prepare → nrc_gradient (indirect) → nrc_optimize   … batch 1
gradients=0 → train_prepare → nrc_gradient (indirect) → nrc_optimize   … batch 2
gradients=0 → train_prepare → nrc_gradient (indirect) → nrc_optimize   … batch 3 (+ use_weights 書き出し)
```

`NRCRenderGraph.cpp:57-80` で 4 つの `NNTrain` パスグループが**直列に鎖状に**接続され、各グループが前のグループの `weights` / `optimizer_entries` / `optimizer_state` を入力として受ける。**1 フレームで Adam が 4 ステップ進む**。

`NNTrain::PassGroupBase` の構成 (`src/rg/NNTrain.cpp`):

| パス | 種類 | 役割 |
|---|---|---|
| `clear_pass` | `myvk_rg::BufferFillPass` | `gradients` (fp32 × 20672) をゼロ埋め |
| `NNPreparePass` | compute (1,1,1) | count のクランプ、indirect command 生成、optimizer state の更新 |
| `NNGradient` | compute indirect | forward + backward、dW を atomic 加算 |
| `NNOptimizer` | compute (20672/64,1,1) | Adam + EMA、fp16 重みの書き出し |

学習は 4 バッチが**同じフレーム内で別々のサンプル集合**に対して行われる。パストレーサが `batch = clamp(uint(RNGNext() * 4), 0, 3)` でランダムに振り分けているので、4 バッチは同じ分布からの独立サンプルになる。

バッチが空 (`count == 0`) のときの扱い:
- `nrc_train_prepare.comp:21`: `uCommand = (0,1,1)` → `NNGradient` は 0 workgroup で実質スキップ。
- `nrc_train_prepare.comp:22`: `count > 0` のときだけ `uStep` / `uBeta*_T` / `uAlpha_T` を進める。空バッチで Adam のバイアス補正が狂わないようにしている。
- `nrc_optimize.comp:33-34`: `if (subgroupAll(uBatchTrainCount == 0)) return;` で早期 return。`subgroupAll` で包んでいるのは uniform な値に対する分岐をコンパイラに明示するためで、実質的には全レーン同一。

## 5.3 勾配シェーダ (`nrc_gradient.comp`)

```glsl
if (gl_GlobalInvocationID.x < uBatchTrainCount) {
    NRCTrainRecord r = uBatchTrainRecords[gl_GlobalInvocationID.x];
    NRCInputEncode(UnpackNRCInput(r.packed_input), inputs);
    target = vec3(r.bias_r, r.bias_g, r.bias_b);
}
// (範囲外レーンは inputs = 0, target = 0 のまま MLP を走らせる)
```

推論と同じく **workgroup 全体で MLP を走らせなければならない**ので、バッチ末尾の余剰レーンは `inputs = 0, target = 0` のダミーとして計算に参加する。`predict` は入力 0 に対する出力なので 0 とは限らず、`d_loss = 2 (predict - 0) / (lum² + 0.01)` が実際に勾配として atomic される。

**これは仕様上のノイズになる**。バッチサイズが 128 の倍数でない限り、最大 127 サンプル分の「入力ゼロ → 出力ゼロ」を学習させてしまう。ただし
- 分母 `uBatchTrainCount` で割られるので寄与は 127/16384 以下 (~0.8%)、
- 「入力ゼロなら出力ゼロ」自体は放射輝度キャッシュとしておかしくない教師、

なので実害は小さい。厳密にやるなら `NNLoadDA3_*` の前にレーンマスクで `d_loss = 0` にすればよい。

推論側との差: 勾配側は `vec3 predict = NNOutput3(out_coopmats);` で**クランプしない** (`nrc_gradient.comp:45`)。推論側は `max(..., vec3(0))`。損失関数の中では輝度計算時にだけ `max(predict, vec3(0))` を使い、`predict - target` には生値を使う (`NN_nv.glsl:183-184`)。負の出力に対しても勾配が流れて正方向に押し戻されるので、これは意図的な設計と読める (クランプすると負領域で勾配が消える)。

backward の呼び出し順序と in-place の活性値置換については §04.5 を参照。

## 5.4 損失関数: 相対 L2 輝度損失

`NNLoadDA3_RelativeL2LuminanceLoss` (`NN_nv.glsl:178-196`):

```glsl
float predict_luminance = dot(vec3(0.299, 0.587, 0.114), max(predict, vec3(0)));
vec3 d_loss = 2.0 * loss_scale * (predict - target) / (predict_luminance * predict_luminance + 0.01);
```

対応する損失は
```
L = Σ_c (p_c - t_c)² / (Y(p)² + 0.01),    Y(p) = 輝度
```
の勾配 (分母を定数扱いした近似勾配。厳密には分母の `p` 依存項の微分が抜けている)。

- 論文 Sec. 4 の相対 L2 と同じ発想 (明るい領域の誤差を相対化して、暗部を潰さない)。
- チャンネルごとに `p_c²` で割るのではなく**輝度の 2 乗**で割るので、色相のバランスが崩れにくい。コミット `763b670 "Use Relative L2 Luminance Loss"` で L2 から置き換えられた。
- `+0.01` は暗部での分母の発散を止めるフロア。
- 分母に **target ではなく predict** を使う。これは tiny-cuda-nn の `RelativeL2Luminance` と同じ流儀で、target がスパイク (ファイアフライ) のとき勾配が爆発しないという利点がある。

`LOSS_SCALE` は `Constant.glsl` で **1.0**。オプティマイザ側でも `/ LOSS_SCALE` して割り戻すので、現状は完全に no-op。fp16 勾配のアンダーフロー対策としてスケールを入れる余地を残した形になっているが、dW の集約が subgroup 間から fp32 なので効果は限定的。

## 5.5 勾配の集約

3 段構成 (詳細は §04.4):

1. subgroup 内 32/16 サンプル: fp16 MMA アキュムレータ
2. subgroup 間 (4 or 8 subgroup): shared memory 経由で fp32 加算
3. workgroup 間 (最大 128 workgroup): `atomicAdd(float)` でグローバル `gradients` バッファへ

`gradients` は **fp32 × 20672 = 82.7 KB**。毎バッチ頭で `BufferFillPass` によりゼロ埋めされる。

`VK_EXT_shader_atomic_float` の `shaderBufferFloat32AtomicAdd` が必須なのはこの 3 段目のため (`main.cpp` の feature 有効化)。

平均化はオプティマイザ側で行われる:
```glsl
float gradient = uGradients[gid] / float(uBatchTrainCount) / LOSS_SCALE;
```
つまり実際のバッチサイズ (パディング分を含む 128 の倍数ではなく、クランプ後の `count`) で割る。

## 5.6 オプティマイザ (`nrc_optimize.comp`)

`local_size 64`、`CmdDispatch(20672/64, 1, 1)` = 323 workgroup。**1 スレッド = 1 重み**。

```cpp
struct OptimizerEntry {  // 16 B × 20672 = 330 KB
    vec2 moment;         // Adam の m, v
    float weight;        // fp32 マスター重み
    float ema_weight;    // fp32 EMA 重み
};
struct OptimizerState {  // 20 B (uniform)
    uint  t;
    float beta1_t, beta2_t;   // ADAM_BETA1^t, ADAM_BETA2^t
    float alpha_t, alpha_t_1; // EMA_ALPHA^t, EMA_ALPHA^(t-1)
};
```

### Adam

```glsl
entry.moment = vec2(β1, β2) * entry.moment + (1 - vec2(β1, β2)) * vec2(g, g*g);
vec2 h_moment = entry.moment / (1.0 - vec2(uBeta1_T, uBeta2_T));   // バイアス補正
entry.weight -= LEARNING_RATE * h_moment.x / (sqrt(h_moment.y) + EPSILON);
```

`β1 = 0.9`, `β2 = 0.999`, `lr = 0.002`, `ε = 1e-8`。標準的な Adam。累乗項 `β^t` は `nrc_train_prepare.comp` が毎バッチ CPU 介入なしに GPU 上で乗算更新する (`3532c90 "Use global state for adam optimizer"`)。

- weight decay なし
- 勾配クリッピングなし。代わりに NaN/Inf を 0 に落とす (`nrc_optimize.comp:37-38`)。fp16 forward/backward で inf が出た場合の保険。
- 学習率スケジュールなし (定数)。

### 重みの EMA (`5b7ccc5 "Exponential moving average weights"`)

```glsl
float eta_t = 1.0 - uAlpha_T, eta_t_1 = 1.0 - uAlpha_T_1;
entry.ema_weight = (1.0 - EMA_ALPHA) / eta_t * entry.weight + EMA_ALPHA * eta_t_1 * entry.ema_weight;
```

`α = 0.99`。これは **debias 済み EMA** の漸化式。debias 前の EMA を `s_t` とすると
```
s_t   = α s_{t-1} + (1-α) w_t
ŝ_t   = s_t / (1 - α^t)                  ← 保存されているのはこの ŝ
```
から `η_t = 1 - α^t` を使って `ŝ_t = (1-α)/η_t · w_t + α·η_{t-1}/η_t · ŝ_{t-1}` になる。実装では両辺に `η_t` を掛けた形ではなく、上記の `η_t` 除算と `η_{t-1}` 乗算に分けて書かれている (`/ eta_t` が第 1 項にだけ掛かって第 2 項に掛かっていないのは、`eta_t_1 / eta_t` の分母を第 1 項と共有する式変形…ではなく、**第 2 項が `α·η_{t-1}·ŝ` で `η_t` で割られていない**)。厳密な debias 式は
```
ŝ_t = [(1-α) w_t + α η_{t-1} ŝ_{t-1}] / η_t
```
なので、実装は第 2 項の `/η_t` が抜けている。`t` が大きくなれば `η_t → 1` なので差は消えるが、**学習初期 (数十ステップ) では EMA 重みがわずかに小さめに出る**。1 フレーム 4 ステップなので数フレームで解消する範囲。

EMA 重みは論文には無い追加要素で、tiny-cuda-nn / Instant-NGP 系の実装で使われる安定化手法。ImGui の "Use EMA" チェックボックスで推論に使うかを切り替えられる。

### 2 種類の重みバッファ

| バッファ | 型 | 更新タイミング | 用途 |
|---|---|---|---|
| `m_weights` | fp16 × 20672 | 毎バッチ (4回/フレーム) | 次の `nrc_gradient` の forward/backward |
| `m_use_weights` | fp16 × 20672 | フレーム末 (batch 3 のみ) | 次フレームの `nrc_inference` |
| `optimizer_entries.weight` | fp32 | 毎バッチ | マスター重み (これが真の値) |
| `optimizer_entries.ema_weight` | fp32 | 毎バッチ | EMA |

fp32 マスター重みを持ち、そこから fp16 のコピーを作る典型的な mixed-precision 構成。`m_use_weights` を分離しているのは、**推論パスがフレーム冒頭で走る一方で学習は同フレーム後半に 4 回走る**ため、推論中に重みが書き換わるのを避ける必要があるから。

`WRITE_USE_WEIGHTS` は `#ifdef` でシェーダごと分けられており (`nrc_optimize.comp.u32` と `nrc_optimize_use.comp.u32` を `shader/CMakeLists.txt` で 2 回コンパイル)、`NNOptimizer::Create` の `write_use_weights` フラグで選ばれる (`src/rg/NNTrain.cpp`)。`uUseEMAWeights` は push constant。

## 5.7 初期化と再初期化

`VkNRCState::ResetMLPBuffers()` (`src/VkNRCState.cpp`):

```cpp
std::normal_distribution<float> nd{0.0f, std::sqrt(2.0f / float(kNNWidth))};  // He (Kaiming)
```

- 全 20672 重みを `N(0, sqrt(2/64))` で初期化。出力層 (3×64) も同じ分散。
- `m_weights` と `m_use_weights` に fp16 で、`optimizer_entries.weight` / `.ema_weight` に fp32 で同じ値を書き込む。
- `moment` は 0、`OptimizerState` は `{t=0, beta1_t=1, beta2_t=1, alpha_t=1, alpha_t_1=1}`。

コミット `78fb661 "Kaiming Initialization; Make MLP Work!"` が示すとおり、初期化を He に直したことで初めて学習が回った。ReLU + バイアスなしの構成では初期スケールが臨界的。

ImGui の "Re-Train" ボタンがこれを呼ぶ。"Lock" は `SetTrainProbability(0.0f)` で学習経路の生成を止める (`main.cpp`)。"Train 1-Frame" は 1 フレームだけ lock を外す。

## 5.8 パイプライン設定 (`src/rg/NNTrain.cpp`)

`NNGradient` パス:
- `CmdDispatchIndirect` (workgroup 数は `nrc_train_prepare` が GPU 上で決める)
- `VK_PIPELINE_SHADER_STAGE_CREATE_REQUIRE_FULL_SUBGROUPS_BIT`
- `VkPipelineShaderStageRequiredSubgroupSizeCreateInfo` で実測 subgroupSize を要求
- SPIR-V は `NNGradientShader.cpp` が subgroupSize 16 / 32 で選択、それ以外は `spdlog::error`

`NNOptimizer` パス:
- `CmdDispatch(GetWeightCount() / 64, 1, 1)`。`20672 / 64 = 323` で割り切れる (`64*64*5/64 + 64*3/64 = 320 + 3`)。
- subgroup 要件なし
