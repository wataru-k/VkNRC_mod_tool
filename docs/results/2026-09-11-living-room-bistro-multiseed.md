# LivingRoom and textured Bistro multiseed result — 2026-09-11

Guard-off whiteout diagnostics were repeated with seeds 2, 3 and 4 for the
ported LivingRoom and textured Bistro scenes. Every run used 3,600 frames and
a luminance threshold of 100 on an NVIDIA GeForce RTX 4090.

| Scene | Seed | Evaluated predictions | Non-finite | Over threshold | Maximum luminance | Exit |
|---|---:|---:|---:|---:|---:|---:|
| LivingRoom | 2 | 3,178,426,680 | 0 | 0 | 45.745907 | 0 |
| LivingRoom | 3 | 3,178,423,982 | 0 | 0 | 29.730167 | 0 |
| LivingRoom | 4 | 3,178,406,747 | 0 | 0 | 39.488020 | 0 |
| Bistro | 2 | 2,918,919,153 | 0 | 0 | 32.271860 | 0 |
| Bistro | 3 | 2,918,932,819 | 0 | 0 | 54.040474 | 0 |
| Bistro | 4 | 2,918,952,064 | 0 | 0 | 28.236967 | 0 |

All six runs completed without a non-finite or over-threshold prediction. No
whiteout-class event was reproduced. Together with the seed-1 A/B runs, this
gives four tested initializations per scene, but it does not establish that the
upstream failure is absent from VkNRC.

The ports reuse source assets and camera metadata, while VkNRC still uses its
own BRDF, environment lighting, training schedule and tone mapper. Bistro
normal maps and the source directional sun are not evaluated. These remaining
renderer differences are the leading candidates for a reproduction gap.

The machine-readable result is
[`2026-09-11-living-room-bistro-multiseed.json`](2026-09-11-living-room-bistro-multiseed.json).
The run was driven by `tools/run-whiteout-sweep.ps1`, which writes a summary
after each run and stops the sweep on process failure, Vulkan/texture errors,
non-finite predictions or threshold violations.
