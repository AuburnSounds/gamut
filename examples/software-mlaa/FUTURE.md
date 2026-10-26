# software-mlaa: possible enhancements

Roughly in priority order. Most of these already exist in the SMAA reference
(https://github.com/iryoku/smaa, MIT), so they can be ported the same way as the core.


## Smaller refinements

6. **Smooth small U-shapes.**
   One-pixel bumps get the full blend from both sides, which can wash out small details.
   SMAA's `smootharea` in `AreaTex.py` reduces this for short shapes.

7. **Longer search.**
   The search stops at `MLAA_MAX_SEARCH_DISTANCE` (32 pixels) each side, so very shallow
   edges (slope below about 1/64) lose part of their gradient. A larger limit is cheap
   on the CPU, since only edge pixels pay for it.

## Not quality, but worth doing


9. **Transparency.**
   Colour and alpha are blended separately, which can leave coloured fringes on
   semi-transparent edges. Blending with premultiplied alpha avoids that.
ersampling or a temporal method, both out of scope for this example.

