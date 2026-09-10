# Textured Bistro port preparation — 2026-09-11

## CPU validation

- Source: `E:\RTXGI_mod_tool_4\Assets\Media\Bistro.scene.json`
- Vertices: 4,073,339
- Texture coordinates: 4,073,339 plus one dummy coordinate
- Triangles: 4,209,006
- Expanded mesh primitives: 2,909
- Materials: 254
- Referenced diffuse/specular/emission textures: 219
- DDS textures converted to PNG: 219/219
- Converted images decoded successfully: 219/219
- CPU-only VkNRC OBJ parse: successful
- Vulkan device created during preparation: no

## Generated input

- OBJ size: 610,353,810 bytes
- OBJ SHA-256: `85395D6C726D0C273895508F29579E52CE36ADA0D6B6A977A167285E7A5F67FB`
- MTL SHA-256: `D4DA84D7C7F771ECF02CBDC10A7177E6CD7440BC0BA68AFC40567C9FD6752872`
- Manifest SHA-256: `8401A88E0F1A0A2BD01A4EF8B36B96B0AB96071D405286B0508B71B605480A40`

## Imported camera

- Source position: `[-12.63, 1.71, 21.66]`
- VkNRC normalized position: `[-0.2897171834, -0.1653424101, 0.1203948303]`
- Vertical FOV: `0.7` radians

## Fidelity boundary

The port retains the scene graph, transforms, UVs, diffuse/specular/emission
textures used by VkNRC, constant material factors and camera. The source Sun is
recorded in the generated manifest, but VkNRC currently uses its own hard-coded
environment lighting. Normal maps are also omitted because VkNRC has no
normal-map material input. The upcoming GPU result therefore applies to the
textured Bistro asset/camera port under VkNRC lighting, not a pixel-identical
RTXGI Bistro renderer.

GPU validation has completed; see
[`2026-09-11-bistro-textured-whiteout-ab.md`](2026-09-11-bistro-textured-whiteout-ab.md).
