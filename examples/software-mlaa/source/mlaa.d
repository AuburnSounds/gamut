module mlaa;

/*
 * Copyright (C) 2013 Jorge Jimenez (jorge@iryoku.com)
 * Copyright (C) 2013 Jose I. Echevarria (joseignacioechevarria@gmail.com)
 * Copyright (C) 2013 Belen Masia (bmasia@unizar.es)
 * Copyright (C) 2013 Fernando Navarro (fernandn@microsoft.com)
 * Copyright (C) 2013 Diego Gutierrez (diegog@unizar.es)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software. As clarification, there is no
 * requirement that the copyright notice and permission be included in binary
 * distributions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 * FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 * IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

// CPU port of the MLAA core of SMAA:
//   https://github.com/iryoku/smaa (SMAA.hlsl and Scripts/AreaTex.py)
//
// Algorithm from:
//   Alexander Reshetov, "Morphological Antialiasing", HPG 2009.
//   Jimenez et al., "Practical Morphological Antialiasing", GPU Pro 2, 2011.
//
// Only the MLAA part of SMAA is ported, that is SMAA 1x with:
//  - luma + chroma edge detection, without local contrast adaptation,
//  - no diagonal pattern detection,
//  - corner detection, to keep sharp corners sharp,
//  - no temporal supersampling / reprojection (SMAA T2x, 4x),
//    there is no history buffer and no subpixel jitter.
//
// The three passes are the same as in SMAA:
//  1. Edge detection.
//  2. Blending weights calculation: search the extent of each edge line,
//     classify its shape with the crossing edges at its ends, and compute
//     the area covered by the revectorized line.
//  3. Neighborhood blending.
//
// Since we are on the CPU, there is no need for the pre-computed area
// texture and search texture of SMAA: the area is computed analytically
// and searches are done one pixel at a time.

import core.stdc.stdlib;
import core.stdc.math: fabs, floor, powf;

nothrow @nogc:

// Edge sensitivity, in luma units (0 to 1). Like SMAA_THRESHOLD, but
// lower than its 0.1 default, which was rated better on game images.
enum float MLAA_THRESHOLD = 0.08f;

// Edge sensitivity, in chroma units (Cb or Cr, -0.5 to 0.5).
// Catches edges between colours of similar luma. Higher than
// MLAA_THRESHOLD, since chroma noise is common and the eye is less
// sensitive to chroma detail.
/* @tuning */ enum float MLAA_CHROMA_THRESHOLD = 0.14f;

// Maximum search distance, in pixels, at each side of a pixel.
enum int MLAA_MAX_SEARCH_DISTANCE = 32;

// How much sharp corners are rounded, from 0 (kept sharp) to 1 (fully
// rounded, as plain MLAA). Same as SMAA_CORNER_ROUNDING / 100.
/* @tuning */ enum float MLAA_CORNER_ROUNDING = 0.1f;

// Edge flags.
enum : ubyte
{
    EDGE_LEFT = 1, // edge between (x-1, y) and (x, y)
    EDGE_TOP  = 2, // edge between (x, y-1) and (x, y)
}

