# Bistro normal-map WhiteOut reproduction — 2026-09-11

WhiteOut was reproduced after adding source vertex normals, tangents and normal
maps to the textured Bistro port and enabling RTXGI reference lighting.

## Smoke

The 60-frame guard-off smoke completed with target exit code 0, but already
showed a widespread finite over-bright failure:

| Evaluated | Non-finite | Over threshold 100 | Maximum luminance |
|---:|---:|---:|---:|
| 48,569,035 | 0 | 38,641,110 | 10,748.671 |

The sweep wrapper returned its fail-fast status because 79.6% of evaluated
predictions exceeded the threshold. There was no process, Vulkan or texture
failure, so the planned diagnostic A/B continued.

## 3,600-frame A/B

| Guard | Evaluated predictions | Non-finite | Over threshold | Maximum finite luminance | Exit |
|---|---:|---:|---:|---:|---:|
| Off | 2,914,060,710 | 2,810,762,632 | 93,437,130 | 55,357.26 | 0 |
| On | 2,914,052,519 | 1,402,083,299 | 178,922,539 | 58,359.19 | 0 |

Both runs used seed 1, 3,600 frames, threshold 100 and RTXGI reference lighting
on an NVIDIA GeForce RTX 4090 with driver 616.56. The user observed the large
magenta diagnostic region during the guard-off run. This matches the final
counter: 96.5% of predictions were non-finite.

The experimental guard did not prevent the failure. Its current implementation
sets an invalid prediction to zero and clamps only finite over-threshold values;
the diagnostic intentionally paints invalid predictions magenta. Guard ON
reduced the non-finite count but did not keep the network finite, and its finite
over-threshold count and maximum luminance were higher than Guard OFF.

This isolates shading-normal fidelity as the trigger in the current VkNRC
reproduction: the same Bistro textures, camera and reference lighting remained
stable with geometric face normals, while the normal-map port failed within 60
frames. It does not yet distinguish vertex-normal interpolation from tangent-
space normal mapping; that requires the next component A/B.

The machine-readable result is
[`2026-09-11-bistro-normal-map-whiteout-ab.json`](2026-09-11-bistro-normal-map-whiteout-ab.json).
