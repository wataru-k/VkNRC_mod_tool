# Bistro normal-map port preparation — 2026-09-11

## CPU validation

- Source: `E:\RTXGI_mod_tool_4\Assets\Media\Bistro.scene.json`
- Vertices: 4,073,339
- Vertex normals: 4,073,339/4,073,339
- Source tangents applied: 4,045,852/4,073,339
- Zero source tangents using per-triangle UV fallback: 27,487 (0.675%)
- Triangles: 4,209,006
- Expanded mesh primitives: 2,909
- Materials: 254
- Materials with normal maps: 207
- Unique normal maps: 119
- Total unique diffuse/specular/emission/normal textures: 338
- Referenced images present and decoded: 338/338
- CPU-only VkNRC OBJ parse: successful
- Legacy OBJ without the tangent marker: successful
- Vulkan device created during preparation: no

## Generated input

- OBJ size: 1,205,301,939 bytes
- OBJ SHA-256: `2702657591D022ABB3DF484A5AB04CA60DFBD873D705E04F7E34F9DF6AC15710`
- MTL SHA-256: `E0DF0C40508F9FEE1F6A68E20E54A313F4823F1837200F161C8D99A56415B8FC`
- Manifest SHA-256: `A421AF36B98B4296A2A8206E0B52A8200E9BD798C17EA63EB56BBE03E81958C0`

## Representation

The converter writes glTF vertex normals as OBJ `vn` records. It preserves
glTF tangent direction and handedness in the RGB vertex-color fields behind an
explicit `# vknrc_tangents_in_vertex_colors 1` marker. VkNRC ignores ordinary
OBJ vertex colors unless this marker is the first line, so existing inputs keep
their previous behavior.

Normal textures are emitted through the tinyobjloader PBR `norm` directive and
uploaded as linear `VK_FORMAT_R8G8B8A8_UNORM` images. Color textures remain
sRGB. The shader interpolates vertex normals and source tangents, orthogonalizes
the tangent against the shading normal, restores handedness, and transforms the
sampled tangent-space normal. Missing or zero tangents reconstruct the basis
from triangle positions and UVs.

## GPU validation

The Release shader/C++ build passes and both generated and legacy scenes pass
CPU-only parsing. GPU validation subsequently reproduced WhiteOut within the
60-frame smoke and confirmed non-finite network output in the 3,600-frame A/B.
See the [Bistro normal-map WhiteOut reproduction](2026-09-11-bistro-normal-map-whiteout-ab.md).
