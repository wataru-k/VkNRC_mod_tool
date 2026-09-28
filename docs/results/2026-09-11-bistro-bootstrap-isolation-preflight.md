# Bistro bootstrap isolation preflight — 2026-09-11

This 60-frame, fixed-seed experiment tested the causal controls requested by
the WhiteOut review. It is an NRC divergence preflight, not a
`DISPLAY_WHITEOUT` verdict: only raw NRC prediction diagnostics were measured.
The diagnostic color overlay was disabled.

## Fixed conditions

- Scene: normal-mapped Bistro conversion
- Camera: conversion manifest camera
- Seed: 1
- Frames: 60 per condition
- Lighting: RTXGI reference preset
- GPU: NVIDIA GeForce RTX 4090
- Execution: four sequential processes, no retry

## Results

| Condition | Bootstrap | Training | Display contribution | Evaluated | Non-finite | Raw Y > 100 | Fraction | Max raw Y |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| A | on | on | on | 48,569,070 | 0 | 38,756,472 | 79.80% | 11,939.859 |
| B | off | on | on | 47,640,769 | 0 | 37,693,371 | 79.12% | 6,001.6704 |
| C | off | off | on | 47,640,769 | 0 | 0 | 0% | 1.4593168 |
| D | on | on | off | 48,569,035 | 0 | 38,684,438 | 79.65% | 11,701.735 |

All processes exited zero, all stderr logs were empty, and no target process
remained after the run.

## Interpretation

Disabling bootstrap did not remove the widespread raw-prediction threshold
crossing at frame 60, although it reduced the maximum by roughly half. Holding
the initial model fixed by disabling training removed it completely. The
current evidence therefore supports a rapid **training-dependent raw NRC
divergence**, but does not support bootstrap as the sole cause.

This does not contradict the visual observation that disabling bootstrap
prevents displayed whitening. Raw prediction alone is not the resolved NRC
contribution: `factor * prediction`, After Resolve HDR and the fixed-tone-map
pre-overlay image still need to be measured. The smaller maximum in condition B
could also be material at the resolve stage.

The generated summary is under
`build-vs/bootstrap-isolation/20260911-bistro-60f-preflight/summary.json` with
SHA-256
`F3A34E1EA3039327AF6E6D8C08B1FBC1524826122DC12AFA002FB5F99AC1F777`.
