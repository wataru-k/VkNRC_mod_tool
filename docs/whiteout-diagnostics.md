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
