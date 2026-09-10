# 04. Fully-Fused MLP (`NN_nv.glsl`)

対象: `shader/src/NN_nv.glsl` (325 行)、利用側は `nrc_inference.comp` / `nrc_gradient.comp`

このファイルが本実装の中核であり、tiny-cuda-nn の fully-fused MLP を GLSL + `VK_NV_cooperative_matrix` で書き直したものに相当する。**forward だけでなく backward も完全に融合**されており、中間活性値を一度もグローバルメモリへ出さない。

## 4.1 なぜ NV 拡張なのか

`GL_NV_cooperative_matrix` (`fcoopmatNV<16, gl_ScopeSubgroup, 16, 16>`) を使っている。KHR 版 (`GL_KHR_cooperative_matrix`) ではなく NV 版なのは、README に「KHR は制限が強すぎる」と書かれている通り、以下が必要だから:

- **fp16 アキュムレータ** (`fcoopmatNV<16, ...>` = 16bit 要素の A/B/C 全部)。KHR は `gl_MatrixUseA/B/Accumulator` の組み合わせに制約があり、A/B/C を自由に入れ替えられない。
- **同じ型を A としても B としても使う**。本実装は `coopMatMulAddNV(weight, act, dst)` と `coopMatMulAddNV(da_t, weight, dst)` のように、同じ 16×16 型をオペランドの左右どちらにも置く。
- **要素への直接添字アクセス** `coopmats[x][y][k]`。ReLU とその微分マスクを行列要素ごとに操作するために必須。

`fcoopmatNV<16, gl_ScopeSubgroup, 16, 16>` = 要素 16bit、スコープ subgroup、16×16。MMA は 16×16×16 の 1 単位だけを使い、それをタイル状に並べて 64×64 や 64×128 を作る。

## 4.2 タイル構成

workgroup は **128 スレッド固定** (`NN_nv.glsl:12-14` で `#error`)。1 workgroup が 128 サンプル分を一括処理する。

| マクロ | 値 | 意味 |
|---|---|---|
| `FP_X` | 64 | 特徴次元 (= 隠れ層幅) |
| `ACT_Y` | 128 | サンプル数 = workgroup サイズ |
| `UV4_X` | 8 | 64 fp16 = 8 uvec4 |
| `COOPMAT_X` | 4 | 64 / 16 |
| `ACT_COOPMAT_Y` | 8 | 128 / 16 |
| `SUBGROUP_COUNT` | 4 (sg=32) / 8 (sg=16) | 128 / SUBGROUP_SIZE |
| `SUBGROUP_ACT_COOPMAT_Y` | 2 (sg=32) / 1 (sg=16) | 各 subgroup が持つ活性行列の列ブロック数 |
| `THREAD_WEIGHT_64_UV4_COUNT` | 4 | 512 uvec4 / 128 スレッド |

活性行列 `A` は 64 (特徴) × 128 (サンプル)。これを 16×16 ブロックに切ると 4×8 = 32 ブロック。**subgroup 数で列方向に分割**するので、subgroupSize=32 なら 1 subgroup が 4×2 = 8 ブロック (= 32 サンプル分)、subgroupSize=16 なら 4×1 = 4 ブロック (= 16 サンプル分) をレジスタに保持する。

```
A (64 x 128), 16x16 ブロック
        サンプル →
  特徴  [0][0] [1][0] ... [7][0]   ← subgroup 0 (sg=32 なら y=0,1)
   ↓    [0][1] [1][1] ... [7][1]   ← subgroup 1
        [0][2] ...                 ← subgroup 2
        [0][3] ...                 ← subgroup 3
```

コードでの添字は `act_coopmats[x][y]`、`x` = 特徴方向 (0..3)、`y` = subgroup 内のサンプル方向 (0..SUBGROUP_ACT_COOPMAT_Y-1)。workgroup 内の絶対列ブロックは `gl_SubgroupID * SUBGROUP_ACT_COOPMAT_Y + y`。

### レイアウトの取り方 (`NN_nv.glsl:54-58`)

