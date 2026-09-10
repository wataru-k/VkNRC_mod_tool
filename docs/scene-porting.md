# RTXGI scene porting

VkNRC accepts OBJ/MTL input, while the RTXGI sample scenes are glTF models
assembled by a `.scene.json` manifest. The checked-in converter bridges these
formats without redistributing the source scene assets.

## LivingRoom

The LivingRoom port includes both models declared by `LivingRoom.scene.json`:

- `LivingRoom/living_room.gltf`
- `GltfSampleModels/2.0/BrainStem/glTF/BrainStem.gltf`, including its graph transform

It expands the glTF node transforms, retains UVs and constant material factors,
copies all 16 referenced JPEG base-color textures, and writes a VkNRC manifest
containing the normalized camera position and vertical FOV.

```powershell
node .\tools\convert-rtxgi-scene-to-vknrc.mjs `
  E:\RTXGI_mod_tool_4\Assets\Media\LivingRoom.scene.json `
  .\build-vs\scenes\living-room\living-room.obj
```

CPU-only parsing validation does not create a Vulkan device:

```powershell
.\build-vs\Release\VkNRC.exe `
  .\build-vs\scenes\living-room\living-room.obj `
  --validate-scene-only
```

`run-whiteout-ab.ps1` automatically finds the adjacent
`living-room.vknrc.json` file and applies its normalized camera position and FOV
to both A/B runs.

```powershell
.\tools\run-whiteout-ab.ps1 `
  -Scene .\build-vs\scenes\living-room\living-room.obj `
  -Frames 3600 -Threshold 100 -Seed 1
```

Generated OBJ, MTL, copied textures and manifests remain under ignored
`build-vs`. The original assets remain owned by the adjacent RTXGI repository.

## Fidelity boundary

The port preserves scene composition, mesh transforms, triangle topology,
base-color textures, constant material factors, camera position and FOV. VkNRC
still uses its own Cook-Torrance implementation, hard-coded environment light
and filmic tone mapper, so this is an asset/camera port rather than a claim of
pixel-identical RTXGI rendering.

## Bistro DDS preparation

Bistro uses DDS textures. Download and verify the pinned Microsoft DirectXTex
converter, then pass it to the scene converter:

```powershell
$texconv = (.\tools\prepare-directxtex.ps1).path
node .\tools\convert-rtxgi-scene-to-vknrc.mjs `
  E:\RTXGI_mod_tool_4\Assets\Media\Bistro.scene.json `
  .\build-vs\scenes\bistro-full\bistro.obj `
  --texconv $texconv
```

The pinned `may2026` `texconv.exe` SHA-256 is
`DCFDEC10244E02CF5037FBA089C55FB7E1326B1C8181742D77D15FA5CB5EEF06`.
Only textures consumed by VkNRC (diffuse, specular and emission) are converted;
normal maps are omitted because the current VkNRC material/shader path has no
normal-map input.

