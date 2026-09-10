# Whiteout diagnostics

VkNRC can produce a finite but very large neural radiance prediction. The
original inference path clamps negative RGB values to zero, but does not bound
positive values before adding the prediction to the HDR render target. The
filmic tone mapper can therefore turn widespread large predictions into an
apparently white frame even when no NaN or infinity is present.

## Controls

The NRC panel exposes three experimental controls:

- **Whiteout Diagnostic** marks a non-finite raw network prediction in magenta
  and a finite prediction above the configured luminance threshold in red.
- **Experimental Whiteout Guard** scales an over-threshold prediction so that
  its luminance equals the configured threshold. It applies to both screen
  resolve and bootstrap training records.
- **Whiteout Luminance** configures the diagnostic and guard threshold. The
  default is `100.0` in linear HDR units.

All controls are disabled by default except for the threshold value. Changing
a control clears display accumulation so that an old accumulated frame does not
mask the new condition.

The same settings can be selected from the command line. `--frames` closes the
application cleanly after a fixed number of rendered frames, which is useful for
repeatable unattended runs:

```powershell
.\build-vs\Release\VkNRC.exe scene.obj `
  --whiteout-diagnostic `
  --whiteout-threshold 100 `
  --seed 1 `
  --frames 3600
```

Add `--whiteout-guard` only for an A/B guard run. The command-line settings are
also reflected in the UI and may be changed while the application is running.
On clean shutdown, VkNRC logs the total evaluated predictions, non-finite
predictions, predictions over the selected threshold, and the maximum finite
prediction luminance. These counters are collected on the GPU and make a fixed
frame run machine-verifiable without relying only on a screenshot.

Use the same `--seed` value for guard-off and guard-on runs. It fixes both MLP
weight initialization and the generated per-frame random seed sequence. GPU
atomic scheduling and floating-point order can still vary, so this controls the
stochastic inputs but does not guarantee bitwise-identical runs. If omitted,
VkNRC selects and logs a random seed.

The two-run wrapper records both logs and a parsed `summary.json`:

```powershell
.\tools\run-whiteout-ab.ps1 `
  -Scene .\test\scenes\whiteout-smoke\smoke.obj `
  -Frames 3600 -Threshold 100 -Seed 1
```

VkNRC accepts OBJ input only. For a glTF asset such as the RTXGI Bistro scene,
prepare a geometry-only OBJ without using the GPU:

```powershell
node .\tools\convert-gltf-to-vknrc-obj.mjs `
  E:\RTXGI_mod_tool_4\Assets\Media\Bistro\bistro.gltf `
  .\build-vs\scenes\bistro\bistro.obj
```

The converter expands glTF node transforms and instances into OBJ geometry and
retains constant material factors. It deliberately omits DDS textures because
VkNRC's current stb_image-based OBJ path cannot load them. Results from this
conversion therefore test whiteout stability, not texture-faithful image quality.

## Experiment protocol

1. Start from freshly initialized weights using **Re-Train**.
2. Keep the scene, camera, resolution, training state, EMA selection and random
   seed policy identical between runs.
3. Run with the diagnostic enabled and guard disabled. Record the first frame
   at which red or magenta appears and whether it spreads across the frame.
4. Repeat from freshly initialized weights with the guard enabled.
5. Compare both the resolved image and accumulated display against a finite,
   NRC-disabled reference.

The guard is a diagnostic safety mechanism, not a production fix. A per-query
luminance cap can introduce dark bias, and a successful run on one scene or GPU
does not establish general stability.

## Recorded results

- [RTX 4090 closed-room smoke A/B, 2026-09-11](results/2026-09-11-whiteout-smoke.md)
- [Bistro GPU-run preparation, 2026-09-11](results/2026-09-11-bistro-preparation.md)
- [RTX 4090 Bistro fixed-seed A/B, 2026-09-11](results/2026-09-11-bistro-whiteout-ab.md)
- [LivingRoom port CPU preparation, 2026-09-11](results/2026-09-11-living-room-preparation.md)
- [RTX 4090 LivingRoom fixed-seed A/B, 2026-09-11](results/2026-09-11-living-room-whiteout-ab.md)
