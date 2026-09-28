# Bootstrap-dependent NRC divergence isolation

This experiment deliberately separates NRC divergence from display WhiteOut.
The existing raw-prediction `> 100` and non-finite counters are diagnostic
signals only; neither signal is a display WhiteOut verdict.

## Controls

- `--nrc-bootstrap-off` accepts only fully path-traced training targets. An
  unfinished path is discarded before train slots are reserved, so partial or
  stale records cannot reach the optimizer.
- `--nrc-training-off` holds the initial model fixed by setting the training
  probability to zero.
- `--nrc-contribution-off` evaluates and trains NRC normally but excludes the
  NRC contribution from the displayed resolve result.

## Preflight matrix

`run-bootstrap-isolation.ps1` executes four same-seed conditions:

| Condition | Bootstrap | Training | Display contribution |
|---|---:|---:|---:|
| A | on | on | on |
| B | off | on | on |
| C | off | off | on |
| D | on | on | off |

Start with 60 frames. This run checks causal separation and command plumbing;
it must be reported as `RAPID_BOOTSTRAP_DEPENDENT_NRC_DIVERGENCE_CANDIDATE`,
not as confirmed WhiteOut. A display verdict additionally requires fixed
tone-mapping, pre-overlay final-image measurement, spatial coverage and
three-frame persistence.

```powershell
.\tools\run-bootstrap-isolation.ps1 `
  -Scene .\build-vs\scenes\bistro-full\bistro.obj `
  -Frames 60 -Seed 1 -RTXGIReferenceLighting
```

Use `-DryRun` to validate all four commands without creating a Vulkan device.

Add `-FrameMetrics` to enable per-frame histograms and counters for Before
Resolve, screen prediction, factor, contribution, After Resolve, tone-mapped
pre-overlay final, PT-only and bootstrap targets, training prediction/loss,
gradient, optimizer update, weight and EMA-weight magnitude. Source counters
report generated, PT-accepted, bootstrap-accepted and incomplete-rejected
records. The instrumentation is disabled during normal rendering.

The first 60-frame result is documented in
[Bistro bootstrap isolation preflight](results/2026-09-11-bistro-bootstrap-isolation-preflight.md).

The fixed-tone-map, pre-overlay A/B/C/D result is documented in
[Bistro formal WhiteOut isolation](results/2026-09-12-bistro-formal-whiteout-isolation.md).

The early training-distribution comparison is documented in
[Bistro training root-cause diagnostic](results/2026-09-12-bistro-training-rootcause-15f.md).

The Path Tracer BRDF tail audit and isolated Walter G1 A/B are documented in
[Bistro Path Tracer BRDF/PDF tail diagnostic](results/2026-09-16-bistro-brdf-tail-60f.md)
and [Bistro Walter G1 isolated A/B](results/2026-09-16-bistro-walter-g1-fix-60f.md).
