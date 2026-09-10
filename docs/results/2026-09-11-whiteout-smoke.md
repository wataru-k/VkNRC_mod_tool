# Whiteout smoke A/B result — 2026-09-11

## Environment

- GPU: NVIDIA GeForce RTX 4090
- Resolution: 1280 x 720
- Scene: `test/scenes/whiteout-smoke/smoke.obj`
- Frames per run: 3,600
- Diagnostic luminance threshold: 100 linear HDR units
- Build: Release, commit `5917653`

## Commands

```powershell
.\build-vs\Release\VkNRC.exe .\test\scenes\whiteout-smoke\smoke.obj `
  --whiteout-diagnostic --whiteout-threshold 100 --frames 3600

.\build-vs\Release\VkNRC.exe .\test\scenes\whiteout-smoke\smoke.obj `
  --whiteout-diagnostic --whiteout-guard --whiteout-threshold 100 --frames 3600
```

## Results

| Guard | Evaluated predictions | Non-finite | Over threshold | Maximum luminance | Exit |
|---|---:|---:|---:|---:|---:|
| Off | 3,352,559,905 | 0 | 0 | 22.653128 | 0 |
| On | 3,352,492,207 | 0 | 0 | 24.631264 | 0 |

No whiteout-class prediction was observed in this synthetic closed-room smoke
test. The guard was not activated because no prediction exceeded the threshold.

## Claim boundary

This result verifies the executable, NRC inference/training path, diagnostic
counters, fixed-frame termination, and guard plumbing on the tested RTX 4090.
It does not establish stability on Bistro or another production scene. The two
runs also use independently randomized initial weights and frame seeds, so this
is a stability A/B smoke test rather than an identical-seed numerical comparison.

