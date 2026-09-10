# LivingRoom whiteout A/B result — 2026-09-11

The port includes LivingRoom, the transformed BrainStem model, all 16 JPEG
base-color textures, UVs, and the normalized source camera position/FOV.

| Guard | Evaluated predictions | Non-finite | Over threshold | Maximum luminance | Exit |
|---|---:|---:|---:|---:|---:|
| Off | 3,178,413,015 | 0 | 0 | 40.781906 | 0 |
| On | 3,178,419,487 | 0 | 0 | 41.110214 | 0 |

Both runs used seed 1, 3,600 frames and a threshold of 100 on an NVIDIA
GeForce RTX 4090 with driver 616.56. All 16 textures loaded successfully.
No whiteout-class prediction was observed and the guard did not activate.

The machine-readable result is
[`2026-09-11-living-room-whiteout-ab.json`](2026-09-11-living-room-whiteout-ab.json).

This is a materially more faithful scene port than the earlier geometry-only
Bistro conversion. VkNRC still uses its own BRDF, hard-coded environment light
and tone mapper, so it is not pixel-identical to the RTXGI renderer.

