# Bistro whiteout A/B result — 2026-09-11

## Outcome

The fixed-seed, 3,600-frame Bistro A/B run completed successfully on an RTX
4090. Neither run produced a non-finite prediction or a finite prediction above
the configured luminance threshold of 100. Whiteout was not reproduced under
these conditions, and the experimental guard was never activated.

## Environment and input

- Commit: `79e0863d0ad44371b91b4891b805c08f441dfd7d`
- GPU: NVIDIA GeForce RTX 4090
- Driver: 616.56
- Resolution: 1280 x 720
- Frames per run: 3,600
- Seed: 1
- Threshold: 100 linear HDR units
- OBJ SHA-256: `793CD18BCD76FAA116DEC443A840F9B2169D6B85D5604E17F8A2D0C1B423BC92`

## Results

| Guard | Evaluated predictions | Non-finite | Over threshold | Maximum luminance | Exit |
|---|---:|---:|---:|---:|---:|
| Off | 3,135,181,071 | 0 | 0 | 18.231560 | 0 |
| On | 3,135,181,544 | 0 | 0 | 18.716967 | 0 |

The complete machine-readable result is in
[`2026-09-11-bistro-whiteout-ab.json`](2026-09-11-bistro-whiteout-ab.json).

## Interpretation and limits

`--seed 1` fixes MLP initialization and the generated per-frame seed sequence.
The two runs nevertheless differed by 473 evaluated predictions and by about
0.49 in maximum luminance. GPU atomic scheduling and floating-point reduction
order remain nondeterministic, so a fixed seed controls the stochastic inputs
but does not guarantee bitwise-identical execution.

The source Bistro glTF was converted to OBJ with node transforms and constant
material factors, but without its DDS textures. This result is therefore strong
evidence that standalone VkNRC does not inevitably white out on the tested
Bistro geometry over 3,600 frames. It does not prove that whiteout is impossible
across other seeds, longer runs, textured-material behavior, camera views, GPU
models, or the separate RTXGI integration.

