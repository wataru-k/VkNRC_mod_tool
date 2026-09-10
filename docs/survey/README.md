# VkNRC 実装調査レポート

調査基準: upstream `AdamYuan/VkNRC` (branch `master`, HEAD `a667859`)
調査日: 2026-08-28

このForkでは、調査内容と改造コードを同じ履歴で管理する。

NVIDIA の論文 [Real-time Neural Radiance Caching for Path Tracing (Müller et al., SIGGRAPH 2021)](https://research.nvidia.com/publication/2021-06_real-time-neural-radiance-caching-path-tracing) の Vulkan 実装。
Fully-Fused MLP を `VK_NV_cooperative_matrix` で自前実装しており、CUDA / tiny-cuda-nn には一切依存しない。

## 目次

| ファイル | 内容 |
|---|---|
| [01-architecture.md](01-architecture.md) | 全体アーキテクチャ、レンダーグラフのパス構成、リソース一覧、1フレームの実行フロー |
| [02-path-tracer.md](02-path-tracer.md) | パストレーサ、経路終端ヒューリスティック、self-training 経路とレコード生成 |
| [03-encoding.md](03-encoding.md) | NRC のクエリ入力定義、64次元への周波数 / One-Blob エンコーディング、レコードのビットパッキング |
| [04-fused-mlp.md](04-fused-mlp.md) | Fully-Fused MLP (`NN_nv.glsl`)、cooperative matrix による forward / backward の実装詳細 |
| [05-training.md](05-training.md) | 損失関数、勾配集約、Adam / EMA オプティマイザ、フレーム内 4 バッチ学習 |
| [06-parameters-and-notes.md](06-parameters-and-notes.md) | 全ハイパーパラメータ一覧、論文との差異、気付いた実装上の論点、ファイルマップ |

## 要約 (30秒版)

- **描画方式**: V-Buffer をラスタライズ → 1次ヒットを取得 → compute shader で ray query によるパストレース。経路は論文の面積拡がり (area-spread) ヒューリスティックで短く打ち切り、終端頂点で **ニューラルキャッシュを1回推論** して残りの寄与を代替する。
- **ネットワーク**: 入力 64 → 隠れ 5 層 × 64 (ReLU) → 出力 3。バイアス項なし。重み総数 **20,672** (fp16, 41 KB)。
- **MLP 実装**: workgroup 128 スレッド = 128 サンプルのタイル。活性値 64×128 の fp16 行列を shared memory / レジスタに常駐させ、`fcoopmatNV<16, subgroup, 16, 16>` の 16×16×16 MMA だけで全層を計算する。**backward もフル融合**で、逆伝播中の活性値を全部レジスタに保持したまま dW を計算する。
- **学習**: self-training。学習用画素 (既定 3%) では経路を延長し、各頂点の教師値を「残り経路の放射輝度 + throughput × キャッシュ推論値」として作る。相対 L2 輝度損失、Adam (lr=0.002)、重みの EMA (α=0.99)。**1 フレームあたり 16384 サンプル × 4 バッチ**を逐次学習。
- **依存**: `VK_NV_cooperative_matrix`, `VK_KHR_ray_query`, `VK_KHR_acceleration_structure`, `VK_EXT_shader_atomic_float`, Vulkan 1.3 (subgroupSizeControl / computeFullSubgroups)。事実上 NVIDIA GPU 専用 (subgroupSize=32 前提)。
- **UI**: 画面左右で描画手法 (None / NRC / Cache) を切り替えて比較できる。学習の一時停止・1フレームだけ学習・重み再初期化のボタンあり。