```glsl
#define MAT64_COOPMAT_STRIDE UV4_X                        // 8 uvec4 = 64 fp16
#define MAT64_COOPMAT_ELEMENT(X, Y) ((X)*2 + (Y)*16*8)
#define WEIGHT_COOPMAT_MAJOR false   // row-major
#define ACT_COOPMAT_MAJOR  true      // column-major
#define COOPMAT_MAJOR_T(x) (!(x))
```

shared memory 上のバッファは「幅 64 fp16 の 2 次元配列」として一元的に扱われる。重みは row-major (1 行 = 出力ニューロン 1 個の 64 入力重み)、活性値は column-major (1 列 = サンプル 1 個の 64 特徴) なので、**どちらも「連続 64 fp16 が 1 単位」で同じ stride 8 uvec4 が使える**。`MAT64_COOPMAT_ELEMENT(X,Y)` の `X*2` は連続方向に 16 fp16 (= 2 uvec4) 進む分、`Y*128` は 16 行分進む分。

転置が必要な場所では major フラグを反転させるだけ (`COOPMAT_MAJOR_T`) で、実際の転置命令は使わない。

### shared memory は 1 本を使い回す (`NN_nv.glsl:60-67`)

```glsl
shared uvec4 SHARED_BUFFER[SHARED_BUFFER_SIZE];
```

同じ配列が (a) 層の重みのステージング、(b) 活性値の coopmat ↔ スレッド間の受け渡し、(c) backward の subgroup 間 dW リダクション、の 3 用途に使い回される。用途の切り替えは全部 `barrier()` で区切られている。

サイズは:
- 推論 (`NN_BACKPROPAGATION` なし): `max(512, 1024)` = **1024 uvec4 = 16 KB**
- 勾配: `max(512 * SUBGROUP_COUNT, 1024)`
  - subgroupSize=32 → 2048 uvec4 = **32 KB**
  - subgroupSize=16 → 4096 uvec4 = **64 KB** ← NVIDIA の `maxComputeSharedMemorySize` (通常 49152) を超える

subgroupSize=16 の勾配シェーダは shared memory 上限を超える可能性が高いが、NVIDIA の subgroupSize は 32 なので実行時には選ばれない (`NNGradientShader.cpp` は実測 subgroupSize で SPIR-V を選ぶ)。

## 4.3 forward

### 重みのロード

```glsl
void _nn_load_weight_64(in const uint layer) {   // 64x64 層
    // 128 スレッド × 4 uvec4 = 512 uvec4 を一斉コピー
    SHARED_BUFFER[tid*4 + i] = uWeights[layer*512 + tid*4 + i];
    barrier();
}
void _nn_load_weight_3(in const uint layer) {    // 3x64 出力層
    SHARED_BUFFER[tid] = tid < 24 ? uWeights[layer*512 + tid] : uvec4(0);
    barrier();
}
```

重みバッファ内のオフセットが常に `layer * WEIGHT_64_UV4_COUNT` である点に注意。出力層 (layer 5) も 512 uvec4 のスロットの先頭 24 uvec4 だけを使う…**わけではなく**、`kNNWeighCount = 64*64*5 + 64*3 = 20672` なので出力層は詰めて配置されている。`layer=5` のとき `5*512 = 2560 uvec4 = 20480 fp16` が出力層の開始位置で、そこから 192 fp16 (24 uvec4) がちょうど末尾に収まる。余白はない。

`_nn_load_weight_3` が 24 以上のスレッドで 0 を書くのは、16×16 の coopmat をロードするときに 3 行目以降 (パディング) を確実にゼロにするため。

### 入力ロード (`NNLoadInput`, `NN_nv.glsl:84-97`)

各スレッドが自分のサンプルの `uvec4[8]` (= 64 fp16) を `SHARED_BUFFER[tid*8 + x]` に書き、barrier 後に column-major で coopmat にロードする。これで「スレッド ↔ サンプル」の対応が「coopmat ↔ 列ブロック」に変換される。

