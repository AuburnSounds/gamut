module fxaa;

/*
 * Copyright (C) 2013
 *     Dale Weiler
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
 * of the Software, and to permit persons to whom the Software is furnished to do
 * so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

 // Find original here: https://gist.github.com/graphitemaster/5545330
 // Original version has bugs with luma computation!

import inteli.tmmintrin;
import core.stdc.string;

nothrow @nogc:

//
// Implemented from spec:
//  http://developer.download.nvidia.com/assets/gamedev/files/sdk/11/FXAA_WhitePaper.pdf
//
// Other sources used:
//  Intel SIMD intrinsics guide
//  Nvidia Graphics SDK 11 (for shader implementation as reference)
//

// the higher the span the less area of screen is actually
// anti-aliased
enum int SW_FXAA_SPAN_MAX = 8;
enum int SW_FXAA_OFFS = (((SW_FXAA_SPAN_MAX*8)>>4));


enum float FXAA_REDUCE_MIN = 1.0 / 128;  // not much to win, optimal;
enum float FXAA_REDUCE_MUL = 1.0 / 12.0; // slightly sharper than original 1/8.0
enum float FXAA_MYSTERIOUS_FACTOR = 7.0f; // slightly sharper than original 8.0

__m128i MM_MUL_IMPL(__m128i A, __m128i B, __m128i AI, __m128i BI)
{
    return _mm_shuffle_epi32!(_MM_SHUFFLE(3,1,2,0))(
        cast(__m128i) _mm_shuffle_ps!(_MM_SHUFFLE(2,0,2,0)) (
            cast(__m128) _mm_mul_epu32(A, B),
            cast(__m128) _mm_mul_epu32(AI,BI),            
        ),
        
    );
}

__m128i MM_MULI_N(__m128i A, __m128i B) 
{
    return MM_MUL_IMPL(A, B, 
                       _mm_shuffle_epi32!(_MM_SHUFFLE(3,3,1,1))(A), 
                       _mm_shuffle_epi32!(_MM_SHUFFLE(3,3,1,1))(B));
}
__m128i MM_MULI_I(__m128i A, __m128i B) 
{
    return MM_MUL_IMPL(A, B, 
                       _mm_shuffle_epi32!(_MM_SHUFFLE(3,3,1,1))(A), B);
}

// Luma operator
// RGB, as input, has following i32 bits for each of 4 pixels:
// 0000_00BB_BBBB_BBGG_GGGG_GGRR_RRRR_RR00
__m128i LUMA(__m128i RGB, int AND1, int SRLI1, int AND2, int SRLI2, int AND3, int SRLI3)
{
    return _mm_add_epi32(
        _mm_add_epi32(
            _mm_srli_epi32(_mm_and_si128(RGB, _mm_set1_epi32(AND1)), SRLI1),
            _mm_srli_epi32(_mm_and_si128(RGB, _mm_set1_epi32(AND2)), SRLI2)
        ),
        _mm_srli_epi32(_mm_and_si128(RGB, _mm_set1_epi32(AND3)), SRLI3)
    );
}

// Give a rgba8 image, this function perform two sets of linear interpolations.
// On is at (pitch) + (dx, dy)
// The other at (pitch) - (dx, dy)
__m128i bilinear_filter32(const(ubyte*) inPixels,
                          __m128i pitch_bytes, // pitch in byte of each pixel
                          __m128i dx,          // 4x horz displacement in fixed signed 28.4 bit format
                          __m128i dy,          // 4x horz displacement in fixed signed 28.4 bit format
                          int inputPitchBytes) 
{
    alias p = inputPitchBytes;
    __m128i pt = _mm_set1_epi32(inputPitchBytes);

    const __m128i f128  = _mm_set1_epi32(0xFu);
    const __m128i mask1 = _mm_set1_epi32(0xFF00FFu);
    const __m128i mask2 = _mm_set1_epi32(0xFF00u);
    const __m128i fe1   = _mm_set1_epi32(0xFE00FE00u);
    const __m128i fe2   = _mm_set1_epi32(0x00FE0000u);

    const __m128i dy4n = _mm_add_epi32(_mm_slli_epi32(_mm_srai_epi32(dx,4), 2), MM_MULI_I(_mm_srai_epi32(dy,4),pt));
    const __m128i osa  = _mm_add_epi32(pitch_bytes,dy4n);
    const __m128i osb  = _mm_sub_epi32(pitch_bytes,dy4n);

    dx = _mm_and_si128(dx, f128);
    dy = _mm_and_si128(dy, f128);

    const __m128i xy          = MM_MULI_N(dx,dy);
    const __m128i x16         = _mm_slli_epi32(dx,4);
    const __m128i invxy       = _mm_sub_epi32(_mm_slli_epi32(dy,4),xy);
    const __m128i xinvy       = _mm_sub_epi32(x16,xy);
    const __m128i invxinvy    = _mm_sub_epi32(_mm_sub_epi32(_mm_set1_epi32(256),x16),invxy);
    const int oa0    = osa.array[0];
    const int oa1    = osa.array[1];
    const int oa2    = osa.array[2];
    const int oa3    = osa.array[3];
    
    int loadPixel(int offsetBytes)
    {
        const(int)* fb = cast(const(int)*) (inPixels + offsetBytes);
        return *fb;
    }
    
    __m128i r00a = _mm_set_epi32(loadPixel(oa3    ), loadPixel(oa2    ), loadPixel(oa1    ), loadPixel(oa0    ));
    __m128i r10a = _mm_set_epi32(loadPixel(oa3  +4), loadPixel(oa2  +4), loadPixel(oa1  +4), loadPixel(oa0  +4));
    __m128i r01a = _mm_set_epi32(loadPixel(oa3+p  ), loadPixel(oa2+p  ), loadPixel(oa1+p  ), loadPixel(oa0+p  ));
    __m128i r11a = _mm_set_epi32(loadPixel(oa3+p+4), loadPixel(oa2+p+4), loadPixel(oa1+p+4), loadPixel(oa0+p+4));


    const __m128i lerp0 =
        _mm_srli_epi32(
            _mm_or_si128(
                _mm_and_si128(
                    _mm_add_epi32(
                        _mm_add_epi32(
                            MM_MULI_N(_mm_and_si128(r00a, mask1), invxinvy),
                            MM_MULI_N(_mm_and_si128(r10a, mask1), xinvy)
                        ),
                        _mm_add_epi32(
                            MM_MULI_N(_mm_and_si128(r01a, mask1), invxy),
                            MM_MULI_N(_mm_and_si128(r11a, mask1), xy)
                        )
                    ),
                    fe1
                ),
                _mm_and_si128(
                    _mm_add_epi32(
                        _mm_add_epi32(
                            MM_MULI_N(_mm_and_si128(r00a, mask2), invxinvy),
                            MM_MULI_N(_mm_and_si128(r10a, mask2), xinvy)
                        ),
                        _mm_add_epi32(
                            MM_MULI_N(_mm_and_si128(r01a, mask2), invxy),
                            MM_MULI_N(_mm_and_si128(r11a, mask2), xy)
                        )
                    ),
                    fe2
                )
            ),
            9
        );

    const int ob0 = osb.array[0];
    const int ob1 = osb.array[1];
    const int ob2 = osb.array[2];
    const int ob3 = osb.array[3];
    __m128i r11b = _mm_set_epi32(loadPixel(ob3-4-p), loadPixel(ob2-4-p), loadPixel(ob1-4-p), loadPixel(ob0-4-p));
    __m128i r01b = _mm_set_epi32(loadPixel(ob3  -p), loadPixel(ob2  -p), loadPixel(ob1  -p), loadPixel(ob0  -p));
    __m128i r10b = _mm_set_epi32(loadPixel(ob3-4  ), loadPixel(ob2-4  ), loadPixel(ob1-4  ), loadPixel(ob0-4  ));
    __m128i r00b = _mm_set_epi32(loadPixel(ob3    ), loadPixel(ob2    ), loadPixel(ob1    ), loadPixel(ob0    ));

    return _mm_add_epi32(
                lerp0,
                _mm_srli_epi32(
                    _mm_or_si128(
                        _mm_and_si128(
                            _mm_add_epi32(
                                _mm_add_epi32(
                                    MM_MULI_N(_mm_and_si128(r00b, mask1),invxinvy),
                                    MM_MULI_N(_mm_and_si128(r10b, mask1),xinvy)
                                ),
                                _mm_add_epi32(
                                    MM_MULI_N(_mm_and_si128(r01b, mask1),invxy),
                                    MM_MULI_N(_mm_and_si128(r11b, mask1),xy)
                                )
                            ),
                            fe1
                        ),
                        _mm_and_si128(
                            _mm_add_epi32(
                                _mm_add_epi32(
                                    MM_MULI_N(_mm_and_si128(r00b, mask2),invxinvy),
                                    MM_MULI_N(_mm_and_si128(r10b, mask2),xinvy)
                                ),
                                _mm_add_epi32(
                                    MM_MULI_N(_mm_and_si128(r01b, mask2),invxy),
                                    MM_MULI_N(_mm_and_si128(r11b, mask2),xy)
                                )
                            ),
                            fe2
                        )
                    ),
                    9
                )
            );
}

import core.stdc.stdio;

// fxaa filter
void fxaa_32bit(
    const int ystart, // rectangle where applied
    const int yend,
    const int xstart,
    const int xend,

    const int width,  // width in pixels
    const int inputPitchBytes, // input pitch, in pixels (pitch must be multiple of 4)
    const int outputPitchBytes, // output pitch, in pixels (pitch must be multiple of 4)
    const int height, // height in pixels

    ubyte* inPixels,  // input image (only RGBA8 supported)
    ubyte* outPixels, // output image (only RGBA8 supported)
    ubyte* mask       // mask, temporary buffer

) {
    const __m128i t161616     = _mm_set1_epi32(16);
    const __m128i fefefe    = _mm_set1_epi32(0xFEFEFE);
    const __m128i fcfcfc    = _mm_set1_epi32(0xFCFCFC);
    const __m128i w0        = _mm_set_epi32(0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0);
    const __m128  pspanmax  = _mm_set1_ps( SW_FXAA_SPAN_MAX);
    const __m128  nspanmax  = _mm_set1_ps(-SW_FXAA_SPAN_MAX);
    
    // top and bottom borders
    {
        size_t oneScanlineBytes = width * 4;
        for(int y = 0; y < ystart; ++y)
        {
            ubyte* src = inPixels + y * inputPitchBytes;
            ubyte* dst = outPixels + y * outputPitchBytes;
            memcpy(dst, src,oneScanlineBytes);
        }
        for(int y = yend; y < cast(int)height; ++y)
        {
            ubyte* src = inPixels + y * inputPitchBytes;
            ubyte* dst = outPixels + y * outputPitchBytes;
            memcpy(dst, src, oneScanlineBytes);
        }
    }

    for(int y = ystart; y < yend; ++y)
    {
        //  ________________________
        // |        |       |       |
        // | offsm1 |       |       |
        // |________|_______|_______|
        // |        |       |       |
        // | offs   | offsn |       |
        // |________|_______|_______|
        // |        |       |       |
        // | offsp1 |       |       |
        // |________|_______|_______|

        int offsm1_bytes    = (y - 1) * inputPitchBytes - 4 + xstart * 4;
        int offsn_bytes     = (y * outputPitchBytes) + xstart * 4;
        int offsmask_bytes  = (y * width + xstart) >> 2;
        
        __m128i pitch_bytes = _mm_add_epi32(_mm_set_epi32(12,8,4,0),
                                            _mm_set1_epi32(y*inputPitchBytes + xstart*4));

        // borders
        for(int x = 0; x < xstart; ++x)
        {
            ubyte* src = inPixels + y * inputPitchBytes + xstart * 4;
            ubyte* dst = outPixels + y * outputPitchBytes + x * 4;
            dst[0..4] = src[0..4];
        }

        if (xend > 0)
        {
            for(int x = xend; x < width; ++x)
            {
                ubyte* src = inPixels + y * inputPitchBytes + (xend-1) * 4;
                ubyte* dst = outPixels + y * outputPitchBytes + x * 4;
                dst[0..4] = src[0..4];
            }
        }
        
        for(int x = xstart; x < xend; x              += 4, 
                                      offsm1_bytes   += 16, 
                                      offsn_bytes    += 16, 
                                      offsmask_bytes += 1, 
                                      pitch_bytes    = _mm_add_epi32(pitch_bytes, t161616)) 
        {
            int offs_bytes   = offsm1_bytes + inputPitchBytes;
            int offsp1_bytes = offs_bytes   + inputPitchBytes;

            //if(mask[offsmask_bytes] == 0)
            {                

                // NW = texture2D(First_Texture, TexCoord1 + (vec2(-1.0, -1.0) * PixelSize)).xyz
                // NE = texture2D(First_Texture, TexCoord1 + (vec2(+1.0, -1.0) * PixelSize)).xyz
                __m128i NW = _mm_and_si128(_mm_loadu_si32(inPixels + offsm1_bytes), fcfcfc);
                __m128i rN = _mm_and_si128(_mm_loadu_si128(cast(__m128i*)(inPixels+offsm1_bytes+4)), fcfcfc);
                __m128i NE = _mm_and_si128(_mm_loadu_si32(inPixels+offsm1_bytes + 20), fcfcfc);
                __m128i rNW = _mm_or_si128(NW,_mm_and_si128(_mm_shuffle_epi32!(_MM_SHUFFLE(2,1,0,0))(rN), w0));
                __m128i rNE = _mm_shuffle_epi32!(_MM_SHUFFLE(0,3,2,1))(_mm_or_si128(NE,_mm_and_si128(rN, w0)));


                // SW = texture2D(First_Texture, TexCoord1 + (vec2(-1.0, +1.0) * PixelSize)).xyz
                // SE = texture2D(First_Texture, TexCoord1 + (vec2(+1.0, +1.0) * PixelSize)).xyz
                __m128i SW = _mm_and_si128(_mm_loadu_si32(inPixels+offsp1_bytes), fcfcfc);
                __m128i rS = _mm_and_si128(_mm_loadu_si128(cast(__m128i*)(inPixels+offsp1_bytes+4)), fcfcfc);
                __m128i SE = _mm_and_si128(_mm_loadu_si32(inPixels+offsp1_bytes+20), fcfcfc);
                __m128i rSW = _mm_or_si128(SW,_mm_and_si128(_mm_shuffle_epi32!(_MM_SHUFFLE(2,1,0,0))(rS), w0));
                __m128i rSE = _mm_shuffle_epi32!(_MM_SHUFFLE(0,3,2,1))(_mm_or_si128(SE,_mm_and_si128(rS, w0)));

                // M  = texture2D(First_Texture, TexCoord1).xyz
                __m128i W = _mm_and_si128(_mm_loadu_si32(inPixels+offs_bytes), fcfcfc);
                __m128i rM = _mm_and_si128(_mm_loadu_si128(cast(__m128i*)(inPixels+offs_bytes+4)), fcfcfc);
                __m128i E = _mm_and_si128(_mm_loadu_si32(inPixels+offs_bytes+20), fcfcfc);
                __m128i rW = _mm_or_si128(W,_mm_and_si128(_mm_shuffle_epi32!(_MM_SHUFFLE(2,1,0,0))(rM), w0));
                __m128i rE = _mm_shuffle_epi32!(_MM_SHUFFLE(0,3,2,1))(_mm_or_si128(E,_mm_and_si128(rM, w0)));
                
                __m128i rMrN   = _mm_add_epi32(rM,rN);
                __m128i rMrS   = _mm_add_epi32(rM,rS);

                // luma center pixel = R / 4 + G / 2 + B / 8 
                __m128i lM     = LUMA(rM, 0xFFu, 2, 0xFF00u, 9, 0x00FE0000u, 19);

                // lNW, lNE, lSW and lSE contain a luminance estimation in 8-bit
                // for the diagonal directions.
                // Note: all values have 2 bits at zero, so you can add 
                // such a value 4x by overflowing on the next i32 item (!)


                __m128i lNW    = LUMA(_mm_add_epi32(_mm_add_epi32(rMrN,rNW),rW), 0x3FCu, 4, 0x3FC00u, 11, 0x3FC0000u, 21);
                __m128i lNE    = LUMA(_mm_add_epi32(_mm_add_epi32(rMrN,rNE),rE), 0x3FCu, 4, 0x3FC00u, 11, 0x3FC0000u, 21);
                __m128i lSW    = LUMA(_mm_add_epi32(_mm_add_epi32(rMrS,rSW),rW), 0x3FCu, 4, 0x3FC00u, 11, 0x3FC0000u, 21);
                __m128i lSE    = LUMA(_mm_add_epi32(_mm_add_epi32(rMrS,rSE),rE), 0x3FCu, 4, 0x3FC00u, 11, 0x3FC0000u, 21);
                __m128i mS     = _mm_cmpgt_epi32(lSW,lSE);
                __m128i mN     = _mm_cmpgt_epi32(lNW,lNE);

                // min and max of luminance coming from south
                __m128i tMax   = _mm_or_si128(_mm_and_si128(mS,lSW), _mm_andnot_si128(mS,lSE));
                __m128i tMin   = _mm_or_si128(_mm_and_si128(mS,lSE), _mm_andnot_si128(mS,lSW));
                
                // min and max of luminance coming from north
                __m128i tMax2  = _mm_or_si128(_mm_and_si128(mN,lNW), _mm_andnot_si128(mN,lNE));
                __m128i tMin2  = _mm_or_si128(_mm_and_si128(mN,lNE), _mm_andnot_si128(mN,lNW));

                // luminance South and North (9-bit unsigned value)
                __m128i SWSE   = _mm_add_epi32(lSW,lSE);
                __m128i NWNE   = _mm_add_epi32(lNW,lNE);
                __m128i NWSW   = _mm_add_epi32(lNW,lSW);
                __m128i NESE   = _mm_add_epi32(lNE,lSE);

                // gradient of luminances (10-bit signed), visualized to be correct
                // in GLSL shader, this is -4.0f to +4.0f, so we remap that.
                // Original source had many problems of range like that.
                __m128 fdirx   = _mm_cvtepi32_ps(_mm_sub_epi32(SWSE, NWNE)) * _mm_set1_ps(1.0f / 256.0f);
                __m128 fdiry   = _mm_cvtepi32_ps(_mm_sub_epi32(NWSW, NESE)) * _mm_set1_ps(1.0f / 256.0f);

                // 10-bit unsigned luma sum, mapped to 0.0 to 1.0f
                __m128 lumasum = _mm_cvtepi32_ps(_mm_add_epi32(NWNE, SWSE)) * _mm_set1_ps(1.0f / 1023.0f);

                
                __m128 dirReduce = _mm_max_ps( _mm_mul_ps(lumasum, _mm_set1_ps(FXAA_REDUCE_MUL)), _mm_set1_ps(FXAA_REDUCE_MIN));

                __m128 rcpDirMin = _mm_rcp_ps( _mm_min_ps(_mm_abs_ps(fdirx), _mm_abs_ps(fdiry)) + dirReduce);

                // dirx and diry should be -SW_FXAA_SPAN_MAX to +SW_FXAA_SPAN_MAX
                __m128 fMF = _mm_set1_ps(FXAA_MYSTERIOUS_FACTOR);
                __m128i dirx = _mm_cvttps_epi32(fMF * _mm_min_ps(pspanmax, _mm_max_ps(nspanmax, _mm_mul_ps(fdirx, rcpDirMin))));
                __m128i diry = _mm_cvttps_epi32(fMF * _mm_min_ps(pspanmax, _mm_max_ps(nspanmax, _mm_mul_ps(fdiry, rcpDirMin))));

                __m128i virx = _mm_srai_epi32(dirx, 2);
                __m128i viry = _mm_srai_epi32(diry, 2);
                __m128i rB = bilinear_filter32(inPixels, pitch_bytes, dirx, diry, inputPitchBytes);
                __m128i rA = bilinear_filter32(inPixels, pitch_bytes, virx, viry, inputPitchBytes);
                rB         = _mm_srli_epi32(
                                _mm_add_epi32(
                                    _mm_and_si128(rA, fefefe),
                                    _mm_and_si128(rB, fefefe)
                                ),
                                1
                            );
                
                __m128i lB = LUMA(rA, 0xFFu, 2, 0xFF00u, 9, 0x00FE0000u, 19);
                __m128i mL =  _mm_or_si128(
                                            _mm_and_si128(
                                                _mm_and_si128(
                                                    _mm_cmplt_epi32(lB,lM),
                                                    _mm_cmplt_epi32(lB,tMin)
                                                ),
                                                _mm_cmplt_epi32(lB,tMin2)
                                            ),
                                            _mm_and_si128(
                                                _mm_and_si128(
                                                    _mm_cmpgt_epi32(lB,lM),
                                                    _mm_cmpgt_epi32(lB,tMax)
                                                ),
                                                _mm_cmpgt_epi32(lB,tMax2)
                                            )
                                        );
                __m128i result = _mm_or_si128(_mm_and_si128(mL, rA), _mm_andnot_si128(mL, rB)); 

                // Force alpha to be 255
                byte16 b16 = cast(byte16) result;
                b16.ptr[3] = cast(byte)255;
                b16.ptr[7] = cast(byte)255;
                b16.ptr[11] = cast(byte)255;
                b16.ptr[15] = cast(byte)255;
                result = cast(__m128i)b16;

                _mm_storeu_si128(cast(__m128i*)(outPixels + offsn_bytes), result);                
                mask[offsmask_bytes] = 1;
            }
        }
    }
}
