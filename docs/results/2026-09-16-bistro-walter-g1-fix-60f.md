# Bistro Walter G1 isolated A/B (2026-09-16)

## Verdict

The erroneous multiplier in `Walter_G1` is a causal WhiteOut driver in the
tested Bistro condition.

Changing only the G1 visibility term eliminated formal WhiteOut within 60
frames and collapsed the finite BRDF, PT-target, and NRC-prediction tails.
The sampler and PDF code were intentionally left unchanged.

## Isolated change

Baseline computes:

```glsl
max(v_dot_h / v_dot_n, 0) * beckmann_g1_approximation
```

The fixed runtime condition `--brdf-walter-g1-fix` computes:

```glsl
(v_dot_h / v_dot_n > 0) ? beckmann_g1_approximation : 0
```

This implements the intended visibility indicator rather than using the ratio
as an unbounded energy multiplier. The default remains baseline-compatible;
the fix is enabled only by the command-line flag for this experiment.

## Controlled conditions

Both sides use Bistro, seed 1, RTXGI reference lighting, NRC bootstrap/training/
display contribution enabled, 60 frames, and the same formal fixed-tone-map
WhiteOut definition.

- Baseline: `build-vs/bootstrap-isolation/20260916-bistro-brdf-tail-v2`
- Fixed: `build-vs/bootstrap-isolation/20260916-bistro-walter-g1-fix-60f-v1`

Fixed-run completeness:

- 19 stages x 60 frames = 1,140/1,140
- 921,600 pixels for 60/60 frames
- BRDF counters for 60/60 frames
- fix flag logged as `true`
- exit code 0, empty stderr

## A/B result

| Metric | Baseline | Walter G1 fix | Change |
|---|---:|---:|---:|
| Formal WhiteOut | yes | no | eliminated |
| First WhiteOut frame | 42 | none | — |
| Maximum consecutive WhiteOut frames | 19 | 0 | eliminated |
| Finite BRDF throughput maximum | 13,379,788 | 2,075.61 | 6,446x lower |
| Maximum per-frame throughput p99 | 2,896.31 | 1.414 | 2,048x lower |
| Maximum per-frame throughput p99.9 | 185,363.80 | 1.414 | 131,072x lower |
| PT target maximum | 1.5247931e12 | 29.34 | 5.197e10x lower |
| NRC raw maximum | 10,967.98 | 5.68 | 1,931x lower |

## Important control observation

The following counts are identical between baseline and fixed runs:

- total BRDF samples: 120,887,417
- below-hemisphere samples: 3,482,606
- bad PDFs: 3,596,065
- non-finite pre-sanitization throughput: 3,482,606

Therefore this A/B did not repair or hide the sampler/PDF failures. It changed
the finite energy scale produced by G1, while preserving the measured sample
population and invalid-sample counts. This makes the collapse of the finite
tail and disappearance of WhiteOut specifically attributable to the G1 term
under this condition.

## Claim boundary

Supported:

- The legacy `v_dot_h / v_dot_n` multiplier causes the observed finite heavy
  tail and is necessary for the measured 60-frame Bistro WhiteOut under this
  configuration.
- Replacing it with the visibility indicator prevents that WhiteOut in the
  tested run.

Not supported:

- that the complete path tracer is now correct;
- that the fix prevents WhiteOut in every scene, camera, seed, or duration;
- that below-hemisphere, bad-PDF, shading-normal, or NRC-input-normal defects
  are harmless.

Those remaining failures still require separate fixes and tests.
