/**
BMP support.

Copyright: Copyright Guillaume Piolat 2022
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut.plugins.bmp;

nothrow @nogc @safe:

import core.stdc.stdlib: malloc, free, realloc;
import gamut.types;
import gamut.io;
import gamut.plugin;
import gamut.image;
import gamut.internals.errors;
import gamut.internals.types;


version(decodeBMP) import gamut.codecs.stbdec;
version(encodeBMP) import gamut.codecs.bmpenc;

ImageFormatPlugin makeBMPPlugin()
{
    ImageFormatPlugin p;
    p.format = "BMP";
    p.extensionList = "bmp,dib";
    p.mimeTypes = "image/bmp";
    version(decodeBMP)
        p.loadProc = &loadBMP;
    else
        p.loadProc = null;
    version(encodeBMP)
        p.saveProc = &saveBMP;
    else
        p.saveProc = null;
    p.detectProc = &detectBMP;
    return p;
}

// FUTURE: Note: detection API should report I/O errors other than yes/no for the test, 
// since stream might be fatally errored.
// Returning a ternary would be extra-nice.

bool detectBMP(IOStream *io, IOHandle handle) @trusted
{
    // save I/O cursor
    c_long offset = io.tell(handle);
    if (offset == -1) // IO error
        return false;

    uint ds;
    bool err;    
    ubyte b = io.read_ubyte(handle, &err); if (err) return false; // IO error
    if (b != 'B') goto no_match;

    b = io.read_ubyte(handle, &err); if (err) return false; // IO error
    if (b != 'M') goto no_match;
    
    if (!io.skipBytes(handle, 12))
        return false; // IO error

    ds = io.read_uint_LE(handle, &err); if (err) return false; // IO error

    if (ds == 12 || ds == 40 || ds == 52 || ds == 56 || ds == 108 || ds == 124)
        goto match;
    else
        goto no_match;

match:
    // restore I/O cursor
    if (!io.seekAbsolute(handle, offset))
        return false; // IO error
    return true;

no_match:
    // restore I/O cursor
    if (!io.seekAbsolute(handle, offset))
        return false; // IO error

    return false;
}

version(decodeBMP)
void loadBMP(ref Image image, IOStream *io, IOHandle handle, int page, int flags, void *data) @trusted
{
    // prepare STB callbacks
    IOAndHandle ioh;
    stbi_io_callbacks stb_callback;
    initSTBCallbacks(io, handle, &ioh, &stb_callback);
       
    int requestedComp = computeRequestedImageComponents(flags);
    if (requestedComp == 0) // error
    {
        image.error(kStrInvalidFlags);
        return;
    }
    if (requestedComp == -1)
        requestedComp = 0; // auto

    ubyte* decoded;
    int width, height, components;

    float ppmX = -1;
    float ppmY = -1;
    float pixelRatio = -1;

    // PERF: let stb_image return a flipped bitmap, so that to save some time on load.

    decoded = stbi_load_from_callbacks(&stb_callback, &ioh, &width, &height, &components, requestedComp,
                                       &ppmX, &ppmY, &pixelRatio);

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

    image._allocArea = decoded; // Note: coupling, works because stb and gamut both use malloc/free
    image._width = width;
    image._height = height;
    image._data = decoded; 
    image._pitch = width * components;
    image._pixelAspectRatio = (pixelRatio == -1) ? GAMUT_UNKNOWN_ASPECT_RATIO : pixelRatio;
    image._resolutionY = (ppmY == -1) ? GAMUT_UNKNOWN_RESOLUTION : convertInchesToMeters(ppmY);
    image._layoutConstraints = LAYOUT_DEFAULT; // STB decoder follows no particular constraints (TODO?)
    image._layerCount = 1;
    image._layerOffset = 0;

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
    else
        assert(false);

    PixelType targetType = applyLoadFlags(image._type, flags);

    // Convert to target type and constraints
    image.convertTo(targetType, cast(LayoutConstraints) flags);
}

version(encodeBMP)
bool saveBMP(ref const(Image) image, IOStream *io, IOHandle handle, int page, int flags, void *data) @trusted
{
    if (page != 0)
        return false;    

    int components;

    // For now, can save RGB and RGBA 8-bit images.
    switch (image._type)
    {
        case PixelType.rgb8:
            components = 3; break;
        case PixelType.rgba8:
            components = 4; 
            break;
        default:
            return false;
    }

    int width = image._width;
    int height = image._height;
    int pitch = image._pitch;
    if (width < 1 || height < 1 || width > 32767 || height > 32767)
        return false; // Can't be saved as BMP

    bool success = write_bmp(image, io, handle, width, height, components);

    return success;
}

