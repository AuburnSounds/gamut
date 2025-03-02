/**
SQZ support.

Copyright: Copyright Guillaume Piolat 2025
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut.plugins.sqz;

nothrow @nogc @safe:

import core.stdc.stdlib: malloc, free, realloc;
import core.stdc.string: memset;
import gamut.types;
import gamut.io;
import gamut.plugin;
import gamut.image;
import gamut.internals.errors;
import gamut.internals.types;

version(decodeSQZ) import gamut.codecs.sqz;
else version(encodeSQZ) import gamut.codecs.sqz;

ImageFormatPlugin makeSQZPlugin()
{
    ImageFormatPlugin p;
    p.format = "SQZ";
    p.extensionList = "sqz";
    p.mimeTypes = "image/sqz"; // had to invent
    version(decodeSQZ)
        p.loadProc = &loadSQZ;
    else
        p.loadProc = null;
    version(encodeSQZ)
        p.saveProc = &saveSQZ;
    else
        p.saveProc = null;
    p.detectProc = &detectSQZ;
    return p;
}


version(decodeSQZ)
void loadSQZ(ref Image image, IOStream *io, IOHandle handle, int page, int flags, void *data) @trusted
{
    // Read all available bytes from input

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

    // read all input at once.
    if (len != io.read(buf, 1, len, handle))
    {
        image.error(kStrImageDecodingIOFailure);
        return;
    }

    // Find out size needed
    size_t dest_size;
    SQZ_image_descriptor_t desc;
    SQZ_status_t st = SQZ_decode(buf, null, len, &dest_size, &desc);
    if (st != SQZ_BUFFER_TOO_SMALL)
    {
        image.error(kStrImageDecodingIOFailure);
        return;
    }

    /// No Gamut `Image` can exceed this width.
    if ( (desc.width > GAMUT_MAX_IMAGE_WIDTH)
        || (desc.height > GAMUT_MAX_IMAGE_HEIGHT) 
        || (dest_size > GAMUT_MAX_IMAGE_BYTES) )
    {
        image.error(kStrImageTooLarge);
        return;
    }

    int w = cast(int)desc.width;
    int h = cast(int)desc.height;

    // Now we know the number of planes. Can be 1 or 3.
    if (desc.num_planes == 1)
        image._type = PixelType.l8;
    else if (desc.num_planes == 3)
        image._type = PixelType.rgb8;
    else
    {
        image.error(kStrImageDecodingIOFailure);
        return;
    }

    ubyte* decoded = cast(ubyte*) malloc(dest_size);
    st = SQZ_decode(buf, decoded, len, &dest_size, &desc);
    if (st != SQZ_RESULT_OK)
    {
        free(decoded);
        image.error(kStrImageDecodingIOFailure);
        return;
    }

    image._width = w;
    image._height = h;
    image._allocArea = decoded;
    image._data = decoded;
    image._pitch = cast(int)(w * desc.num_planes);
    image._pixelAspectRatio  = GAMUT_UNKNOWN_ASPECT_RATIO;
    image._resolutionY       = GAMUT_UNKNOWN_RESOLUTION;
    image._layoutConstraints = LAYOUT_DEFAULT;
    image._layerCount = 1;
    image._layerOffset = 0;

    // Convert to target type and constraints
    image.convertTo(applyLoadFlags(image._type, flags), cast(LayoutConstraints) flags);
}

bool detectSQZ(IOStream *io, IOHandle handle) @trusted
{
    static immutable ubyte[1] sqzSignature = [0xA5]; // unfortunately not very discriminating
    return fileIsStartingWithSignature(io, handle, sqzSignature);
}

version(encodeSQZ)
bool saveSQZ(ref const(Image) image, IOStream *io, IOHandle handle, int page, int flags, void *data) @trusted
{
    if (page != 0)
        return false;

    if (image.width < 8 || image.height < 8)
        return false;

    if (image.type != PixelType.rgb8) // only this type supported for now
        return false;

    int flagsBPP = ((flags & ENCODE_SQZ_QUALITY_MAX) >>> 5);
    if (flagsBPP == 0)
        flagsBPP = 0x50;
    double bpp = flagsBPP / 32.0f;

    long maxSize = SQZ_HEADER_SIZE + cast(long)( (cast(double)image.width) * image.height * bpp / 8.0 );

    if (maxSize > size_t.max)
        return false; // too big an image

    // Create a maximum sized buffer
    ubyte* encoded = cast(ubyte*) malloc(cast(size_t)maxSize);
    scope(exit) free(encoded);

    // Must be filed with zeroes, since the decoder does |= on it.
    // PERF: not sure about that, actually
    memset(encoded, 0, cast(size_t)maxSize);

    size_t budget = cast(size_t)maxSize;

    SQZ_image_descriptor_t desc;
    desc.width = image.width;
    desc.height = image.height;
    desc.color_mode = SQZ_COLOR_MODE_OKLAB; // Oklab, TODO check with 
    desc.dwt_levels = 7; // TODO tune one day
    desc.subsampling = 1; // TODO Is worth it?

    // TODO: SQZ encoder should take a pitch
    ubyte* content = cast(ubyte*) image.allPixelsAtOnce.ptr;
    SQZ_status_t st = SQZ_encode(content, encoded, &desc, &budget);

    if (st != SQZ_RESULT_OK)
        return false;

    assert(*encoded == 0xA5);

    // PERF: this could use the IOstream inside the codec perhaps
    if (1 != io.write(encoded, budget, 1, handle))
    {
        return false;
    }

    return true;
}