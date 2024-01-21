/**
PNG support.

Copyright: Copyright Guillaume Piolat 2022
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut.plugins.png;

nothrow @nogc @safe:

import core.stdc.stdlib: malloc, free, realloc;
import gamut.types;
import gamut.io;
import gamut.plugin;
import gamut.image;
import gamut.internals.errors;
import gamut.internals.types;

version(decodePNG) import gamut.codecs.stbdec;
version(encodePNG) import gamut.codecs.stb_image_write;

ImageFormatPlugin makePNGPlugin()
{
    ImageFormatPlugin p;
    p.format = "PNG";
    p.extensionList = "png";
    p.mimeTypes = "image/png";
    version(decodePNG)
        p.loadProc = &loadPNG;
    else
        p.loadProc = null;
    version(encodePNG)
        p.saveProc = &savePNG;
    else
        p.saveProc = null;
    p.detectProc = &detectPNG;
    return p;
}


// PERF: STB callbacks could disappear in favor of our own callbakcs, to avoid one step.

version(decodePNG)
void loadPNG(ref Image image, IOStream *io, IOHandle handle, int page, int flags, void *data) @trusted
{
    IOAndHandle ioh;
    ioh.io = io;
    ioh.handle = handle;

    stbi_io_callbacks stb_callback;
    stb_callback.read = &stb_read;
    stb_callback.skip = &stb_skip;
    stb_callback.eof = &stb_eof;

    bool is16bit = stbi__png_is16(&stb_callback, &ioh);

    ubyte* decoded;
    int width, height, components;

    int requestedComp = computeRequestedImageComponents(flags);
    if (requestedComp == 0) // error
    {
        image.error(kStrInvalidFlags);
        return;
    }
    if (requestedComp == -1)
        requestedComp = 0; // auto

    // rewind stream
    if (!io.rewind(handle))
    {
        image.error(kStrImageDecodingIOFailure);
        return;
    }

    float ppmX = -1;
    float ppmY = -1;
    float pixelRatio = -1;

    // PERF: this could be overriden to use internal 8-bit <-> 10-bit stb conversion

    bool decodeTo16bit = is16bit;
    if (flags & LOAD_8BIT) decodeTo16bit = false;
    if (flags & LOAD_16BIT) decodeTo16bit = true;

    if (decodeTo16bit)
    {
        decoded = cast(ubyte*) stbi_load_16_from_callbacks(&stb_callback, &ioh, &width, &height, &components, requestedComp,
                                                           &ppmX, &ppmY, &pixelRatio);
    }
    else
    {
        decoded = stbi_load_from_callbacks(&stb_callback, &ioh, &width, &height, &components, requestedComp,
                                           &ppmX, &ppmY, &pixelRatio);
    }

    if (requestedComp != 0)
        components = requestedComp;

    if (decoded is null)
    {
        image.error(kStrImageDecodingFailed);
        return;
    }    

    if (!imageIsValidSize(1, width, height))
    {
        image.error(kStrImageTooLarge);
        free(decoded);
        return;
    }

    image._allocArea = decoded; // works because codec.pngload and gamut both use malloc/free
    image._width = width;
    image._height = height;
    image._data = decoded; 
    image._pitch = width * components * (decodeTo16bit ? 2 : 1);

    image._pixelAspectRatio = (pixelRatio == -1) ? GAMUT_UNKNOWN_ASPECT_RATIO : pixelRatio;
    image._resolutionY = (ppmY == -1) ? GAMUT_UNKNOWN_RESOLUTION : convertInchesToMeters(ppmY);
    image._layoutConstraints = LAYOUT_DEFAULT; // STB decoder follows no particular constraints (TODO?)
    image._layerCount = 1;
    image._layerOffset = 0;

    if (!decodeTo16bit)
    {
        if (components == 1)
        {
            image._type = PixelType.l8;
        }
        else if (components == 2)
        {
            image._type = PixelType.la8;
        }
        else if (components == 3)
        {
            image._type = PixelType.rgb8;
        }
        else if (components == 4)
        {
            image._type = PixelType.rgba8;
        }
    }
    else
    {
        if (components == 1)
        {
            image._type = PixelType.l16;
        }
        else if (components == 2)
        {
            image._type = PixelType.la16;
        }
        else if (components == 3)
        {
            image._type = PixelType.rgb16;
        }
        else if (components == 4)
        {
            image._type = PixelType.rgba16;
        }
    }

    PixelType targetType = applyLoadFlags(image._type, flags);

    // Convert to target type and constraints
    image.convertTo(targetType, cast(LayoutConstraints) flags);
}

bool detectPNG(IOStream *io, IOHandle handle) @trusted
{
    static immutable ubyte[8] pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    return fileIsStartingWithSignature(io, handle, pngSignature);
}

version(encodePNG)
bool savePNG(ref const(Image) image, IOStream *io, IOHandle handle, int page, int flags, void *data) @trusted
{
    if (page != 0)
        return false;

    int channels = 0;
    bool is16Bit = false;
    switch (image._type)
    {
        case PixelType.l8:     channels = 1; break;
        case PixelType.la8:    channels = 2; break;
        case PixelType.rgb8:   channels = 3; break;
        case PixelType.rgba8:  channels = 4; break;
        case PixelType.l16:    channels = 1; is16Bit = true; break;
        case PixelType.la16:   channels = 2; is16Bit = true; break;
        case PixelType.rgb16:  channels = 3; is16Bit = true; break;
        case PixelType.rgba16: channels = 4; is16Bit = true; break;
        default:
            return false;
    }

    int width = image._width;
    int height = image._height;
    int pitch = image._pitch;

    int len;
    const(ubyte)* pixels = image._data;

    // PERF: use stb_image_write stbi_write_png_to_func instead.
    ubyte *encoded = gamut.codecs.stb_image_write.stbi_write_png_to_mem(pixels, pitch, width, height, channels, &len, is16Bit);
    if (encoded == null)
        return false;

    scope(exit) free(encoded);

    // Write all output at once. This is rather bad, could be done progressively.
    // PERF: adapt stb_image_write.h to output in our own buffer directly.
    if (len != io.write(encoded, 1, len, handle))
        return false;

    return true;
}

private:

// Need to give both a IOStream* and a IOHandle to STB callbacks.
static struct IOAndHandle
{
    IOStream* io;
    IOHandle handle;
}

// fill 'data' with 'size' bytes.  return number of bytes actually read
int stb_read(void *user, char *data, int size) @system
{
    IOAndHandle* ioh = cast(IOAndHandle*) user;

    // Cannot ask more than 0x7fff_ffff bytes at once.
    assert(size <= 0x7fffffff);

    size_t bytesRead = ioh.io.read(data, 1, size, ioh.handle);
    return cast(int) bytesRead;
}

// skip the next 'n' bytes, or 'unget' the last -n bytes if negative
void stb_skip(void *user, int n) @system
{
    IOAndHandle* ioh = cast(IOAndHandle*) user;
    ioh.io.skipBytes(ioh.handle, n);
}

// returns nonzero if we are at end of file/data
int stb_eof(void *user) @system
{
    IOAndHandle* ioh = cast(IOAndHandle*) user;
    return ioh.io.eof(ioh.handle);
}