### 隠れ層 (`NNForward64_ReLU`, `NN_nv.glsl:99-127`)

```glsl
for (w_y = 0..3)            // 出力特徴ブロック
  for (x = 0..3) {          // 入力特徴ブロック (縮約方向)
    load weight_coopmat = W[w_y][x];          // row-major
    for (a_y = 0..S-1)                        // サンプルブロック
      dst[w_y][a_y] = coopMatMulAddNV(weight_coopmat, src[x][a_y], dst[w_y][a_y]);
  }
barrier();
// ReLU
dst[x][y][k] = max(dst[x][y][k], 0);
```

重み行列ブロックを 1 回ロードして、そのブロックが関わる全サンプルブロックに対して MMA を回す (レジスタ再利用)。subgroupSize=32 なら 4×4×2 = **32 MMA / subgroup / 層**。

ReLU は MMA 結果のレジスタ上で要素ごとに適用される。活性値がグローバルメモリにも shared memory にも出ないのが「fully-fused」の意味。

**アキュムレータが fp16** である点は注意が必要。64 項の内積を fp16 で累積するので、tiny-cuda-nn (fp16 入力 / fp32 アキュムレータ) より精度は低い。He 初期化 + 入力が `[0,1]` 前後に正規化されている前提で成立している。

### 出力層 (`NNForward3` + `NNOutput3`, `NN_nv.glsl:129-158`)

`NNForward3` は縮約 4 ブロック × サンプルブロック分の MMA を回して 16×16 の結果を 1 本作る (有効な行は 0..2 のみ)。`NNOutput3` はそれを column-major で shared memory に書き戻し、各スレッドが自分のサンプルの先頭 uvec4 から `unpackHalf2x16` で RGB 3 成分を取り出す。

```glsl
uvec2 uv2 = SHARED_BUFFER[gl_LocalInvocationID.x * UV4_X].rg;
return vec3(unpackHalf2x16(uv2.x), unpackHalf2x16(uv2.y).x);
```

**この API 構造が「MLP は workgroup 全体で必ず実行しなければならない」制約を生む**。`coopMat*` と `barrier()` が全レーン参加を要求するため、`nrc_inference.comp` では無効レコード (`NRC_EVAL_INVALID_DST`) のスレッドも MLP を走らせてから捨てる (`nrc_inference.comp:50` の early-return は forward の**後**)。

## 4.4 backward

### 損失勾配のロード (`NNLoadDA3_*`, `NN_nv.glsl:162-196`)

`dL/dy` (3 次元) を shared memory 経由で **転置レイアウト** (`COOPMAT_MAJOR_T(ACT_COOPMAT_MAJOR)` = row-major) の 16×16 coopmat に載せる。以降 backward 側の行列は全て「サンプル × 特徴」の転置形 `dA^T` として扱われる。

- `NNLoadDA3_L2Loss`: `dL = 2 (p - t) * scale`
- `NNLoadDA3_RelativeL2LuminanceLoss` (実際に使われる方):
  ```glsl
  float lum = dot(vec3(0.299,0.587,0.114), max(predict, vec3(0)));
  vec3 d_loss = 2.0 * loss_scale * (predict - target) / (lum*lum + 0.01);
  ```
  論文 Sec. 4 の相対 L2 損失を、チャンネルごとの `p^2` ではなく**予測の輝度**で正規化したもの。`+0.01` は暗部での発散防止。分母を予測側から取るので勾配が定数倍のスケールしか受けず、暗い領域に過剰な重みが乗らない。

### ReLU の微分を NaN で表す (`_nn_act_64_relu_mask_t`, `NN_nv.glsl:198-220`)

これが本実装で最も技巧的な部分。

問題: `dA_prev^T = dA^T · W` を計算した後に「forward で ReLU がゼロにした位置」をマスクしたい。しかしその forward 活性値は `dst_da_coopmats_t` として渡されるレジスタに既に入っている (呼び出し側は同じ配列を forward の活性値置き場と backward の勾配置き場に兼用している)。MMA は `C += A·B` なので、C を単に 0 にしてから MMA すると活性値情報が失われる。

