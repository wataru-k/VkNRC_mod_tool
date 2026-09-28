# Bistro formal WhiteOut isolation — 2026-09-12

The fixed-seed 60-frame A/B/C/D experiment confirms display WhiteOut under the
reviewed spatial and temporal definition. It also rejects bootstrap completion
as the sole cause under the tested implementation.

## Definition and validity

The measurement uses the diagnostic-overlay-free image after fixed Hejl 2015
tone mapping with white point 3.2. A frame is a candidate when at least 50% of
pixels satisfy `Y >= 0.95` and `max(RGB)-min(RGB) <= 0.05`, and this coverage is
at least 25 percentage points above Before Resolve. Three consecutive candidate
frames confirm `DISPLAY_WHITEOUT`.

Every condition produced 60 valid frame records with 921,600 pixels per frame.
All measured stages were finite. A preflight found that the original shader
could feed a slightly negative tone-map result to fractional `pow`; the formal
run clamps the tone-map result to zero before gamma encoding.

## Results

| Condition | Bootstrap | Training | Display contribution | WhiteOut | First frame | Max consecutive |
|---|---:|---:|---:|---:|---:|---:|
| A | on | on | on | yes | 37 | 24 |
| B | off | on | on | yes | 36 | 25 |
| C | off | off | on | no | — | 0 |
| D | on | on | off | no | — | 0 |

Before Resolve white coverage remained approximately 3.45%. In A it rose from
49.84% at frame 36 to 51.23%, 52.32% and 53.49% at frames 37–39. In B it reached
50.40% at frame 36 and remained above the threshold, confirming WhiteOut from
frame 36.

At frame 36, A had raw-prediction p50 near 1,448 and NRC-contribution p50 near
22.63; contribution/After Resolve p99 was near 2.97e6. B had a similar raw p50,
with contribution p50 near 11.31 and p99 near 1.48e6. Condition D retained the
internal raw and contribution divergence but excluded it from After Resolve,
and its final image exactly followed Before Resolve for the WhiteOut metric.

## Conclusion

The displayed WhiteOut is caused by the trained NRC contribution entering the
resolve. Training is a necessary condition in this matrix; display contribution
is also necessary. Strict bootstrap-off mode discards unfinished paths before
reserving train records, yet WhiteOut still occurs one frame earlier than in the
bootstrap-on run. Bootstrap completion is therefore neither a necessary
condition nor the sole cause of this 60-frame failure.

The earlier observation that “Bootstrap OFF prevents WhiteOut” likely used a
control that also disabled training or another training path. That exact prior
control must be mapped against the new flags before comparing conclusions.

Artifacts are under
`build-vs/bootstrap-isolation/20260912-bistro-formal-60f/`. The summary SHA-256
is `925BF76D1D8DAFDB9C97813A165E7A499F834CE28B0A1F72AF1905CAC5E4EA2B`.
The canonical corrected metadata is stored in
[`2026-09-12-bistro-formal-whiteout-isolation.json`](2026-09-12-bistro-formal-whiteout-isolation.json);
the generated artifact itself is intentionally unchanged.
