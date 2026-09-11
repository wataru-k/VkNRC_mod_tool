# Bistro RTXGI-reference-lighting whiteout A/B — 2026-09-11

This run evaluates the textured Bistro port with the opt-in RTXGI reference
lighting preset. The preset uses sky radiance `(4, 6, 8)` and a shadowed Sun
with irradiance 20, direction-to-light `(0.049, 0.87, -0.48)` and a 0.8-degree
angular diameter. Direct Sun terms are included in both rendered radiance and
NRC training records.

| Guard | Evaluated predictions | Non-finite | Over threshold | Maximum luminance | Exit |
|---|---:|---:|---:|---:|---:|
| Off | 2,918,681,384 | 0 | 0 | 18.078688 | 0 |
| On | 2,918,679,167 | 0 | 0 | 15.762361 | 0 |

Both runs used seed 1, 3,600 frames and a threshold of 100 on an NVIDIA
GeForce RTX 4090 with driver 616.56. A preceding 60-frame guard-off smoke also
completed with exit 0, no non-finite or over-threshold prediction, and maximum
luminance 5.4480066. No Vulkan or texture error was logged.

No whiteout-class event was reproduced. Matching the reference sky and Sun is
therefore insufficient by itself. The next fidelity gap to close is material
shading, especially glTF vertex normals, tangents and normal maps; VkNRC still
uses geometric face normals and its own Cook-Torrance/path policy.

The machine-readable A/B result is
[`2026-09-11-bistro-rtxgi-lighting-whiteout-ab.json`](2026-09-11-bistro-rtxgi-lighting-whiteout-ab.json).
