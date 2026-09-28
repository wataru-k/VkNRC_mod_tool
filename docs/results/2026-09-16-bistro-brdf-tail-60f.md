# Bistro Path Tracer BRDF/PDF tail diagnostic (2026-09-16)

## Verdict

The current path-tracer BRDF sampling implementation is not valid as-is.
In the real Bistro workload, it generates below-hemisphere samples, invalid
PDF divisions, and very large finite path weights before NRC training.

The result supports this causal sequence:

1. The path tracer supplies a persistent heavy-tailed target distribution.
2. NRC training progressively raises its raw prediction.
3. The NRC display contribution crosses the formal WhiteOut criterion later.

This is stronger than a CPU-only counterexample, but it does not yet isolate
which combination of `Walter_G1`, hemisphere handling, shading normals, and
roughness is the dominant finite-tail source.

## Valid run

- Artifact: `build-vs/bootstrap-isolation/20260916-bistro-brdf-tail-v2`
- Scene: Bistro
- Frames: 60
- Seed: 1
- RTXGI reference lighting: on
- NRC bootstrap/training/display contribution: on/on/on
- Exit code: 0
- stderr: empty
- Metrics: 19 stages x 60 frames = 1,140/1,140 records
- Display pixels: 921,600 for 60/60 frames

The first `v1` run is explicitly marked invalid. A missing CMake dependency
left old SPIR-V buffer offsets in non-path-tracer shaders. The dependency was
fixed by adding `Diagnostics.glsl` to `SHADER_HEADER`, all shaders were rebuilt,
and `v2` was written to a new directory.

## BRDF estimator observations

Across 120,887,417 BRDF samples:

- below the shading-normal hemisphere: 3,482,606 (2.880867%)
- bad/non-positive/non-finite PDF: 3,596,065 (2.974722%)
- non-finite pre-sanitization throughput: 3,482,606 (2.880867%)
- maximum finite one-step throughput: 13,379,788 (frame 18)
- maximum per-frame p99: 2,896.31
- maximum per-frame p99.9: 185,363.80

The non-finite weights are later converted to zero by `NormalizeRGB`. They are
therefore primarily evidence of an invalid/biasing estimator path, not direct
positive-energy WhiteOut pixels. The finite tail is the more plausible source
of extreme positive training targets.

## Training and display observations

- PT target maximum: 1.5247931e12, already present in frame 1
- PT target maximum per-frame p99.9: 2.9658208e6
- NRC raw maximum: 1.0967975e4 at frame 60
- formal display WhiteOut: detected
- first WhiteOut frame: 42
- maximum consecutive WhiteOut frames: 19

Selected raw-prediction progression:

| Frame | p50 | p99 | Maximum |
|---:|---:|---:|---:|
| 1 | ~0 | 0.18 | 1.12 |
| 10 | 45.25 | 45.25 | 67.75 |
| 20 | 362.04 | 362.04 | 572.70 |
| 30 | 724.08 | 1,448.15 | 1,647.04 |
| 40 | 2,896.31 | 2,896.31 | 3,704.42 |
| 42 | 2,896.31 | 2,896.31 | 4,114.45 |
| 60 | 5,792.62 | 11,585.24 | 10,967.98 |

Histogram percentiles are log2-bin estimates and must not be interpreted as
exact sample percentiles. Maxima are recorded directly.

## Interpretation

The enormous PT target exists before NRC has learned a large output, while the
NRC raw prediction rises over subsequent frames and WhiteOut begins at frame
42. This temporal ordering rules out the interpretation that NRC alone creates
all extreme energy from an otherwise well-behaved PT target.

The added atomic diagnostics can perturb scheduling and sample order, so the
first WhiteOut frame must not be compared exactly with the earlier uninstrumented
frame-37 result. The classification, tail scale, and temporal ordering are the
relevant observations.

## Next isolation

The next A/B should correct only the path-tracer estimator while leaving NRC
loss, optimizer, seed, scene, and display definition unchanged:

1. reject sampled directions outside the geometric and shading hemispheres;
2. reject non-positive/non-finite PDFs before division;
3. replace the erroneous `v_dot_h / v_dot_n` multiplier in `Walter_G1` with the
   intended visibility test and keep `G1` bounded to `[0,1]`;
4. use geometric-normal-aware shading-normal correction;
5. make NRC input reconstruct the same shading normal used by the teacher.

Run each change separately before combining them, because the current evidence
does not assign the finite tail to one unique defect.
