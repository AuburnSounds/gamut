# software-mlaa: possible enhancements

Roughly in priority order. Most of these already exist in the SMAA reference
(https://github.com/iryoku/smaa, MIT), so they can be ported the same way as the core.

## Clear quality wins

2. **Diagonal pattern detection.** => didn't work out, overly blurry

3. **Colour edge detection.**
   Tune those thresholds.

4. **Keep sharp corners sharp.**
   MLAA rounds the corners of rectangles, UI elements and text.
   SMAA's corner detection (`SMAA_CORNER_ROUNDING`) controls how much corners get
   rounded. Matters for UI and rendered-text images.

## Smaller refinements

5. **Local contrast adaptation.**
   A strong edge next to a weak edge running across it can cut a long line into short
   pieces, which then get poor blending. SMAA ignores an edge when a neighbouring edge
   has more than twice its contrast (`SMAA_LOCAL_CONTRAST_ADAPTATION_FACTOR`).
   Also reduces false edges in textured areas.

6. **Smooth small U-shapes.**
   One-pixel bumps get the full blend from both sides, which can wash out small details.
   SMAA's `smootharea` in `AreaTex.py` reduces this for short shapes.

7. **Longer search.**
   The search stops at `MLAA_MAX_SEARCH_DISTANCE` (32 pixels) each side, so very shallow
   edges (slope below about 1/64) lose part of their gradient. A larger limit is cheap
   on the CPU, since only edge pixels pay for it.

## Not quality, but worth doing

8. **Speed.**
   The code is plain scalar D, unlike the SIMD `software-fxaa`. Edge detection and
   blending vectorise easily, and rows can be processed in parallel.

9. **Transparency.**
   Colour and alpha are blended separately, which can leave coloured fringes on
   semi-transparent edges. Blending with premultiplied alpha avoids that.

## Out of reach

MLAA only reshapes the pixels it is given. A feature thinner than a pixel that is
already broken into dots can't be recovered. That needs more samples, from
supersampling or a temporal method, both out of scope for this example.

## Testing

Add matching test patterns to the synthetic test image so each change can be
checked in before/after comparisons:
- a 45° edge (for 2),
- an edge between two colours of equal brightness (for 3),
- an axis-aligned rectangle (for 4),
- a very shallow edge, slope below 1/64 (for 7).