解法:
```glsl
float16_t nan_16 = uint16BitsToHalf(uint16_t(0x7FFF));
// 活性値を転置し直しつつ、
coopmats[x][y][k] = coopmats[x][y][k] > 0.0 ? float16_t(0.0) : nan_16;
```
- 活性値 > 0 の位置 → アキュムレータ初期値 **0** (MMA の結果がそのまま残る)
- 活性値 ≤ 0 の位置 → **NaN** (MMA の結果は NaN に汚染される)

MMA 後に
```glsl
dst[x][y][k] = isnan(dst[x][y][k]) ? float16_t(0) : dst[x][y][k];
```
で NaN を 0 に潰せば、ReLU の微分マスクが適用済みの勾配になる。**アキュムレータの初期値にマスク情報を埋め込む**ことで、ゼロ初期化と ReLU 微分の 2 パスを 1 パスに融合している。

この関数はついでに `coopMatStoreNV(ACT_COOPMAT_MAJOR)` → `coopMatLoadNV(COOPMAT_MAJOR_T(...))` の往復で**転置も済ませている** (forward の「特徴×サンプル」から backward の「サンプル×特徴」へ)。shared memory 経由の store/load 1 往復で転置するのは coopmat に転置命令がないための定石。

### 勾配の逆伝播 (`NNBackwardDA3_ReLU` / `NNBackwardDA64_ReLU`)

```glsl
// 出力層から: dA^T (128,16) x W (16,64) -> dA_prev^T (128,64)
dst_da_t[x][y] = coopMatMulAddNV(src_da_t[y], weight_coopmat, dst_da_t[x][y]);
// 隠れ層: dA^T (128,64) x W (64,64) -> dA_prev^T (128,64)
dst_da_t[x][a_y] = coopMatMulAddNV(src_da_t[w_y][a_y], weight_coopmat, dst_da_t[x][a_y]);
```

forward が `W · A` だったのに対し backward は `dA^T · W` で、**同じ row-major の重みブロックをそのまま (転置せずに) 使える**。これが活性値側を転置形で持つ理由。

### 重み勾配 (`NNUpdateDW64` / `NNUpdateDW3`)

```glsl
// (act (64,128) x da^T (128,64))^T = dW (64,64)
dw_coopmats[w_y][x] = coopMatMulAddNV(act_coopmats[w_y][a_y], da_coopmats_t[x][a_y], dw_coopmats[w_y][x]);
```

forward の活性値 (転置していない側) と backward の勾配 (転置側) を掛けて dW を作る。subgroup 内のサンプルブロックについては MMA のアキュムレータで自動的に足し合わされる。

subgroup 間の集約は shared memory で行う:

1. 各 subgroup が自分の dW (64×64 = 512 uvec4) を `MAT64_COOPMAT_ELEMENT(y, x + COOPMAT_X * gl_SubgroupID)` に書く → subgroup ごとに専用領域 (これが `SHARED_BUFFER_SIZE` に `× SUBGROUP_COUNT` が要る理由)。
2. barrier 後、各スレッドが `SUBGROUP_COUNT` 個の領域から自分担当の 4 uvec4 を読んで fp32 (`vec2` × 4) で加算。
3. `atomicAdd(uDWeights[...], ..., gl_ScopeQueueFamily, gl_StorageSemanticsBuffer, gl_SemanticsRelaxed)` で**グローバルバッファへ fp32 加算** (`VK_EXT_shader_atomic_float` が必須な理由)。

つまり勾配は「subgroup 内 = fp16 MMA アキュムレータ、subgroup 間 = fp32 shared 加算、workgroup 間 = fp32 グローバル atomic」の 3 段構成。バッチ 16384 サンプル = 128 workgroup 分の atomic が 20672 個の float に集まる。

