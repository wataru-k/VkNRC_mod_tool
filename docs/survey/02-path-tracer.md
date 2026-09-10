# 02. パストレーサとレコード生成

対象: `shader/src/path_tracer.comp`, `src/rg/PathTracerPass.cpp`

## 2.1 基本構成

- workgroup 8×8、1 スレッド = 1 画素 (`path_tracer.comp:9`)。
- `MAX_BOUNCE 8`, `T_MIN 1e-6`, `T_MAX 4.0`, `C 0.01` (`path_tracer.comp:11-14`)。
  `T_MAX = 4.0` はシーンが `Scene.cpp:33-41` で `[-1,1]` (最大辺 2) に正規化されることを前提とした固定値。
- BRDF は Cook-Torrance (Beckmann 分布 + Walter G1 + Schlick フレネル、`CookTorranceBRDF.glsl`)。
  サンプリングは鏡面 / 拡散の輝度比 `CT_Specular_Prob` で確率的に切り替える MIS 無しの単純な混合。
- 環境光は `kConstLight = vec3(10,10,10)` の定数 (`path_tracer.comp:142`)。ミスした時点で寄与を確定して打ち切る。
- RNG は PCG (`RNG.glsl`)。シードは 256×256 タイル座標 + フレームシード (`path_tracer.comp:381`)。

1次ヒットは**レイトレースせず V-Buffer から復元**する (`GetVBufferHit`, `path_tracer.comp:68-99`)。primitive_id / instance_id から頂点を引き、レイと三角形の解析的交差でバリセントリックを再計算している。

## 2.2 描画手法の切り替え

`Method` は 3 種 (`VkNRCState.hpp:19`, `path_tracer.comp:25-27`):

| 値 | 意味 | 挙動 |
|---|---|---|
| `METHOD_NONE` (0) | キャッシュ無しの純パストレース | `c_a0 = +inf` にして面積ヒューリスティックを無効化し、`MAX_BOUNCE` まで追跡。キャッシュ推論もしない |
| `METHOD_NRC` (1) | 論文の NRC | 面積ヒューリスティックで打ち切り、終端でキャッシュ推論 |
| `METHOD_CACHE` (2) | キャッシュ単体の可視化 | 経路を追跡せず、1次ヒットで即キャッシュ推論 |

画面の左半分 / 右半分に別々の手法を割り当てられる (`path_tracer.comp:387`)。手法の分岐は `subgroupAll(...)` でガードされていて、subgroup 内で手法が混在する境界の subgroup では**どちらの分岐も実行されない**。境界の 1 subgroup 幅は未定義値になるが、比較 UI としては実害が無い割り切りになっている。

## 2.3 経路の打ち切り: 面積拡がりヒューリスティック

論文 Sec. 5 の終端条件をそのまま実装している (`path_tracer.comp:218-222`)。

```glsl
c_a0 = C * info.dist2 / (4 * M_PI * info.cosine);   // 1次頂点の a_0 相当
...
for (bounce = 1; bounce < MAX_BOUNCE && sqrt_a_sum * sqrt_a_sum <= c_a0; ++bounce) {
    ...
    sqrt_a_sum += sqrt(info.dist2 / (info.pdf * info.cosine));
}
```

各頂点で `sqrt(d^2 / (p * cos))` を累積し、その二乗が `C * a_0` を超えたら終端する。`C = 0.01`。
論文の記法では `a(x_1..x_n) = (Σ sqrt(d_i^2/(p_i cos_i)))^2 > c * a_0` に対応する。

- `METHOD_NONE` では `c_a0` を `+inf` (`uintBitsToFloat(0x7F800000u)`) に置いて条件を無効化する (`path_tracer.comp:218`)。
- ロシアンルーレットは無い。打ち切りは面積条件と `MAX_BOUNCE` のみ。

## 2.4 放射輝度の分解 (bias / factor)

パストレーサはキャッシュ推論の結果を待てないため、画素値を

```
L = bias + factor * cache(x_terminal, ω_terminal)
```

の形に分解して出力する (`PathTraceResult { vec3 bias, factor; }`, `path_tracer.comp:204-206`)。

- `bias` … 経路上で確定した放射輝度 (emission の累積、およびミス時の `kConstLight`)。
- `factor` … 終端頂点までの throughput (`accumulate`、BRDF·cos/pdf の積)。

書き出し先は 2 枚のイメージに分けている (`path_tracer.comp:418-419`):
- `uBias_FactorR` (RGBA32F) = `(bias.rgb, factor.r)`
- `uFactorGB` (RG32F) = `(factor.gb, 0, 0)`

環境光にミスして終端した場合は `PathTraceResult(radiance, accumulate)` を返すが `eval_record` を積まない (`path_tracer.comp:236-238`)。この場合 `factor` は 0 ではないので**キャッシュ推論が発生しないまま `factor` が残る**が、推論パスが `bias` に加算しないため画面には `bias` だけが出る。`factor` の値は使われずに捨てられる。V-Buffer でミスした画素も同様に `PathTraceResult(kConstLight, vec3(0))` (`path_tracer.comp:401`) として扱われる。