// MLAA filter.
void mlaa_32bit(
    const int width,            // width in pixels
    const int height,           // height in pixels
    const(ubyte)* inPixels,     // input image (only RGBA8 supported)
    const int inputPitchBytes,  // input pitch, in bytes
    ubyte* outPixels,           // output image (only RGBA8 supported)
    const int outputPitchBytes, // output pitch, in bytes
    bool showEdges = false)     // debug: output the edges instead
{
    if (width <= 0 || height <= 0)
        return;

    size_t N = cast(size_t)width * height;
    float* ycc     = cast(float*) malloc(N * 3 * float.sizeof);
    ubyte* edges   = cast(ubyte*) malloc(N);
    float* weights = cast(float*) malloc(N * 4 * float.sizeof);
    scope(exit)
    {
        free(ycc);
        free(edges);
        free(weights);
    }

    // 1. Edge detection.
    //
    // An edge is where luma changes by MLAA_THRESHOLD, as SMAA luma edge
    // detection, or where Cb or Cr changes by MLAA_CHROMA_THRESHOLD.
    // The chroma test finds edges between colours of similar brightness,
    // that luma alone misses (like SMAAColorEdgeDetectionPS), while being
    // less sensitive to noise than a per-channel RGB difference.

    for (int y = 0; y < height; ++y)
    {
        const(ubyte)* scan = inPixels + y * inputPitchBytes;
        for (int x = 0; x < width; ++x)
        {
            const(ubyte)* p = &scan[x*4];
            float r = p[0] / 255.0f;
            float g = p[1] / 255.0f;
            float b = p[2] / 255.0f;
            float Y = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            float* o = &ycc[(y*width+x)*3];
            o[0] = Y;
            o[1] = (b - Y) / 1.8556f; // Cb, BT.709
            o[2] = (r - Y) / 1.5748f; // Cr, BT.709
        }
    }

    bool isEdge(const(float)* a, const(float)* b)
    {
        return fabs(a[0] - b[0]) >= MLAA_THRESHOLD
            || fabs(a[1] - b[1]) >= MLAA_CHROMA_THRESHOLD
            || fabs(a[2] - b[2]) >= MLAA_CHROMA_THRESHOLD;
    }

    for (int y = 0; y < height; ++y)
    {
        for (int x = 0; x < width; ++x)
        {
            const(float)* P = &ycc[(y*width+x)*3];
            ubyte e = 0;
            if (x > 0 && isEdge(P, P - 3))
                e |= EDGE_LEFT;
            if (y > 0 && isEdge(P, P - width*3))
                e |= EDGE_TOP;
            edges[y*width+x] = e;
        }
    }

    if (showEdges)
    {
        for (int y = 0; y < height; ++y)
        {
            ubyte* dst = outPixels + y * outputPitchBytes;
            for (int x = 0; x < width; ++x)
            {
                ubyte e = edges[y*width+x];
                dst[x*4+0] = (e & EDGE_LEFT) ? 255 : 0;
                dst[x*4+1] = (e & EDGE_TOP) ? 255 : 0;
                dst[x*4+2] = 0;
                dst[x*4+3] = 255;
            }
        }
        return;
    }

    // 2. Blending weights calculation.
    //
    // For each pixel P, 4 weights are stored:
    //  [0] how much P takes from its top neighbour    (horizontal edge at top of P)
    //  [1] how much top neighbour takes from P        (horizontal edge at top of P)
    //  [2] how much P takes from its left neighbour   (vertical edge at left of P)
    //  [3] how much left neighbour takes from P       (vertical edge at left of P)
    // This is the .rgba of SMAA blendTex.

    bool hasLeft(int x, int y)
    {
        if (x < 0 || y < 0 || x >= width || y >= height)
            return false;
        return (edges[y*width+x] & EDGE_LEFT) != 0;
    }

    bool hasTop(int x, int y)
    {
        if (x < 0 || y < 0 || x >= width || y >= height)
            return false;
        return (edges[y*width+x] & EDGE_TOP) != 0;
    }

    for (int y = 0; y < height; ++y)
    {
        for (int x = 0; x < width; ++x)
        {
            float* w = &weights[(y*width+x)*4];
            w[0..4] = 0;
            ubyte e = edges[y*width+x];

            if (e & EDGE_TOP)
            {
                // Horizontal line between rows y-1 and y.
                // A crossing edge is a vertical edge at one end of the line,
                // in the row of P (below) or in the row above.
                int xl = x;
                while (!hasLeft(xl, y) && !hasLeft(xl, y-1)
                       && hasTop(xl-1, y) && x - xl < MLAA_MAX_SEARCH_DISTANCE)
                    --xl;

                int xr = x;
                while (!hasLeft(xr+1, y) && !hasLeft(xr+1, y-1)
                       && hasTop(xr+1, y) && xr - x < MLAA_MAX_SEARCH_DISTANCE)
                    ++xr;

                int pattern = 0;
                if (hasLeft(xl,   y  )) pattern |= 1;
                if (hasLeft(xr+1, y  )) pattern |= 2;
                if (hasLeft(xl,   y-1)) pattern |= 4;
                if (hasLeft(xr+1, y-1)) pattern |= 8;

                areaOrtho(pattern, x - xl, xr - x, w[0], w[1]);

                // Corners: crossing edges that continue one row further,
                // below P or above the top neighbour.
                cornerFactors(x - xl, xr - x,
                              hasLeft(xl, y+1), hasLeft(xr+1, y+1),
                              hasLeft(xl, y-2), hasLeft(xr+1, y-2),
                              w[0], w[1]);
            }

            if (e & EDGE_LEFT)
            {
                // Vertical line between columns x-1 and x.
                int yt = y;
                while (!hasTop(x, yt) && !hasTop(x-1, yt)
                       && hasLeft(x, yt-1) && y - yt < MLAA_MAX_SEARCH_DISTANCE)
                    --yt;

                int yb = y;
                while (!hasTop(x, yb+1) && !hasTop(x-1, yb+1)
                       && hasLeft(x, yb+1) && yb - y < MLAA_MAX_SEARCH_DISTANCE)
                    ++yb;

                int pattern = 0;
                if (hasTop(x,   yt  )) pattern |= 1;
                if (hasTop(x,   yb+1)) pattern |= 2;
                if (hasTop(x-1, yt  )) pattern |= 4;
                if (hasTop(x-1, yb+1)) pattern |= 8;

                areaOrtho(pattern, y - yt, yb - y, w[2], w[3]);

                cornerFactors(y - yt, yb - y,
                              hasTop(x+1, yt), hasTop(x+1, yb+1),
                              hasTop(x-2, yt), hasTop(x-2, yb+1),
                              w[2], w[3]);
            }
        }
    }

    // 3. Neighborhood blending.

    for (int y = 0; y < height; ++y)
    {
        const(ubyte)* src = inPixels + y * inputPitchBytes;
        ubyte* dst = outPixels + y * outputPitchBytes;

        for (int x = 0; x < width; ++x)
        {
            const(float)* w = &weights[(y*width+x)*4];
            float aRight  = (x + 1 < width)  ? weights[(y*width+x+1)*4 + 3] : 0;
            float aBottom = (y + 1 < height) ? weights[((y+1)*width+x)*4 + 1] : 0;
            float aLeft   = w[2];
            float aTop    = w[0];

            const(ubyte)* P = &src[x*4];

            if (aRight + aBottom + aLeft + aTop < 1e-5f)
            {
                dst[x*4..x*4+4] = P[0..4];
                continue;
            }

            // Blend with either the horizontal or the vertical neighbours.
            const(ubyte)* A, B;
            float wa, wb;
            if (_max(aRight, aLeft) > _max(aBottom, aTop))
            {
                A = (x + 1 < width) ? &src[x*4+4] : P;
                B = (x > 0)         ? &src[x*4-4] : P;
                wa = aRight;
                wb = aLeft;
            }
            else
            {
                A = (y + 1 < height) ? P + inputPitchBytes : P;
                B = (y > 0)          ? P - inputPitchBytes : P;
                wa = aBottom;
                wb = aTop;
            }

            // Blend in linear light, like SMAA does with a sRGB render
            // target. Alpha is not gamma-encoded and is blended as is.
            float invSum = 1.0f / (wa + wb);
            for (int c = 0; c < 4; ++c)
            {
                float p, va, vb;
                if (c < 3)
                {
                    p  = g_sRGBToLinear[P[c]];
                    va = g_sRGBToLinear[A[c]];
                    vb = g_sRGBToLinear[B[c]];
                }
                else
                {
                    p  = P[c];
                    va = A[c];
                    vb = B[c];
                }
                float a = p + (va - p) * wa;
                float b = p + (vb - p) * wb;
                float v = (a * wa + b * wb) * invSum;
                if (c < 3)
                    v = linearToSRGB(v);
                int iv = cast(int)(v + 0.5f);
                if (iv < 0) iv = 0;
                if (iv > 255) iv = 255;
                dst[x*4+c] = cast(ubyte)iv;
            }
        }
    }
}

