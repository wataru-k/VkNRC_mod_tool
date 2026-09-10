# LivingRoom port preparation — 2026-09-11

## CPU validation

- Source manifest: `E:\RTXGI_mod_tool_4\Assets\Media\LivingRoom.scene.json`
- Models: LivingRoom and transformed BrainStem
- Vertices: 394,893
- Triangles: 642,297
- Mesh primitives: 209
- Materials: 98
- Texture coordinates: 360,734 plus one dummy coordinate for untextured primitives
- JPEG textures: 16/16 copied and decoded successfully
- CPU-only VkNRC OBJ parse: successful
- Vulkan device created during preparation: no

## Imported camera

- Source position: `[0.19, 1.70, 7.44]`
- VkNRC normalized position: `[-0.0238523224, 0.0293571849, 0.8119675605]`
- Vertical FOV: `0.7` radians
- Near plane recorded by source: `0.01`

The GPU validation has completed; see
[`2026-09-11-living-room-whiteout-ab.md`](2026-09-11-living-room-whiteout-ab.md).
