/**
WebP support.

Copyright: Copyright Guillaume Piolat 2026
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut.plugins.webp;

nothrow @nogc @safe:

import core.stdc.stdlib: malloc, free, realloc;
import gamut.types;
import gamut.io;
import gamut.plugin;
import gamut.image;
import gamut.internals.errors;
import gamut.internals.types;

version(decodeWEBP) import gamut.codecs.tiny_webp;

ImageFormatPlugin makeWEBPPlugin()
{
    ImageFormatPlugin p;
    p.format = "JPEG XL";
    p.extensionList = "webp";
    p.mimeTypes = "image/webp";
    version(decodeWEBP)
        p.loadProc = &loadWEBP;
    else
        p.loadProc = null;
    p.saveProc = null;
    p.detectProc = &detectWEBP;
    return p;
}


version(decodeWEBP)
void loadWEBP(ref Image image, IOStream *io, IOHandle handle, int page, int flags, void *data) @trusted
{
    // PERF: use IOStream instead of whole file at once

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

    // read all input at once into `buf`
    if (len != io.read(buf, 1, len, handle))
    {
        image.error(kStrImageDecodingIOFailure);
        return;
    }    

    // MAYDO: support twp_FLAG_SKIP_LOOP_FILTER, supposedly faster
    // decoding for worse quality.

    // PERF: use twp_FORMAT_RGB if allowed by flags

    int decflags = 0;
    int width, height;
    ubyte* decoded = twp_read_from_memory(buf, len, &width, &height, twp_FORMAT_RGBA, decflags);

    if (decoded == null)
    {
        image.error(kStrImageDecodingFailed);
        return;
    }

    image._allocArea = decoded;
    image._data      = decoded;
    image._width     = width;
    image._height    = height;
    image._type      = PixelType.rgba8;
    image._pitch     = 4 * width;
    image._pixelAspectRatio = GAMUT_UNKNOWN_ASPECT_RATIO;
    image._resolutionY = GAMUT_UNKNOWN_RESOLUTION;
    image._layoutConstraints = 0; // no particular constraint followed in QOI decoder.
    image._layerCount = 1;
    image._layerOffset = 0;

    // Convert to target type and constraints
    image.convertTo(applyLoadFlags(image._type, flags), cast(LayoutConstraints) flags);
}

bool detectWEBP(IOStream *io, IOHandle handle) @trusted
{
    version(decodeWEBP)
    {
        // save I/O cursor
        c_long offset = io.tell(handle);

        bool match = false;

        // Get first 30 bytes
        ubyte[30] start;
        if (30 == io.read(start.ptr, 1, 30, handle))
        {
            int w, h, lossless, alpha;
            int res = twp_get_info_from_memory(start.ptr, 30, &w, &h, &lossless, &alpha);
            match = (res == 1);
        }

        // restore I/O cursor
        if (!io.seekAbsolute(handle, offset))
        {
            // TODO: that rare error should propagate somehow, 
            // we couldn't reset the cursor hence more detection will fail.
            return false; 
        }
        return match;
    }
    else
    {
        return false;
    }
}