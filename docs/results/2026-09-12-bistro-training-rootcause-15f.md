# Bistro training root-cause diagnostic — 15 frames

This fixed-seed A/B diagnostic measures the first 15 training frames before the
formal display WhiteOut onset. Both runs completed with finite metrics and did
not meet the display criterion within the short window.

## Conditions

- A: bootstrap on, training on, display contribution on
- B: bootstrap off, valid PT-only targets, training on, display contribution on
- Bistro normal-map scene, RTXGI reference lighting, seed 1
- 15 frames, 1280x720, fixed Hejl 2015 tone map, overlay off

## Result

The screen and training prediction distributions rise throughout the run in
both A and B. The coarse log2 histogram places screen-prediction p50 near zero
at frame 1, then in bins centered near 0.71, 1.41, 2.83, 45.25 and 181.02 at
frames 2, 3, 5, 10 and 15. These bin centers must not be interpreted as precise
doubling measurements.

A fills all 65,536 record slots per frame, with roughly 7.6–8.0k PT-complete
records and 57.5–57.9k bootstrap-completed records. B accepts roughly 9.7–13.1k
PT-complete records and rejects approximately 66–89k records from unfinished
paths. Despite this large source and batch-size difference, the global
prediction rise is similar.

PT-only targets have a median luminance bin near 5.66 but a very heavy tail:
p99 varies roughly from 11 to 362 and p99.9 from 3.7e5 to 3.0e6. All measured
gradients, updates and weights remain finite. Weight p99 stays near 0.354 and
the optimizer-update p99 stays around 0.001–0.0028, so the first 15 frames do
not show a simple scalar weight explosion.

## Source semantics

The implemented loss output derivative is

`2 * (prediction - target) / (prediction_luminance^2 + 0.01)`.

The denominator is effectively detached because its derivative is not included
in the handwritten backpropagation. Gradients are reduced by dividing their
batch sum by record count. Each record has equal weight, but one selected path
emits one record per stored bounce; consequently a longer path receives more
total weight than a shorter path.

Targets and predictions are trained in linear RGB without a target-domain log
or compression transform. Training uses the raw network prediction, including
negative values, while rendering clamps finite predictions to non-negative
before resolve. This train/render asymmetry is another candidate to isolate.

The evidence supports bootstrap not being necessary, a heavy-tailed PT target
distribution, and finite updates producing a rapid global prediction increase.
It does not yet identify the target tail, loss normalization, per-path
weighting, or domain asymmetry as the unique root cause.

Artifacts:

- `build-vs/bootstrap-isolation/20260912-training-rootcause-15f-v2/A.stdout.log`
  SHA-256 `F4F04ED828CD150D125F7CCD5C7C24AD8E33197EAA7E4CC0C7B612B58341F592`
- `build-vs/bootstrap-isolation/20260912-training-rootcause-15f-v2/B.stdout.log`
  SHA-256 `E6C389AE4E474244B06FA7AA1465AB4F2A2711259BEAE826B39A3D8C5DA84B24`