private:

float _max(float a, float b)
{
    return a > b ? a : b;
}

float _copysign1(float x)
{
    return x < 0 ? -1.0f : 1.0f;
}

// sRGB (0 to 255) to linear light (0 to 1), built at compile-time.
static immutable float[256] g_sRGBToLinear = buildSRGBToLinear();

float[256] buildSRGBToLinear() pure
{
    import std.math: pow;
    float[256] t;
    foreach (i; 0..256)
    {
        double s = i / 255.0;
        t[i] = (s <= 0.04045) ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4);
    }
    return t;
}

// Linear light (0 to 1) to sRGB (0 to 255), unrounded.
// Only called on blended pixels, so the pow() cost is acceptable.
float linearToSRGB(float v)
{
    if (v <= 0.0031308f)
        return v * 12.92f * 255.0f;
    return (1.055f * powf(v, 1.0f / 2.4f) - 0.055f) * 255.0f;
}

// Area under the line p1->p2, for the pixel x..x+1.
// Returns the area on the negative side (P side) in a1,
// the area on the positive side (neighbour side) in a2.
// Port of area() in SMAA AreaTex.py.
void area(float p1x, float p1y, float p2x, float p2y, int x,
          out float a1, out float a2)
{
    a1 = 0;
    a2 = 0;
    float dx = p2x - p1x;
    float dy = p2y - p1y;
    float x1 = x;
    float x2 = x + 1.0f;
    float y1 = p1y + dy * (x1 - p1x) / dx;
    float y2 = p1y + dy * (x2 - p1x) / dx;

    bool inside = (x1 >= p1x && x1 < p2x) || (x2 > p1x && x2 <= p2x);
    if (!inside)
        return;

    bool isTrapezoid = (_copysign1(y1) == _copysign1(y2))
                     || fabs(y1) < 1e-4f || fabs(y2) < 1e-4f;
    if (isTrapezoid)
    {
        float a = (y1 + y2) / 2.0f;
        if (a < 0.0f)
            a1 = fabs(a);
        else
            a2 = fabs(a);
    }
    else
    {
        // Two triangles.
        float xc = -p1y * dx / dy + p1x;
        float frac = xc - floor(xc);
        float t1 = (xc > p1x) ? y1 * frac / 2.0f : 0.0f;
        float t2 = (xc < p2x) ? y2 * (1.0f - frac) / 2.0f : 0.0f;
        float a = fabs(t1) > fabs(t2) ? t1 : -t2;
        if (a < 0.0f)
        {
            a1 = fabs(t1);
            a2 = fabs(t2);
        }
        else
        {
            a1 = fabs(t2);
            a2 = fabs(t1);
        }
    }
}

