# 03. 入力エンコーディングとレコード

対象: `shader/src/NRCRecord.glsl`

## 3.1 クエリの構成要素

論文 Table 1 (入力エンコーディング) に対応する 7 要素。`UnpackedNRCInput` (`NRCRecord.glsl:40-45`):

| 要素 | 次元 | 由来 |
|---|---|---|
| `position` | 3 | ヒット点のワールド座標 (シーンは `[-1,1]` に正規化済み) |
| `scattered_dir` | 2 | 散乱方向の球面座標 (`NRCSphEncode` 済みの `[0,1]^2`) |
| `normal` | 2 | 面法線の球面座標 |
| `roughness` | 1 | マテリアルの roughness |
| `diffuse` | 3 | アルベド (テクスチャ評価済み) |
| `specular` | 3 | 鏡面反射色 (テクスチャ評価済み) |

論文にある「表面法線」「散乱方向」を球面座標 2 次元にする点、「roughness を `1-exp(-r)` で変換する」点は論文どおり。

## 3.2 パックとアンパック

パストレーサは `PackedNRCInput` (16 B) しか書かない (`NRCRecord.glsl:6-10`)。

```glsl
struct PackedNRCInput {
    uint primitive_id;
    uint flip_bit_instance_id;   // bit31: 法線反転, bit0-30: instance_id
    uint barycentric_2x16U;      // packUnorm2x16(barycentric.yz)
    uint scattered_dir_2x16U;    // packUnorm2x16(NRCSphEncode(dir))
};
```

`UnpackNRCInput` (`NRCRecord.glsl:98-125`、`NRC_SCENE_UNPACK` 定義時のみ有効) が推論 / 勾配シェーダ側でシーンバッファを引き直して復元する:

- 頂点 3 つを `GetSceneVertex` で取得し、バリセントリックで位置を補間。
- 法線は 3 頂点の外積 (面法線)。`flip` ビットで反転。頂点法線の補間はしていない。
- テクスチャ座標も補間して `GetSceneDiffuse` / `GetSceneSpecular` でテクスチャをサンプル。
- `roughness` はマテリアルの生値。

つまり**レコードには 16 B しか書かず、位置 / 法線 / アルベドは推論時に再計算する**。帯域と引き換えに ALU とテクスチャフェッチを使う設計。

`NRCSphEncode` (`NRCRecord.glsl:47-49`):
```glsl
vec2(d.xy == vec2(0) ? 0.5 : 0.5 + atan(d.y, d.x) / (2π),  acos(clamp(d.z,-1,1)) / π)
```
方位角と極角を `[0,1]` に正規化。

## 3.3 64 次元への周波数 / One-Blob エンコーディング

`NRCInputEncode` (`NRCRecord.glsl:78-95`) が入力を fp16 × 64 = `uvec4[8]` にパックする。内訳:

| 要素 | 手法 | 出力次元 |
|---|---|---|
| position.x/y/z | 周波数エンコーディング (12 周波数) | 12 × 3 = **36** |
| scattered_dir.x/y | One-Blob (4 ビン) | 4 × 2 = **8** |
| normal.x/y | One-Blob (4 ビン) | 4 × 2 = **8** |
| `1-exp(-roughness)` | One-Blob (4 ビン) | **4** |
| diffuse.rgb | 素通し | **3** |
| specular.rgb | 素通し | **3** |
| 定数 1, 1 | パディング | **2** |
| | 合計 | **64** |

末尾 2 要素が定数 `1.0` (`NRCRecord.glsl:93-94`) になっている。バイアス項が MLP に無いので、**これが実質的に第1層のバイアスとして機能する**。ただし第2層以降にはバイアス相当が無い。

### 周波数エンコーディング (`NRCFrequencyEncode`, `NRCRecord.glsl:65-72`)

```glsl
mat3x4 f = mat3x4(vec4(1,2,4,8), vec4(16,32,64,128), vec4(256,512,1024,2048)) * p;
return mat3x4(_nrc_tri(f[0]), _nrc_tri(f[1]), _nrc_tri(f[2]));
```

周波数は 2^0 … 2^11 の 12 個。`sin(π x)` の代わりに**三角波** `_nrc_tri(x) = 2|mod(x-0.5, 2) - 1| - 1` を使う (`NRCRecord.glsl:65-68`)。コミット `763b670 "Use Relative L2 Luminance Loss; Use Faster Encoding Methods"` で `sin` から置き換えられている。ソース中に `// return sin(M_PI * x);` としてオリジナルが残っている。三角波は超越関数を使わないので大幅に安い。

論文は sin/cos ペアの正弦エンコーディングを使うので、ここは**意図的な高速化のための近似**。

### One-Blob エンコーディング (`NRCOneBlob4Encode`, `NRCRecord.glsl:51-63`)

4 ビン (`[0,0.25), [0.25,0.5), [0.5,0.75), [0.75,1)`) に対し、四次カーネルの CDF 差分でビンごとの重みを求める:

```glsl
vec4 _quartic_cdf(vec4 x, float inv_radius) {
    vec4 u = x * inv_radius; ...
    return clamp((15/16) u (1 - (2/3)u² + (1/5)u⁴) + 0.5, 0, 1);
}
vec4 NRCOneBlob4Encode(float x) {
    vec4 l = vec4(0,0.25,0.5,0.75), r = vec4(0.25,0.5,0.75,1);
    return _quartic_cdf(r - x, 4) - _quartic_cdf(l - x, 4);
}
```

ガウシアンではなく**四次カーネル (Epanechnikov 系)** を使うのも `exp` を避けるための最適化。カーネル半径 `1/4` (= `inv_radius = 4`) で、ビン幅と一致している。論文の One-Blob は 4 ビンなので次元数は一致。

## 3.4 出力先 (`dst`) のエンコーディング

推論結果をどこに書くかを 32 bit に詰める (`NRCRecord.glsl:12-33`)。最下位 1 ビットが種別:

```glsl
// 種別 0: 画面
uint EncodeNRCEvalDstScreen(uvec2 xy15)  { return (xy15.x | (xy15.y << 15u)) << 1u; }
// 種別 1: 学習レコードの範囲
uint EncodeNRCEvalDstTrain(uint b2, uint l14, uint r14) {
    return (b2 | (l14 << 2u) | (r14 << 16u)) << 1u | 1u;
}
```

| 種別 | フィールド | ビット幅 | 上限 |
|---|---|---|---|
| Screen | x, y | 15, 15 | 32768×32768 画素 |
| Train | batch, left, right | 2, 14, 14 | 4 バッチ、インデックス 0-16383 |

学習側の 14 bit は `NRC_TRAIN_BATCH_SIZE = 16384` にちょうど一致する。バッチサイズを変えると**このエンコーディングも同時に直さなければならない**暗黙の結合になっている (`Constant.glsl` の定数を変えても `EncodeNRCEvalDstTrain` は追随しない)。

`NRC_EVAL_INVALID_DST = -1u` は、workgroup 内で `eval_count` を超えたレーン (パディング) を示すマーカー。`dst` の最下位ビットが 1 なので形式上は Train 種別だが、`nrc_inference.comp:50-51` で先にチェックして return する。

Train 種別が「範囲」`[l, r]` になっているのは §02.6 の通り、1 本の学習経路の全頂点が連続スロットを占め、それら全てが**同一の終端キャッシュ推論値を共有する**ため。推論シェーダは 1 回の推論結果を範囲内の全レコードにループで配る (`nrc_inference.comp:64-72`)。
