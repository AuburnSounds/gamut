/**
Various public types.

Copyright: Copyright Guillaume Piolat 2022
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut.types;

nothrow @nogc:
@safe:

/// Image format.
/// It is the kind of container/codec formats Gamut can read and write to.
enum ImageFormat
{
    unknown = -1, /// Unknown format (returned value only, never use it as input value)
    first   =  0,
    JPEG    =  0, /// Independent JPEG Group (*.JPG, *.JIF, *.JPEG, *.JPE)
    PNG     =  1, /// Portable Network Graphics (*.PNG)
    QOI     =  2, /// Quite OK Image format (*.QOI)
    QOIX    =  3, /// Quite OK Image format, eXtended as in Gamut library (*.QOIX)
    DDS     =  4, /// Compressed texture formats.
    TGA     =  5, /// Truevision TGA
    GIF     =  6, /// Graphics Interchange Format
    BMP     =  7, /// Windows or OS/2 Bitmap File (*.BMP)
}

/// Pixel component type.
/// Integer components are stored normalized (255 or 65535 being the maximum of intensity).
enum PixelType
{
    unknown = -1, /// Unknown format (returned value only, never use it as input value)

    l8,           /// Array of ubyte: unsigned 8-bit
    l16,          /// Array of ushort: unsigned 16-bit
    lf32,         /// Array of float: 32-bit IEEE floating point
    
    la8,          /// 16-bit Luminance Alpha image: 2 x unsigned 8-bit
    la16,         /// 32-bit Luminance Alpha image: 2 x unsigned 16-bit
    laf32,        /// 64-bit Luminance Alpha image: 2 x 32-bit IEEE floating point

    rgb8,         /// 24-bit RGB image: 3 x unsigned 8-bit
    rgb16,        /// 48-bit RGB image: 3 x unsigned 16-bit
    rgbf32,       /// 96-bit RGB float image: 3 x 32-bit IEEE floating point

    rgba8,        /// 32-bit RGBA image: 4 x unsigned 8-bit
    rgba16,       /// 64-bit RGBA image: 4 x unsigned 16-bit    
    rgbaf32,      /// 128-bit RGBA float image: 4 x 32-bit IEEE floating point
}


// Limits



/// When images have an unknown DPI resolution;
enum GAMUT_UNKNOWN_RESOLUTION = -1;

/// When images have an unknown physical pixel ratio.
/// Explanation: it is possible to have a known pixel ratio, but an unknown DPI (eg: PNG).
enum GAMUT_UNKNOWN_ASPECT_RATIO = -1;

/// No Gamut `Image` can exceed this width.
enum int GAMUT_MAX_IMAGE_WIDTH = 16777216;  

/// No Gamut `Image` can exceed this height.
enum int GAMUT_MAX_IMAGE_HEIGHT = 16777216;

/// No Gamut `Image` can have this many layers.
enum int GAMUT_MAX_IMAGE_LAYERS = 4194303; // A bit arbitrary, but can be pretty long even as 120fps video.


/// No Gamut `Image` can have a size that exceeds this value.
/// Technically, the true maximum is `MAX(size_t.max, GAMUT_MAX_IMAGE_BYTES)`.
/// So this is worth 32gb. Cannot really exceed that size with just malloc/realloc.
/// Not strictly needed, but such a large allocation is indicative of forged images / attacks anyway.
/// For the decoders limitations themselves, see Issue #   resolution.
enum long GAMUT_MAX_IMAGE_BYTES = 34359738368; 


/// Converts from meters to inches.
float convertMetersToInches(float x) pure
{
    return x * 39.37007874f;
}

/// Converts from inches to meters.
float convertInchesToMeters(float x) pure
{
    return x / 39.37007874f;
}

/// Converts from PPM (Points Per Meter) to DPI (Dots Per Inch).
alias convertPPMToDPI = convertInchesToMeters;

/// Converts from DPI (Dots Per Inch) to PPM (Points Per Meter).
alias convertDPIToPPM = convertMetersToInches;


/// Load flags (range: bits 16 to 23).
/// Load flags occupy high-order word so that casting to ushort only keeps `LayoutConstraints` part.
alias LoadFlags = int;

/// No loading options. This will keep the original input pixel format, so as to make the least
/// conversions possible.
enum LoadFlags LOAD_NORMAL          = 0;


/// Load the image in greyscale, can be faster than loading as RGB8 then converting to greyscale.
/// This will preserve an alpha channel, if existing.
/// The resulting image will have 1 or 2 channels.
/// Can't be used with `LOAD_RGB` flag.
enum LoadFlags LOAD_GREYSCALE       = 0x10000;

/// Load the image in RGB, can be faster than loading a greyscale image and then converting it RGB.
/// The resulting image will have 3 or 4 channels.
/// Can't be used with `LOAD_GREYSCALE`.
enum LoadFlags LOAD_RGB             = 0x80000; 


/// Load the image and adds an alpha channel (opaque if not existing).
/// This will preserve the color channels.
/// The resulting image will have 2 or 4 channels.
/// Can't be used with `LOAD_NO_ALPHA` flag.
enum LoadFlags LOAD_ALPHA           = 0x20000;

/// Load the image and drops an eventual alpha channel, if it exists.
/// The resulting image will have 1 or 3 channels.
/// Can't be used with `LOAD_ALPHA` flag.
enum LoadFlags LOAD_NO_ALPHA        = 0x40000;


/// Load the image directly in 8-bit, can be faster than loading as 16-bit PNG and then converting to 8-bit.
/// Can't be used with `LOAD_10BIT` or `LOAD_FP32` flag.
enum LoadFlags LOAD_8BIT            = 0x100000;

/// Load the image directly in 16-bit, can be faster than loading as 8-bit PNG and then converting to 16-bit.
/// Can't be used with `LOAD_8BIT` or `LOAD_FP32` flag.
enum LoadFlags LOAD_16BIT           = 0x200000;

/// Load the image directly in 32-bit floating point.
/// Probably the same speed as just calling `convertToFP32` after load though.
/// Can't be used with `LOAD_8BIT` or `LOAD_10BIT` flag.
enum LoadFlags LOAD_FP32           = 0x400000;


/// Only decode metadata, not the pixels themselves.
/// NOT SUPPORTED YET!
enum LoadFlags LOAD_NO_PIXELS       = 0x800000;






// Encode flags

/// Do nothing particular.
/// Supported by: JPEG, PNG, DDS, QOI, QOIX.
enum int ENCODE_NORMAL = 0;

/// Internal use, this is to test a variation of a compiler.
/// Supported by: JPEG, PNG, DDS, QOI, QOIX.
enum int ENCODE_CHALLENGER = 4;




/// Layout constraints flags (bits 0 to 15).
/// All of those introduce "gap pixels" after the scanline, in order to follow the various constraints.
///
/// Example: if you want to process 4x RGBA8 pixels at once, with aligned SSE, use:
///    `LAYOUT_MULTIPLICITY_4 | LAYOUT_SCANLINE_ALIGNED_16`
alias LayoutConstraints = ushort;

enum LayoutConstraints
     LAYOUT_DEFAULT               = 0,  /// Default / do-not-care layout options. This is what will give
                                        /// the fastest loading time when loading images (though most decoders
                                        /// tend to return gapless non-flipped images).

     // Multiplicity: 
     // -------------
     //
     // Allows to access pixels by packing them together, without stepping on the next scanline or segfault.
     // Multiplicity warrants READ access to needed excess pixels at the end of each scanline.
     // If the image is owned      => additionally it warrants WRITE access to those excess pixels.
     //                 not-owned  => can't WRITE to those pixels. 
     // Subimage: taking a sub-rect of an image REMOVES the constraint guarantee, it forces `LAYOUT_MULTIPLICITY_1`.
     //
     LAYOUT_MULTIPLICITY_1        = 0,  /// No particular multiplicity requirements.
     LAYOUT_MULTIPLICITY_2        = 1,  /// Beginning at the start of a scanline, pixels can be READ 2 by 2 without segfault.
     LAYOUT_MULTIPLICITY_4        = 2,  /// Beginning at the start of a scanline, pixels can be READ 4 by 4 without segfault.
     LAYOUT_MULTIPLICITY_8        = 3,  /// Beginning at the start of a scanline, pixels can be READ 8 by 8 without segfault.

     // Trailing pixels: 
     // ----------------
     // Allows to access the very end of a scanline with SIMD, without stepping on the next scanline or segfault.
     // Trailing pixels warrants READ access to needed excess pixels at the end of each scanline.
     // If the image is owned      => additionally it warrants WRITE access to those excess pixels.
     //                 not-owned  => can't WRITE to those pixels. 
     // Subimage: taking a sub-rect of an image KEEPS the trailing pixels guarantee (but removes ability to write to them).
     //
     LAYOUT_TRAILING_0            = 0,  /// Scanlines have no trailing requirements.
     LAYOUT_TRAILING_1            = 4,  /// Scanlines must be followed by at least 1 READABLE gap pixels.
     LAYOUT_TRAILING_3            = 8,  /// Scanlines must be followed by at least 3 READABLE gap pixels.
     LAYOUT_TRAILING_7            = 12, /// Scanlines must be followed by at least 7 READABLE gap pixels.

     
     // Scanline alignment:
     // -------------------
     // Allows to access pixels from start of scanline with aligned SIMD.
     // Both scanling addresses, and also pitchInBytes, must be aligned.
     //
     // Gap bytes that would exist are READABLE.
     // If the image is owned      => additionally it warrants WRITE access to those gap bytes, if any.
     //                 not-owned  => can't WRITE to those bytes. 
     // Subimage: taking a sub-rect of an image REMOVES the scanline alignment guarantee, it forces `LAYOUT_SCANLINE_ALIGNED_1`.
     //
     LAYOUT_SCANLINE_ALIGNED_1    = 0,  /// No particular alignment for scanline.
     LAYOUT_SCANLINE_ALIGNED_2    = 16, /// Scanlines required to be at least aligned on 2 bytes boundaries.
     LAYOUT_SCANLINE_ALIGNED_4    = 32, /// Scanlines required to be at least aligned on 4 bytes boundaries.
     LAYOUT_SCANLINE_ALIGNED_8    = 48, /// Scanlines required to be at least aligned on 8 bytes boundaries.
     LAYOUT_SCANLINE_ALIGNED_16   = 64, /// Scanlines required to be at least aligned on 16 bytes boundaries.
     LAYOUT_SCANLINE_ALIGNED_32   = 80, /// Scanlines required to be at least aligned on 32 bytes boundaries.
     LAYOUT_SCANLINE_ALIGNED_64   = 96, /// Scanlines required to be at least aligned on 64 bytes boundaries.
     LAYOUT_SCANLINE_ALIGNED_128  = 112, /// Scanlines required to be at least aligned on 128 bytes boundaries.


     // Scanline alignment:
     // -------------------
     // Allow to access additional pixels in every direction, without segfault.
     //
     // Border pixels are READABLE.
     // If the image is owned      => additionally iborder pixels are WRITEABLE.
     //                 not-owned  => can't WRITE to those pixels. 
     // Subimage: taking a sub-rect of an image KEEPS the border pixels constraint (but removes ability to write to them).
     //     
     LAYOUT_BORDER_0              = 0,   /// No particular border constraint.
     LAYOUT_BORDER_1              = 128, /// The whole image has a border of at least 1 pixel addressable without segfault.
     LAYOUT_BORDER_2              = 256, /// The whole image has a border of at least 2 pixels addressable without segfault.
     LAYOUT_BORDER_3              = 384, /// The whole image has a border of at least 3 pixels addressable without segfault.

     // Allow to force the image representation to be stored in a certain vertical direction.
     LAYOUT_VERT_FLIPPED          = 512,  /// The whole image MUST be stored upside down. Can't be used with `LAYOUT_VERT_STRAIGHT` flag.
     LAYOUT_VERT_STRAIGHT         = 1024, /// The whole image MUST NOT be stored upside down. Can't be used with `LAYOUT_VERT_FLIPPED` flag.

     // No space between scanlines. 
     // This is logically incompatible with scanline alignment, border, trailing pixels, and multiplicity.
     // Subimage: LAYOUT_GAPLESS is immediately lost.
     // Note: In presence of multiple layers, LAYOUT_GAPLESS also forces those layers to be immediately contiguous, not just the scanlines.
     LAYOUT_GAPLESS               = 2048; /// There must be no single trailing bytes between scanlines.


PixelType convertPixelTypeToGreyscale(PixelType type) pure
{
    PixelType t = PixelType.unknown;
    final switch(type) with (PixelType)
    {
        case unknown: t = unknown; break;
        case l8:      t = l8; break;
        case l16:     t = l16; break;
        case lf32:    t = lf32; break;
        case la8:     t = la8; break;
        case la16:    t = la16; break;
        case laf32:   t = laf32; break;
        case rgb8:    t = l8; break;
        case rgb16:   t = l16; break;
        case rgbf32:  t = lf32; break;
        case rgba8:   t = la8; break;
        case rgba16:  t = la16; break;
        case rgbaf32: t = laf32; break;
    }
    return t;
}

PixelType convertPixelTypeToRGB(PixelType type) pure
{
    PixelType t = PixelType.unknown;
    final switch(type) with (PixelType)
    {
        case unknown: t = unknown; break;
        case l8:      t = rgb8; break;
        case l16:     t = rgb16; break;
        case lf32:    t = rgbf32; break;
        case la8:     t = rgba8; break;
        case la16:    t = rgba16; break;
        case laf32:   t = rgbaf32; break;
        case rgb8:    t = rgb8; break;
        case rgb16:   t = rgb16; break;
        case rgbf32:  t = rgbf32; break;
        case rgba8:   t = rgba8; break;
        case rgba16:  t = rgba16; break;
        case rgbaf32: t = rgbaf32; break;
    }
    return t;
}

PixelType convertPixelTypeToAddAlphaChannel(PixelType type) pure
{
    PixelType t = PixelType.unknown;
    final switch(type) with (PixelType)
    {
        case unknown: t = unknown; break;
        case l8:      t = la8; break;
        case l16:     t = la16; break;
        case lf32:    t = laf32; break;
        case la8:     t = la8; break;
        case la16:    t = la16; break;
        case laf32:   t = laf32; break;
        case rgb8:    t = rgba8; break;
        case rgb16:   t = rgba16; break;
        case rgbf32:  t = rgbaf32; break;
        case rgba8:   t = rgba8; break;
        case rgba16:  t = rgba16; break;
        case rgbaf32: t = rgbaf32; break;
    }
    return t;
}

PixelType convertPixelTypeToDropAlphaChannel(PixelType type) pure
{
    PixelType t = PixelType.unknown;
    final switch(type) with (PixelType)
    {
        case unknown: t = unknown; break;
        case l8:      t = l8; break;
        case l16:     t = l16; break;
        case lf32:    t = lf32; break;
        case la8:     t = l8; break;
        case la16:    t = l16; break;
        case laf32:   t = lf32; break;
        case rgb8:    t = rgb8; break;
        case rgb16:   t = rgb16; break;
        case rgbf32:  t = rgbf32; break;
        case rgba8:   t = rgb8; break;
        case rgba16:  t = rgb16; break;
        case rgbaf32: t = rgbf32; break;
    }
    return t;
}

PixelType convertPixelTypeTo8Bit(PixelType type) pure
{
    PixelType t = PixelType.unknown;       
    final switch(type) with (PixelType)
    {
        case unknown: t = unknown; break;
        case l8:      t = l8; break;
        case l16:     t = l8; break;
        case lf32:    t = l8; break;
        case la8:     t = la8; break;
        case la16:    t = la8; break;
        case laf32:   t = la8; break;
        case rgb8:    t = rgb8; break;
        case rgb16:   t = rgb8; break;
        case rgbf32:  t = rgb8; break;
        case rgba8:   t = rgba8; break;
        case rgba16:  t = rgba8; break;
        case rgbaf32: t = rgba8; break;
    }
    return t;
}

PixelType convertPixelTypeTo16Bit(PixelType type) pure
{
    PixelType t = PixelType.unknown;       
    final switch(type) with (PixelType)
    {
        case unknown: t = unknown; break;
        case l8:      t = l16; break;
        case l16:     t = l16; break;
        case lf32:    t = l16; break;
        case la8:     t = la16; break;
        case la16:    t = la16; break;
        case laf32:   t = la16; break;
        case rgb8:    t = rgb16; break;
        case rgb16:   t = rgb16; break;
        case rgbf32:  t = rgb16; break;
        case rgba8:   t = rgba16; break;
        case rgba16:  t = rgba16; break;
        case rgbaf32: t = rgba16; break;
    }
    return t;
}


PixelType convertPixelTypeToFP32(PixelType type) pure
{
    PixelType t = PixelType.unknown;       
    final switch(type) with (PixelType)
    {
        case unknown: t = unknown; break;
        case l8:      t = lf32; break;
        case l16:     t = lf32; break;
        case lf32:    t = lf32; break;
        case la8:     t = laf32; break;
        case la16:    t = laf32; break;
        case laf32:   t = laf32; break;
        case rgb8:    t = rgbf32; break;
        case rgb16:   t = rgbf32; break;
        case rgbf32:  t = rgbf32; break;
        case rgba8:   t = rgbaf32; break;
        case rgba16:  t = rgbaf32; break;
        case rgbaf32: t = rgbaf32; break;
    }
    return t;
}

