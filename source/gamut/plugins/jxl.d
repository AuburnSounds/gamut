/**
JPEG XL support.

Copyright: Copyright Guillaume Piolat 2024
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut.plugins.jxl;

nothrow @nogc @safe:

import core.stdc.stdlib: malloc, free, realloc;
import gamut.types;
import gamut.io;
import gamut.plugin;
import gamut.image;
import gamut.internals.errors;
import gamut.internals.types;

version(decodeJXL) import gamut.codecs.j40;

ImageFormatPlugin makeJXLPlugin()
{
    ImageFormatPlugin p;
    p.format = "JPEG XL";
    p.extensionList = "jxl";
    p.mimeTypes = "image/jxl";
    version(decodeJXL)
        p.loadProc = &loadJXL;
    else
        p.loadProc = null;
    p.saveProc = null;
    p.detectProc = &detectJXL;
    return p;
}


version(decodeJXL)
void loadJXL(ref Image image, IOStream *io, IOHandle handle, int page, int flags, void *data) @trusted
{
    // Read whole file at once.
    // PERF: j40 could use our IOStream directly eventually.

    // Find length of input
    if (io.seek(handle, 0, SEEK_END) != 0)
    {
        image.error(kStrImageDecodingIOFailure);
        return;
    }

    int len = cast(int) io.tell(handle); // works, see io.d for why

    if (!io.rewind(handle))
    {
        image.error(kStrImageDecodingIOFailure);
        return;
    }

    ubyte* buf = cast(ubyte*) malloc(len);
    if (buf is null)
    {
        image.error(kStrImageDecodingMallocFailure);
        return;
    }
    scope(exit) free(buf);

    int requestedComp = computeRequestedImageComponents(flags);
    if (requestedComp == 0) // error
    {
        image.error(kStrInvalidFlags);
        return;
    }

    // read all input at once.
    if (len != io.read(buf, 1, len, handle))
    {
        image.error(kStrImageDecodingIOFailure);
        return;
    }

    j40_image jxlimage;
    if (j40_from_memory(&jxlimage, buf, len, null))
    {
        image.error(kStrImageDecodingFailed);
        return;
    }

    scope(exit) j40_free(&jxlimage);

    if (j40_output_format(&jxlimage, J40_RGBA, J40_U8X4))
    {
        image.error(kStrImageDecodingFailed);
        return;
    }

    if (0 == j40_next_frame(&jxlimage)) 
    {
        // No image.
        image.error(kStrImageDecodingFailed);
        return;
    }

    if (j40_error(&jxlimage)) 
    {
        // Note: j40_error_string(&image) is disregarded here
        image.error(kStrImageDecodingFailed);
        return;
    }

    j40_frame frame = j40_current_frame(&jxlimage);
    j40_pixels_u8x4 pixels = j40_frame_pixels_u8x4(&frame, J40_RGBA);
    if (pixels.data is null)
    {
        image.error(kStrImageDecodingFailed);
        return;
    }

    // Since J40 renders in a buffer created with _mm_malloc aligned on 32-byte, 
    // we can't use it as is in gamut and have to copy.
    // Allocate new pixel 
    // PERF: modify j40 to at least allow us to steal the allocation, save a copy sometimes

    Image view;
    view.createView(cast(void*) pixels.data, // const_cast here
                    pixels.width, 
                    pixels.height, 
                    PixelType.rgba8,
                    pixels.stride_bytes);
    image = view.clone();

    // TODO: resolution/aspect ratio from JPEG XL
    image._pixelAspectRatio  = GAMUT_UNKNOWN_ASPECT_RATIO;
    image._resolutionY       = GAMUT_UNKNOWN_RESOLUTION;
    
    image._layoutConstraints = LAYOUT_DEFAULT;
    image._layerCount = 1;
    image._layerOffset = 0;

    // Convert to target type and constraints
    image.convertTo(applyLoadFlags(image._type, flags), cast(LayoutConstraints) flags);
}

bool detectJXL(IOStream *io, IOHandle handle) @trusted
{
    // Note: only 'naked' codestream supported.
    // JPEG XL encapsulated in ISO BMFF not supported.
    static immutable ubyte[2] jxlSignature = [0xFF, 0x0A];
    return fileIsStartingWithSignature(io, handle, jxlSignature);
}