`NNUpdateDW3` は 16×64 の領域 (128 uvec4) を書くが、有効なのは先頭 24 uvec4 (3×64 = 192 fp16) だけで、`gl_LocalInvocationID.x < WEIGHT_3_UV4_COUNT` のスレッドしか atomic しない。

## 4.5 呼び出し側の構成

### 推論 (`nrc_inference.comp`)

```glsl
fcoopmatNV<...> act_coopmats[2][COOPMAT_X][SUBGROUP_ACT_COOPMAT_Y];   // ping-pong 2 枚
NNLoadInput(inputs, act_coopmats[0]);
NNForward64_ReLU(0, act_coopmats[0], act_coopmats[1]);
NNForward64_ReLU(1, act_coopmats[1], act_coopmats[0]);
... (5 層)
NNForward3(5, act_coopmats[1], out_coopmats);
vec3 predict = max(NNOutput3(out_coopmats), vec3(0));
```

推論は活性値を保存する必要がないので **2 枚の ping-pong** で済む。最後に `max(・, 0)` で負値をクランプ (放射輝度なので非負)。

### 勾配 (`nrc_gradient.comp`)

```glsl
fcoopmatNV<...> act_coopmats[NRC_HIDDEN_LAYERS + 1][COOPMAT_X][SUBGROUP_ACT_COOPMAT_Y];  // 6 枚
fcoopmatNV<...> out_coopmats[...];
```

backward で使うため**全層の活性値をレジスタに保持し続ける**。subgroupSize=32 の場合、1 subgroup が持つのは 6 × 4 × 2 × 256 = 12288 fp16 → 1 レーンあたり 384 fp16 = **192 個の 32bit レジスタ**。さらに `out_coopmats` と backward の作業行列が乗る。NVIDIA の上限 255 レジスタ/スレッドに対してかなりギリギリで、occupancy は 1〜2 warp/SM 程度に落ちると考えられる (レジスタスピルが起きていないかは要プロファイル)。

backward は層ごとに dW 計算と勾配伝播を交互に呼ぶ:

```glsl
NNLoadDA3_RelativeL2LuminanceLoss(predict, target, LOSS_SCALE, out_coopmats);
NNUpdateDW3(5, out_coopmats, act_coopmats[5]);
NNBackwardDA3_ReLU(5, out_coopmats, act_coopmats[5]);   // act_coopmats[5] が dA^T に上書きされる
NNUpdateDW64(4, act_coopmats[5], act_coopmats[4]);
NNBackwardDA64_ReLU(4, act_coopmats[5], act_coopmats[4]);
NNUpdateDW64(3, act_coopmats[4], act_coopmats[3]);
NNBackwardDA64_ReLU(3, act_coopmats[4], act_coopmats[3]);
...
NNUpdateDW64(0, act_coopmats[1], act_coopmats[0]);
```

`act_coopmats[i]` が「層 i の活性値」から「層 i の勾配 `dA^T`」へ**その場で置き換わっていく**。`_nn_act_64_relu_mask_t` が活性値を読んでからマスクを書くので、この in-place 変換が成立する。最終層 (layer 0) は入力層への勾配が不要なので `NNBackwardDA64_ReLU(0, ...)` は呼ばれない。

## 4.6 subgroup サイズ対応

`SUBGROUP_SIZE` はコンパイル時定数として `glslc -DSUBGROUP_SIZE=16` / `=32` で焼き込まれ、実行時に実測 subgroupSize に応じた SPIR-V を選ぶ (`NNInferenceShader.cpp` / `NNGradientShader.cpp`)。パイプラインには

- `VK_PIPELINE_SHADER_STAGE_CREATE_REQUIRE_FULL_SUBGROUPS_BIT`
- `VkPipelineShaderStageRequiredSubgroupSizeCreateInfo`

を指定して、workgroup が完全な subgroup で埋まることを保証している。`SUBGROUP_SIZE = 64` の版は `shader/CMakeLists.txt` でコメントアウトされており (`5a783e0 "Remove support for warpSize=64 due to compile error on windows glslc. Idk why"`)、AMD (wave64) では動かない。