// Reduces the blending of P (w1) and of its neighbour (w2) near a sharp
// corner, that is when the crossing edge at the nearest end of the line
// continues past the line: on P side (cP*) or neighbour side (cN*), at
// the left (*L) or right (*R) end. Port of SMAADetectHorizontalCornerPattern
// and SMAADetectVerticalCornerPattern.
void cornerFactors(int left, int right,
                   bool cPL, bool cPR, bool cNL, bool cNR,
                   ref float w1, ref float w2)
{
    // Only the nearest end counts, both halved if at equal distance.
    float useL = (left <= right) ? 1.0f : 0.0f;
    float useR = (right <= left) ? 1.0f : 0.0f;
    float rounding = (1.0f - MLAA_CORNER_ROUNDING) / (useL + useR);
    float roundL = rounding * useL;
    float roundR = rounding * useR;

    float f1 = 1.0f - roundL * cPL - roundR * cPR;
    float f2 = 1.0f - roundL * cNL - roundR * cNR;
    w1 *= _saturate(f1);
    w2 *= _saturate(f2);
}

float _saturate(float x)
{
    return x < 0 ? 0 : (x > 1 ? 1 : x);
}

// Area covered by the revectorized line, for a pixel at distance `left`
// from the left end of the line and distance `right` from the right end.
// Port of areaortho() in SMAA AreaTex.py, with no subpixel offset
// (no temporal jitter) and no U-shape smoothing.
//
// Pattern bits:
//   1 = crossing edge at left end, P side
//   2 = crossing edge at right end, P side
//   4 = crossing edge at left end, neighbour side
//   8 = crossing edge at right end, neighbour side
void areaOrtho(int pattern, int left, int right, out float a1, out float a2)
{
    a1 = 0;
    a2 = 0;

    //  o1           |
    //       .-------´
    //  o2   |
    //
    //       <---d--->
    float d = left + right + 1;
    float o1 =  0.5f;
    float o2 = -0.5f;
    float h = d / 2.0f;

    switch (pattern)
    {
        case 1: //   .------
                //   |
            area(0, o2, h, 0, left, a1, a2);
            break;

        case 2: //    ------.
                //          |
            area(h, 0, d, o2, left, a1, a2);
            break;

        case 3: //   .------.
                //   |      |
        {
            float b1, b2;
            area(0, o2, h, 0, left, a1, a2);
            area(h, 0, d, o2, left, b1, b2);
            a1 += b1;
            a2 += b2;
            break;
        }

        case 4: //   |
                //   `------
            area(0, o1, h, 0, left, a1, a2);
            break;

        case 6: //   |
                //   `------.
                //          |
        case 7: //   |
                //   +------.
                //   |      |
        case 14://   |      |
                //   `------+
                //          |
            area(0, o1, d, o2, left, a1, a2);
            break;

        case 8: //          |
                //    ------´
            area(h, 0, d, o1, left, a1, a2);
            break;

        case 9: //          |
                //   .------´
                //   |
        case 11://          |
                //   .------+
                //   |      |
        case 13://   |      |
                //   +------´
                //   |
            area(0, o2, d, o1, left, a1, a2);
            break;

        case 12://   |      |
                //   `------´
        {
            float b1, b2;
            area(0, o1, h, 0, left, a1, a2);
            area(h, 0, d, o1, left, b1, b2);
            a1 += b1;
            a2 += b2;
            break;
        }

        default: // 0, 5, 10, 15: no blending
            break;
    }
}