エンコード後の入力生成は `MakeNRCInput` (`path_tracer.comp:159-166`)。頂点の識別情報 (primitive_id, instance_id, 法線反転ビット, バリセントリック) と散乱方向のみを 16 B に詰め、実際の位置 / 法線 / マテリアルは推論側でシーンから引き直す (`UnpackNRCInput`)。**帯域を犠牲にせず情報量を保つための設計**で、コミット `47f4ab5 "Better Inference Record Encoding"` で導入されている。

## 2.5 通常経路 (`PathTrace`, `path_tracer.comp:208-252`)

1. 1次ヒットで BRDF サンプリング。`radiance += emission`, `accumulate *= color`。
2. 面積条件を満たす間、ray query でバウンス。
3. ミスしたら `kConstLight` を加算して即 return (レコードなし)。
4. 打ち切ったら `eval_records` に 1 件 push。`dst` は画面座標エンコード。

`eval_count` への atomic は `gl_ScopeQueueFamily` + `gl_SemanticsRelaxed` (`path_tracer.comp:244`)。

## 2.6 self-training 経路 (`ExtendedPathTrace`, `path_tracer.comp:254-375`)

学習フラグは subgroup 単位で決める (`path_tracer.comp:389-394`):

```glsl
if (subgroupElect()) train = RNGNext() < uTrainProbability;
train = subgroupBroadcastFirst(train);
```

先頭レーンが 1 回だけ乱数を引き、subgroup 全体に配る。既定 `kDefaultTrainProbability = 0.03f` (`VkNRCState.hpp:22`) なので、**subgroup 単位で 3%** が学習経路になる。これにより subgroup 内の分岐発散が無くなる (通常経路と学習経路はレジスタ消費もループ構造も大きく違う)。

処理の流れは 3 段階:

### 段階 1: 通常と同じ長さまで追跡 (`path_tracer.comp:267-318`)

各頂点の `emission` (`lights[]`)、その頂点の throughput 因子 (`colors[]`)、NRC 入力 (`inputs[]`) を長さ `MAX_BOUNCE` のローカル配列に記録しながら進む。この時点で画面表示用の `result` を確定させる:

- `METHOD_CACHE`: 1次頂点 (`inputs[0]`) を画面用クエリとして push。
- それ以外: 通常経路と同じ位置 (`inputs[bounce-1]`) を画面用クエリとして push。ミス終端なら push しない。

### 段階 2: 学習のために経路を延長 (`path_tracer.comp:320-341`)

`sqrt_a_sum` を 0 にリセットし、同じ `c_a0` を閾値としてもう一巡追跡する。実質的に**面積予算を 2 回分使う = 経路長を倍にする**という形の延長で、論文の「学習経路は少し長く追跡する」に対応する。`MAX_BOUNCE = 8` が全体の上限。

### 段階 3: 教師値の構築とレコード書き出し (`path_tracer.comp:343-372`)

```glsl
uint batch = clamp(uint(RNGNext() * NRC_TRAIN_BATCH_COUNT), 0u, NRC_TRAIN_BATCH_COUNT - 1);
uint train_id = atomicAdd(uBatchTrainCounts[batch].count, bounce, ...);
if (train_id < NRC_TRAIN_BATCH_SIZE) {
    for (uint i = bounce - 2u; i != -1u; --i) {       // 後ろから前へ畳み込み
        lights[i] += colors[i] * lights[i + 1];
        colors[i] *= colors[i + 1];
    }
    ...
}
```

- 経路 1 本が**まとめて 1 バッチに入る** (4 バッチのいずれかをランダムに選び、`bounce` 個の連続スロットを atomic で確保)。
- 後ろから畳み込むことで、頂点 `i` に対する `lights[i]` = 「頂点 i 以降で確定した放射輝度」、`colors[i]` = 「頂点 i から終端までの throughput」になる。つまり 1 本の経路から**全頂点分の教師サンプルを同時に得る**。
- スロットが足りない場合は `train_count = min(bounce, 16384 - train_id)` で切り詰める。
- 延長した経路の終端でもミスしていなければ、`dst` に「バッチ b の `[train_id, train_id+train_count-1]` の範囲」をエンコードしたクエリを push する (`path_tracer.comp:364-371`)。これが推論パスで `bias += factor * predict` の形で全教師サンプルに反映される (§03.4)。

学習経路でも画面用のクエリは別途 push されるので、学習画素 1 つで最大 2 件の推論クエリが立つ。

## 2.7 パストレーサのディスクリプタ (`src/rg/PathTracerPass.cpp:28-71`)

| binding | 内容 |
|---|---|
| 0 | TLAS |
| 1-7 | vertices, vertex_indices, texcoords, texcoord_indices, materials, material_ids, transforms |
| 8 (array) | テクスチャ (数は specialization constant 0) |
| 9 | V-Buffer (nearest sampler) |
| 12 | `eval_count` (RW) |
| 13 | `eval_records` (W) |
| 14[4] | `batch_train_count[b]` (RW) |
| 15[4] | `batch_train_records[b]` (W) |
| 16 | `bias_factor_r` (W) |
| 17 | `factor_gb` (W) |

binding 10, 11 が空いている。以前あったリソースを削除した跡と見られる。
push constant は camera (origin/look/side/up)、seed、extent、left/right method、train_probability (`PathTracerPass.cpp:12-21`)。
