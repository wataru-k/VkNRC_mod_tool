# Bistro whiteout A/B preparation — 2026-09-11

## Status

Preparation was completed through the last CPU-only step. The planned GPU run
has since completed; see
[`2026-09-11-bistro-whiteout-ab.md`](2026-09-11-bistro-whiteout-ab.md).

## Source asset

- glTF: `E:\RTXGI_mod_tool_4\Assets\Media\Bistro\bistro.gltf`
- Binary buffer: `E:\RTXGI_mod_tool_4\Assets\Media\Bistro\bistro.bin`
- glTF SHA-256: `4FE4916C1DA2517282AB0204CDFE63B211B03EBF37D07CC273627E6368095E62`
- Binary SHA-256: `5FB11A1D61AEB2537197AA97833FF950638C9D42451EE4FAFBC9550F03918FAA`

## Prepared VkNRC input

- OBJ: `build-vs/scenes/bistro/bistro.obj`
- MTL: `build-vs/scenes/bistro/bistro.mtl`
- Vertices: 4,073,339
- Triangles: 4,209,006
- Expanded mesh instances: 2,909
- OBJ size: 343,925,076 bytes
- OBJ SHA-256: `793CD18BCD76FAA116DEC443A840F9B2169D6B85D5604E17F8A2D0C1B423BC92`
- MTL SHA-256: `1C50DF2AD2B1E99675A2435991BB1C022508FABFE0D09F41C08FADA27D4C858A`

The line-count validation matched the converter totals, and a text scan found
no `NaN` or `Infinity` vertex values. Generated scene files live under the
ignored `build-vs` directory and can be recreated with the checked-in converter.

The conversion expands node transforms and glTF instances. It retains constant
diffuse, specular, emission and roughness factors, but omits DDS textures. This
is appropriate for training-stability/whiteout diagnosis, not image-quality
comparison with the RTXGI Bistro rendering.

## GPU command used

Use seed 1 for an identical-sequence guard-off/guard-on comparison:

```powershell
.\tools\run-whiteout-ab.ps1 `
  -Scene .\build-vs\scenes\bistro\bistro.obj `
  -Frames 3600 -Threshold 100 -Seed 1
```

The wrapper runs guard-off first, then guard-on, and writes both raw logs plus a
parsed `summary.json` under `build-vs/whiteout-results`.
