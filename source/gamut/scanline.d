/**
Scanline conversion public API. This is used both internally and externally, because converting
a whole row of pixels at once is a rather common operations.

Copyright: Copyright Guillaume Piolat 2023
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut.scanline;


import core.stdc.string: memcpy;
import gamut.types;
import gamut.internals.types;

@system:
nothrow:
@nogc:


// <PUBLIC SCANLINES API>


/// When there is a PixelType conversion, we often need an intermediate space.
// FUTURE: this will also manage color conversion.
public PixelType scanlinesInterType(PixelType srcType, PixelType destType)
{
    if (pixelTypeExpressibleInRGBA8(srcType) && pixelTypeExpressibleInRGBA8(destType))
        return PixelType.rgba8;

    return PixelType.rgbaf32;
}


/// Copy scanlines of the same type.
/// This does no conversions.
/// Returns: `true` if successful.
bool scanlinesCopy(PixelType type, const(ubyte)* src, int srcPitch, 
                                         ubyte* dest, int destPitch, int width, int height)
{
    if (pixelTypeIsPlanar(type))
        return false; // No support

    if (pixelTypeIsCompressed(type))
        return false; // No support

    int scanlineBytes = pixelTypeSize(type) * width;

    for (int y = 0; y < height; ++y)
    {
        dest[0..scanlineBytes] = src[0..scanlineBytes];
        src += srcPitch;
        dest += destPitch;
    }
    return true;
}

/// Convert several scanlines, using `interBuf` an intermediate buffer.
/// 
/// Params:
///     srcType   Type of input pixels.
///     src       Input data, point to width x height scanlines.
///     srcPitch  Bytes between lines, can be negative.
///     destType  Type of output pixels.
///     dest      Output data, point to width x height scanlines.
///     width     Width of area to convert, in pixels.
///     height    Height of area to convert, in pixels.
///     interType Type given by scanlinesInterType(srcType, destType).
///     interBuf  Buffer of pixelTypeSize(interType) * width.
bool scanlinesConvert(PixelType srcType, const(ubyte)* src, int srcPitch, 
                      PixelType destType, ubyte* dest, int destPitch,
                      int width, int height,
                      PixelType interType, ubyte* interBuf)
{
    if (srcType == destType)
    {
        return scanlinesCopy(srcType, src, srcPitch, dest, destPitch, width, height);
    }
    assert(srcType != destType);
    assert(srcType != PixelType.unknown && destType != PixelType.unknown);

    if (pixelTypeIsPlanar(srcType) || pixelTypeIsPlanar(destType))
        return false; // No support
    if (pixelTypeIsCompressed(srcType) || pixelTypeIsCompressed(destType))
        return false; // No support

    if (srcType == interType)
    {
        // Source type is already in the intermediate type format.
        // Do not use the interbuf.
        for (int y = 0; y < height; ++y)
        {
            convertFromIntermediate(srcType, src, destType, dest, width);
            src += srcPitch;
            dest += destPitch;
        }
    }
    else if (destType == interType)
    {
        // Destination type is the intermediate type.
        // Do not use the interbuf.
        for (int y = 0; y < height; ++y)
        {
            convertToIntermediateScanline(srcType, src, destType, dest, width);
            src += srcPitch;
            dest += destPitch;
        }
    }
    else
    {
        // For each scanline
        for (int y = 0; y < height; ++y)
        {
            convertToIntermediateScanline(srcType, src, interType, interBuf, width);
            convertFromIntermediate(interType, interBuf, destType, dest, width);
            src += srcPitch;
            dest += destPitch;
        }
    }
    return true;
}



/// All scanlines conversion functions follow this signature:
///   inScan pointer to first pixel of input scanline
///   outScan pointer to first pixel of output scanline
///
/// Type information, user data information, must be given by context.
/// Such a function assumes no overlap in memory between input and output scanlines.
alias scanlineConversionFunction_t = void function(const(ubyte)* inScan, ubyte* outScan, int width, void* userData);



//
// FROM xxxx TO rgb8
// (used in eg. the TGA encoder)

void scanline_convert_l8_to_rgb8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    ubyte* outb = outScan;
    for (int x = 0; x < width; ++x)
    {
        ubyte b = inScan[x];
        *outb++ = b;
        *outb++ = b;
        *outb++ = b;
    }
}

void scanline_convert_rgb8_to_rgb8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    memcpy(outScan, inScan, width * 3);
}

//
// FROM xxxx TO rgba8
// 

void scanline_convert_l8_to_rgba8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    ubyte* outb = outScan;
    for (int x = 0; x < width; ++x)
    {
        ubyte b = inScan[x];
        *outb++ = b;
        *outb++ = b;
        *outb++ = b;
        *outb++ = 255;
    }
}
void scanline_convert_la8_to_rgba8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    ubyte* outb = outScan;
    for (int x = 0; x < width; ++x)
    {
        ubyte b = inScan[x*2];
        *outb++ = b;
        *outb++ = b;
        *outb++ = b;
        *outb++ = inScan[x*2+1];
    }
}
void scanline_convert_rgb8_to_rgba8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    ubyte* outb = outScan;
    for (int x = 0; x < width; ++x)
    {
        *outb++ = inScan[x*3+0];
        *outb++ = inScan[x*3+1];
        *outb++ = inScan[x*3+2];
        *outb++ = 255;
    }
}

//
// FROM rgba8 TO xxxx
//

/// Convert a row of pixel from RGBA 8-bit (0 to 255) to L 8-bit (0 to 255).
void scanline_convert_rgba8_to_l8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    for (int x = 0; x < width; ++x)
    {
        outScan[x] = inScan[4*x];
    }
}

/// Convert a row of pixel from RGBA 8-bit (0 to 255) to LA 8-bit (0 to 255).
void scanline_convert_rgba8_to_la8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    for (int x = 0; x < width; ++x)
    {
        outScan[2*x+0] = inScan[4*x+0];
        outScan[2*x+1] = inScan[4*x+3];
    }
}

/// Convert a row of pixel from RGBA 8-bit (0 to 255) to RGB 8-bit (0 to 255).
void scanline_convert_rgba8_to_rgb8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    for (int x = 0; x < width; ++x)
    {
        outScan[3*x+0] = inScan[4*x+0];
        outScan[3*x+1] = inScan[4*x+1];
        outScan[3*x+2] = inScan[4*x+2];
    }
}

/// Convert a row of pixel from RGBA 8-bit (0 to 255) to RGBA 8-bit (0 to 255).
void scanline_convert_rgba8_to_rgba8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    memcpy(outScan, inScan, width * 4 * ubyte.sizeof);
}

//
// FROM xxxx TO rgbaf32
//

void scanline_convert_l8_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ubyte)* s = inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = s[x] / 255.0f;
        *outp++ = b;
        *outp++ = b;
        *outp++ = b;
        *outp++ = 1.0f;
    }
}

void scanline_convert_l16_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ushort)* s = cast(const(ushort)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = s[x] / 65535.0f;
        *outp++ = b;
        *outp++ = b;
        *outp++ = b;
        *outp++ = 1.0f;
    }
}

void scanline_convert_lf32_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* s = cast(const(float)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = s[x];
        *outp++ = b;
        *outp++ = b;
        *outp++ = b;
        *outp++ = 1.0f;
    }
}

void scanline_convert_la8_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ubyte)* s = inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = *s++ / 255.0f;
        float a = *s++ / 255.0f;
        *outp++ = b;
        *outp++ = b;
        *outp++ = b;
        *outp++ = a;
    }
}

void scanline_convert_la16_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ushort)* s = cast(const(ushort)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = *s++ / 65535.0f;
        float a = *s++ / 65535.0f;
        *outp++ = b;
        *outp++ = b;
        *outp++ = b;
        *outp++ = a;
    }
}

void scanline_convert_laf32_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* s = cast(const(float)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = *s++;
        float a = *s++;
        *outp++ = b;
        *outp++ = b;
        *outp++ = b;
        *outp++ = a;
    }
}


void scanline_convert_lap8_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ubyte)* s = inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = *s++ / 255.0f;
        float a = *s++ / 255.0f;
        if (a != 0)
            b /= a;
        *outp++ = b;
        *outp++ = b;
        *outp++ = b;
        *outp++ = a;
    }
}

void scanline_convert_lap16_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ushort)* s = cast(const(ushort)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = *s++ / 65535.0f;
        float a = *s++ / 65535.0f;
        if (a != 0)
            b /= a;
        *outp++ = b;
        *outp++ = b;
        *outp++ = b;
        *outp++ = a;
    }
}

void scanline_convert_lapf32_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* s = cast(const(float)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = *s++;
        float a = *s++;
        if (a != 0)
            b /= a;
        *outp++ = b;
        *outp++ = b;
        *outp++ = b;
        *outp++ = a;
    }
}


void scanline_convert_rgb8_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ubyte)* s = inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float r = *s++ / 255.0f;
        float g = *s++ / 255.0f;
        float b = *s++ / 255.0f;
        *outp++ = r;
        *outp++ = g;
        *outp++ = b;
        *outp++ = 1.0f;
    }
}

void scanline_convert_rgb16_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ushort)* s = cast(const(ushort)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float r = *s++ / 65535.0f;
        float g = *s++ / 65535.0f;
        float b = *s++ / 65535.0f;
        *outp++ = r;
        *outp++ = g;
        *outp++ = b;
        *outp++ = 1.0f;
    }
}

void scanline_convert_rgbf32_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* s = cast(const(float)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float r = *s++;
        float g = *s++;
        float b = *s++;
        *outp++ = r;
        *outp++ = g;
        *outp++ = b;
        *outp++ = 1.0f;
    }
}

void scanline_convert_rgba8_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ubyte)* s = inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float r = *s++ / 255.0f;
        float g = *s++ / 255.0f;
        float b = *s++ / 255.0f;
        float a = *s++ / 255.0f;
        *outp++ = r;
        *outp++ = g;
        *outp++ = b;
        *outp++ = a;
    }
}

void scanline_convert_rgba16_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ushort)* s = cast(const(ushort)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float r = *s++ / 65535.0f;
        float g = *s++ / 65535.0f;
        float b = *s++ / 65535.0f;
        float a = *s++ / 65535.0f;
        *outp++ = r;
        *outp++ = g;
        *outp++ = b;
        *outp++ = a;
    }
}

void scanline_convert_rgbap8_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ubyte)* s = inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float r = *s++ / 255.0f;
        float g = *s++ / 255.0f;
        float b = *s++ / 255.0f;
        float a = *s++ / 255.0f;
        if (a != 0)
        {
            r /= a;
            g /= a;
            b /= a;
        }
        *outp++ = r;
        *outp++ = g;
        *outp++ = b;
        *outp++ = a;
    }
}

void scanline_convert_rgbap16_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(ushort)* s = cast(const(ushort)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float r = *s++ / 65535.0f;
        float g = *s++ / 65535.0f;
        float b = *s++ / 65535.0f;
        float a = *s++ / 65535.0f;
        if (a != 0)
        {
            r /= a;
            g /= a;
            b /= a;
        }
        *outp++ = r;
        *outp++ = g;
        *outp++ = b;
        *outp++ = a;
    }
}

void scanline_convert_rgbapf32_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* s = cast(const(float)*) inScan;
    float* outp = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float r = *s++;
        float g = *s++;
        float b = *s++;
        float a = *s++;
        if (a != 0)
        {
            r /= a;
            g /= a;
            b /= a;
        }
        *outp++ = r;
        *outp++ = g;
        *outp++ = b;
        *outp++ = a;
    }
}




//
// FROM rgbaf32 TO xxxx
//

/// Convert a row of pixel from RGBA 32-bit float (0 to 1.0) float to L 8-bit (0 to 255).
void scanline_convert_rgbaf32_to_l8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*)inScan; 
    ubyte* s = outScan;
    for (int x = 0; x < width; ++x)
    {
        ubyte b = cast(ubyte)(0.5f + (inp[4*x+0] + inp[4*x+1] + inp[4*x+2]) * 255.0f / 3.0f);
        *s++ = b;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1.0) float to L 16-bit (0 to 65535).
void scanline_convert_rgbaf32_to_l16(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*)inScan; 
    ushort* s = cast(ushort*) outScan;
    for (int x = 0; x < width; ++x)
    {
        ushort b = cast(ushort)(0.5f + (inp[4*x+0] + inp[4*x+1] + inp[4*x+2]) * 65535.0f / 3.0f);
        *s++ = b;
    }
}


/// Convert a row of pixel from RGBA 32-bit float (0 to 1.0) float to L 32-bit float (0 to 1.0).
void scanline_convert_rgbaf32_to_lf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*)inScan; 
    float* s = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = (inp[4*x+0] + inp[4*x+1] + inp[4*x+2]) / 3.0f;
        *s++ = b;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1.0) to LA 16-bit (0 to 65535).
void scanline_convert_rgbaf32_to_la8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    // Issue #21, workaround for DMD optimizer.
    version(DigitalMars) pragma(inline, false);

    const(float)* inp = cast(const(float)*)inScan; 
    ubyte* s = outScan;
    for (int x = 0; x < width; ++x)
    {
        ubyte b = cast(ubyte)(0.5f + (inp[4*x+0] + inp[4*x+1] + inp[4*x+2]) * 255.0f / 3.0f);
        ubyte a = cast(ubyte)(0.5f + inp[4*x+3] * 255.0f);
        *s++ = b;
        *s++ = a;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1.0) to LA 16-bit (0 to 65535).
void scanline_convert_rgbaf32_to_la16(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    ushort* s = cast(ushort*) outScan;    
    for (int x = 0; x < width; ++x)
    {
        ushort b = cast(ushort)(0.5f + (inp[4*x+0] + inp[4*x+1] + inp[4*x+2]) * 65535.0f / 3.0f);
        ushort a = cast(ushort)(0.5f + inp[4*x+3] * 65535.0f);
        *s++ = b;
        *s++ = a;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to LA 32-bit float (0 to 1).
void scanline_convert_rgbaf32_to_laf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    float* s = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = (inp[4*x+0] + inp[4*x+1] + inp[4*x+2]) / 3.0f;
        float a = inp[4*x+3];
        *s++ = b;
        *s++ = a;
    }
}


/// Convert a row of pixel from RGBA 32-bit float (0 to 1.0) to LA 16-bit (0 to 65535) premultiplied.
void scanline_convert_rgbaf32_to_lap8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    // Issue #21, workaround for DMD optimizer. Not sure if this one useful.
    version(DigitalMars) pragma(inline, false);

    const(float)* inp = cast(const(float)*)inScan; 
    ubyte* s = outScan;
    for (int x = 0; x < width; ++x)
    {
        ubyte b = cast(ubyte)(0.5f + (inp[4*x+0] + inp[4*x+1] + inp[4*x+2]) * inp[4*x+3] * 255.0f / 3.0f);
        ubyte a = cast(ubyte)(0.5f + inp[4*x+3] * 255.0f);
        *s++ = b;
        *s++ = a;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1.0) to LA 16-bit (0 to 65535) premultiplied.
void scanline_convert_rgbaf32_to_lap16(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    ushort* s = cast(ushort*) outScan;    
    for (int x = 0; x < width; ++x)
    {
        ushort b = cast(ushort)(0.5f + (inp[4*x+0] + inp[4*x+1] + inp[4*x+2]) * inp[4*x+3] * 65535.0f / 3.0f);
        ushort a = cast(ushort)(0.5f + inp[4*x+3] * 65535.0f);
        *s++ = b;
        *s++ = a;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to LA 32-bit float (0 to 1) premultiplied.
void scanline_convert_rgbaf32_to_lapf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    float* s = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float b = (inp[4*x+0] + inp[4*x+1] + inp[4*x+2]) * inp[4*x+3] / 3.0f;
        float a = inp[4*x+3];
        *s++ = b;
        *s++ = a;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to RGB 8-bit (0 to 255).
void scanline_convert_rgbaf32_to_rgb8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    ubyte* s = outScan;

    for (int x = 0; x < width; ++x)
    {
        ubyte r = cast(ubyte)(0.5f + inp[4*x+0] * 255.0f);
        ubyte g = cast(ubyte)(0.5f + inp[4*x+1] * 255.0f);
        ubyte b = cast(ubyte)(0.5f + inp[4*x+2] * 255.0f);
        *s++ = r;
        *s++ = g;
        *s++ = b;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to RGB 16-bit (0 to 65535).
void scanline_convert_rgbaf32_to_rgb16(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    ushort* s = cast(ushort*) outScan;
    for (int x = 0; x < width; ++x)
    {
        ushort r = cast(ushort)(0.5f + inp[4*x+0] * 65535.0f);
        ushort g = cast(ushort)(0.5f + inp[4*x+1] * 65535.0f);
        ushort b = cast(ushort)(0.5f + inp[4*x+2] * 65535.0f);
        *s++ = r;
        *s++ = g;
        *s++ = b;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to RGB 16-bit (0 to 65535).
void scanline_convert_rgbaf32_to_rgbf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    float* s = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        *s++ = inp[4*x+0];
        *s++ = inp[4*x+1];
        *s++ = inp[4*x+2];
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to RGBA 8-bit (0 to 255).
void scanline_convert_rgbaf32_to_rgba8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    ubyte* s = outScan;
    for (int x = 0; x < width; ++x)
    {
        ubyte r = cast(ubyte)(0.5f + inp[4*x+0] * 255.0f);
        ubyte g = cast(ubyte)(0.5f + inp[4*x+1] * 255.0f);
        ubyte b = cast(ubyte)(0.5f + inp[4*x+2] * 255.0f);
        ubyte a = cast(ubyte)(0.5f + inp[4*x+3] * 255.0f);
        *s++ = r;
        *s++ = g;
        *s++ = b;
        *s++ = a;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to RGBA 16-bit (0 to 65535).
void scanline_convert_rgbaf32_to_rgba16(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    ushort* s = cast(ushort*)outScan;
    for (int x = 0; x < width; ++x)
    {
        ushort r = cast(ushort)(0.5f + inp[4*x+0] * 65535.0f);
        ushort g = cast(ushort)(0.5f + inp[4*x+1] * 65535.0f);
        ushort b = cast(ushort)(0.5f + inp[4*x+2] * 65535.0f);
        ushort a = cast(ushort)(0.5f + inp[4*x+3] * 65535.0f);
        *s++ = r;
        *s++ = g;
        *s++ = b;
        *s++ = a;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to RGBA 32-bit float.
void scanline_convert_rgbaf32_to_rgbaf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    memcpy(outScan, inScan, width * 4 * float.sizeof);
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to RGBA 8-bit (0 to 255) premultiplied.
void scanline_convert_rgbaf32_to_rgbap8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    ubyte* s = outScan;
    for (int x = 0; x < width; ++x)
    {
        ubyte r = cast(ubyte)(0.5f + inp[4*x+0] * inp[4*x+3] * 255.0f);
        ubyte g = cast(ubyte)(0.5f + inp[4*x+1] * inp[4*x+3] * 255.0f);
        ubyte b = cast(ubyte)(0.5f + inp[4*x+2] * inp[4*x+3] * 255.0f);
        ubyte a = cast(ubyte)(0.5f + inp[4*x+3] * 255.0f);
        *s++ = r;
        *s++ = g;
        *s++ = b;
        *s++ = a;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to RGBA 16-bit (0 to 65535) premultiplied.
void scanline_convert_rgbaf32_to_rgbap16(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    ushort* s = cast(ushort*)outScan;
    for (int x = 0; x < width; ++x)
    {
        ushort r = cast(ushort)(0.5f + inp[4*x+0] * inp[4*x+3] * 65535.0f);
        ushort g = cast(ushort)(0.5f + inp[4*x+1] * inp[4*x+3] * 65535.0f);
        ushort b = cast(ushort)(0.5f + inp[4*x+2] * inp[4*x+3] * 65535.0f);
        ushort a = cast(ushort)(0.5f + inp[4*x+3] * 65535.0f);
        *s++ = r;
        *s++ = g;
        *s++ = b;
        *s++ = a;
    }
}

/// Convert a row of pixel from RGBA 32-bit float (0 to 1) to RGBA 32-bit float (0 to 1) premultiplied.
void scanline_convert_rgbaf32_to_rgbapf32(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    const(float)* inp = cast(const(float)*) inScan;
    float* s = cast(float*) outScan;
    for (int x = 0; x < width; ++x)
    {
        float a = inp[4*x+3];
        *s++ = inp[4*x+0] * a;
        *s++ = inp[4*x+1] * a;
        *s++ = inp[4*x+2] * a;
        *s++ = a;
    }
}



//
// BMP ordering functions
//

/// Convert a row of pixel from RGBA 8-bit (0 to 255) to BGRA 8-bit (0 to 255).
void scanline_convert_rgba8_to_bgra8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    for (int x = 0; x < width; ++x)
    {
        outScan[4*x+0] = inScan[4*x+2];
        outScan[4*x+1] = inScan[4*x+1];
        outScan[4*x+2] = inScan[4*x+0];
        outScan[4*x+3] = inScan[4*x+3];
    }
}
///ditto
alias scanline_convert_bgra8_to_rgba8 = scanline_convert_rgba8_to_bgra8;

/// Convert a row of pixel from RGB 8-bit (0 to 255) to BGR 8-bit (0 to 255).
void scanline_convert_rgb8_to_bgr8(const(ubyte)* inScan, ubyte* outScan, int width, void* userData = null)
{
    for (int x = 0; x < width; ++x)
    {
        outScan[3*x+0] = inScan[3*x+2];
        outScan[3*x+1] = inScan[3*x+1];
        outScan[3*x+2] = inScan[3*x+0];
    }
}
///ditto
alias scanline_convert_bgr8_to_rgb8 = scanline_convert_rgb8_to_bgr8;


/// See_also: OpenGL ES specification 2.3.5.1 and 2.3.5.2 for details about converting from 
/// floating-point to integers, and the other way around.
void convertToIntermediateScanline(PixelType srcType, 
                                   const(ubyte)* src, 
                                   PixelType dstType, 
                                   ubyte* dest, int width) @system
{
    if (dstType == PixelType.rgba8)
    {
        switch(srcType) with (PixelType)
        {
            case l8:      scanline_convert_l8_to_rgba8    (src, dest, width); break;
            case la8:     scanline_convert_la8_to_rgba8   (src, dest, width); break;
            case rgb8:    scanline_convert_rgb8_to_rgba8  (src, dest, width); break;
            case rgba8:   scanline_convert_rgba8_to_rgba8 (src, dest, width); break;
            default:
                assert(false); // should not use rgba8 as intermediate type
        }
    }
    else if (dstType == PixelType.rgbaf32)
    {
        final switch(srcType) with (PixelType)
        {
            case unknown: assert(false);
            case l8:      scanline_convert_l8_to_rgbaf32     (src, dest, width); break;
            case l16:     scanline_convert_l16_to_rgbaf32    (src, dest, width); break;
            case lf32:    scanline_convert_lf32_to_rgbaf32   (src, dest, width); break;
            case la8:     scanline_convert_la8_to_rgbaf32    (src, dest, width); break;
            case la16:    scanline_convert_la16_to_rgbaf32   (src, dest, width); break;
            case laf32:   scanline_convert_laf32_to_rgbaf32  (src, dest, width); break;
            case lap8:    scanline_convert_lap8_to_rgbaf32    (src, dest, width); break;
            case lap16:   scanline_convert_lap16_to_rgbaf32   (src, dest, width); break;
            case lapf32:  scanline_convert_lapf32_to_rgbaf32  (src, dest, width); break;
            case rgb8:    scanline_convert_rgb8_to_rgbaf32   (src, dest, width); break;
            case rgb16:   scanline_convert_rgb16_to_rgbaf32  (src, dest, width); break;
            case rgbf32:  scanline_convert_rgbf32_to_rgbaf32 (src, dest, width); break;
            case rgba8:   scanline_convert_rgba8_to_rgbaf32  (src, dest, width); break;
            case rgba16:  scanline_convert_rgba16_to_rgbaf32 (src, dest, width); break;
            case rgbaf32: scanline_convert_rgbaf32_to_rgbaf32(src, dest, width); break;
            case rgbap8:  scanline_convert_rgbap8_to_rgbaf32  (src, dest, width); break;
            case rgbap16: scanline_convert_rgbap16_to_rgbaf32 (src, dest, width); break;
            case rgbapf32:scanline_convert_rgbapf32_to_rgbaf32(src, dest, width); break;
        }
    }
    else
        assert(false);
}

void convertFromIntermediate(PixelType srcType, const(ubyte)* src, PixelType dstType, ubyte* dest, int width) @system
{
    if (srcType == PixelType.rgba8)
    {
        alias inp = src;
        switch(dstType) with (PixelType)
        {
            case l8:      scanline_convert_rgba8_to_l8    (src, dest, width); break;
            case la8:     scanline_convert_rgba8_to_la8   (src, dest, width); break;
            case rgb8:    scanline_convert_rgba8_to_rgb8  (src, dest, width); break;
            case rgba8:   scanline_convert_rgba8_to_rgba8 (src, dest, width); break;
            default:
                assert(false); // should not use rgba8 as intermediate type
        }
    }
    else if (srcType == PixelType.rgbaf32)
    {    
        const(float)* inp = cast(const(float)*) src;
        final switch(dstType) with (PixelType)
        {
            case unknown: assert(false);
            case l8:      scanline_convert_rgbaf32_to_l8     (src, dest, width); break;
            case l16:     scanline_convert_rgbaf32_to_l16    (src, dest, width); break;
            case lf32:    scanline_convert_rgbaf32_to_lf32   (src, dest, width); break;
            case la8:     scanline_convert_rgbaf32_to_la8    (src, dest, width); break;
            case la16:    scanline_convert_rgbaf32_to_la16   (src, dest, width); break;
            case laf32:   scanline_convert_rgbaf32_to_laf32  (src, dest, width); break;
            case lap8:    scanline_convert_rgbaf32_to_lap8    (src, dest, width); break;
            case lap16:   scanline_convert_rgbaf32_to_lap16   (src, dest, width); break;
            case lapf32:  scanline_convert_rgbaf32_to_lapf32  (src, dest, width); break;
            case rgb8:    scanline_convert_rgbaf32_to_rgb8   (src, dest, width); break;
            case rgb16:   scanline_convert_rgbaf32_to_rgb16  (src, dest, width); break;
            case rgbf32:  scanline_convert_rgbaf32_to_rgbf32 (src, dest, width); break;
            case rgba8:   scanline_convert_rgbaf32_to_rgba8  (src, dest, width); break;
            case rgba16:  scanline_convert_rgbaf32_to_rgba16 (src, dest, width); break;
            case rgbaf32: scanline_convert_rgbaf32_to_rgbaf32(src, dest, width); break;
            case rgbap8:  scanline_convert_rgbaf32_to_rgbap8  (src, dest, width); break;
            case rgbap16: scanline_convert_rgbaf32_to_rgbap16 (src, dest, width); break;
            case rgbapf32:scanline_convert_rgbaf32_to_rgbapf32(src, dest, width); break;
        }
    }
    else
        assert(false);
}
