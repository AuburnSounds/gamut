/**
Public API for gamut.

Copyright: Copyright Guillaume Piolat 2022
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut;

/// This is the public API, guaranteed not to break inside a major SemVer version.
public import gamut.image;
public import gamut.types;
public import gamut.io;
public import gamut.scanline; // scanline conversion is also in the public API!

nothrow @nogc @safe:

// <Compatibility with imagefmt API>

/// Basic image information.
struct IFInfo 
{
    int w;              /// width
    int h;              /// height
    ubyte c;            /// channels
    ubyte e;            /// error code or zero
}

/// Image returned from the read functions. Data is in buf8 or buf16 or buf32. 
/// Top-left corner will be at (0, 0).
struct IFImage 
{
    int w;              /// width
    int h;              /// height
    ubyte c;            /// channels in buf, 1 = y, 2 = ya, 3 = rgb, 4 = rgba
    ubyte cinfile;      /// channels found in file NOT IMPLEMENTED IN GAMUT
    ubyte bpc;          /// bits per channel, 8 or 16 or 32
    ubyte e;            /// error code or zero
    union {
        ubyte[]  buf8;  ///
        ushort[] buf16; ///
        float[]  buf32; ///
    }

    @nogc nothrow:

    /// Frees the image data.
    /// Must be called by user.
    void free() @trusted 
    {
        freeImageData(buf8.ptr);
        buf8 = null;
    }
}

public IFInfo read_info(in char[] fname)
{
    Image image;
    IFImage res;
    // PERF: inneficient since flag not implemented
    image.loadFromFile(fname, LOAD_NO_PIXELS);
    IFInfo info;
    if (image.isError)
        info.e = 1;
    else
    {
        info.w = image.width;
        info.h = image.height;
        info.c = cast(ubyte) image.channels();
        info.e = 1;
    }
    return info;
}

/// Reads an image from buf.
public IFImage read_image(in ubyte[] buf, 
                          in int c = 0, 
                          in int bpc = 8) @trusted
{
    Image image;    
    image.loadFromMemory(buf, flagsForImageFmt(c, bpc));
    return GamutImage_to_IFImage(image);
}

/// Reads an image file, detecting its type.
public IFImage read_image(in char[] fname, 
                          in int c = 0, 
                          in int bpc = 8) @trusted
{
    Image image;    
    image.loadFromFile(fname, flagsForImageFmt(c, bpc));
    return GamutImage_to_IFImage(image);
}

/// Returns 0 on success, else an error code. Assumes RGB order for 
/// color components in buf, if present. 
/// Note: The file will remain even if the write fails.
/// Only for 8-bit images, use the Gamut API directly else.
ubyte write_image(in char[] fname, 
                  int w, 
                  int h, 
                  in ubyte[] buf, 
                  int reqchans = 0) @trusted
{
    auto type = gamutTypeFromReqChans(reqchans);
    assert(buf.length == reqchans * w * h);
    Image image;
    image.createView(cast(ubyte*)(buf.ptr), w, h, type, w * pixelTypeSize(type));
    bool success = image.saveToFile(fname);
    return success ? 0 : 1;
}

enum IF_BMP = 0;    /// the BMP format
enum IF_TGA = 1;    /// the TGA format
enum IF_PNG = 2;    /// the PNG format
enum IF_JPG = 3;    /// the JPEG format


/// Returns 0 on success, else an error code. Assumes RGB order for 
/// color components in buf, if present. 
/// The returned data must be released with a call to `freeEncodedImage`.
/// Only for 8-bit images, use the Gamut API directly else.
ubyte[] write_image_mem(int fmt, 
                        int w, 
                        int h, 
                        in ubyte[] buf, 
                        int reqchans, 
                        out int e) @trusted
{
    auto type = gamutTypeFromReqChans(reqchans);
    assert(buf.length == reqchans * w * h);
    Image image;
    image.createView(cast(ubyte*)buf.ptr, w, h, type, w * pixelTypeSize(type));
    ImageFormat gfmt = ImageFormat.PNG;
    if (fmt == IF_BMP) gfmt = ImageFormat.BMP; 
    if (fmt == IF_TGA) gfmt = ImageFormat.TGA; 
    if (fmt == IF_PNG) gfmt = ImageFormat.PNG; 
    if (fmt == IF_JPG) gfmt = ImageFormat.JPEG; 
    ubyte[] bytes = image.saveToMemory(gfmt, ENCODE_NORMAL);
    e = (bytes is null) ? 1 : 0;
    return bytes;
}

private PixelType gamutTypeFromReqChans(int reqchans)
{
    if (reqchans == 1) return PixelType.l8;
    else if (reqchans == 2) return PixelType.la8;
    else if (reqchans == 3) return PixelType.rgb8;
    else if (reqchans == 4) return PixelType.rgba8;
    else assert(false);
}


// disown and return an IFImage.
private IFImage GamutImage_to_IFImage(ref Image image) @trusted
{
    IFImage res;
    if (image.isValid)
    {
        res.w = image.width;
        res.h = image.height;
        res.c = cast(ubyte) image.channels();
        res.cinfile = res.c; // Note: gamut doesn't provide that
        res.bpc = cast(ubyte) image.bitsPerChannel();
        res.e = 0;
        ubyte* data = image.disownData();
        if (res.bpc == 8)
            res.buf8 = data[0..res.w*res.h*res.c];
        if (res.bpc == 16)
            res.buf16 = cast(ushort[])data[0..res.w*res.h*res.c*2];
        if (res.bpc == 32)
            res.buf32 = cast(float[])data[0..res.w*res.h*res.c*4];
    }
    else
        res.e = 1;
    return res;
}

private int flagsForImageFmt(int c, int bpp)
{    
    int flags = LOAD_NO_PREMUL 
              | LAYOUT_VERT_STRAIGHT 
              | LAYOUT_GAPLESS;    
    switch(c)
    {
        case 1: flags |= LOAD_NO_ALPHA | LOAD_GREYSCALE; break;
        case 2: flags |= LOAD_ALPHA    | LOAD_GREYSCALE; break;
        case 3: flags |= LOAD_NO_ALPHA | LOAD_RGB; break;
        case 4: flags |= LOAD_ALPHA    | LOAD_RGB; break;
        default: break;
    }
    switch(bpp)
    {
        case 8: flags |= LOAD_8BIT; break;
        case 16: flags |= LOAD_16BIT; break;
        case 32: flags |= LOAD_FP32; break;
        default: break;
    }
    return flags;
}

// </Compatibility with imagefmt API>