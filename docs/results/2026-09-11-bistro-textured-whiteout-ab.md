# Textured Bistro whiteout A/B result — 2026-09-11

This run uses the full Bistro scene graph, baked node transforms, UVs, source
camera/FOV, constant material factors and 219 diffuse/specular/emission textures
converted from DDS to PNG.

| Guard | Evaluated predictions | Non-finite | Over threshold | Maximum luminance | Exit |
|---|---:|---:|---:|---:|---:|
| Off | 2,918,911,058 | 0 | 0 | 30.226665 | 0 |
| On | 2,918,914,627 | 0 | 0 | 30.603945 | 0 |

Both runs used seed 1, 3,600 frames and a luminance threshold of 100 on an
NVIDIA GeForce RTX 4090 with driver 616.56. All 219 converted textures loaded
successfully. No whiteout-class prediction was observed and the guard did not
activate.

The machine-readable result is
[`2026-09-11-bistro-textured-whiteout-ab.json`](2026-09-11-bistro-textured-whiteout-ab.json).

## Fidelity boundary

This supersedes the earlier geometry-only Bistro test for asset and camera
coverage. The source directional Sun is recorded in the generated manifest but
is not evaluated by VkNRC, which retains its hard-coded environment light.
Normal maps are also not supported. Consequently this is the textured Bistro
asset/camera under VkNRC rendering, not a pixel-identical RTXGI Bistro run.

