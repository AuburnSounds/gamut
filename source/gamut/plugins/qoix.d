/**
QOIX support.
This is "living standard" format living in Gamut that tries to improve upon QOI.

Copyright: Copyright Guillaume Piolat 2022
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut.plugins.qoix;

nothrow @nogc @safe:

import core.stdc.stdlib: malloc, free, realloc;
import core.stdc.string: memcpy;
import gamut.types;
import gamut.io;
import gamut.image;
import gamut.plugin;
import gamut.internals.errors;
import gamut.internals.types;

version(decodeQOIX)
{
    import gamut.codecs.qoi2avg;
    import gamut.codecs.qoiplane;
    import gamut.codecs.qoi10b;
    import gamut.codecs.lz4;
}
else version(encodeQOIX)
{
    import gamut.codecs.qoi2avg;
    import gamut.codecs.qoi2plane;
    import gamut.codecs.qoi10b;
    import gamut.codecs.lz4;
}

ImageFormatPlugin makeQOIXPlugin()
{
    ImageFormatPlugin p;
    p.format = "QOIX";
    p.extensionList = "qoix";

    p.mimeTypes = "image/qoix";

    version(decodeQOIX)
        p.loadProc = &loadQOIX;
    else
        p.loadProc = null;
    version(encodeQOIX)
        p.saveProc = &saveQOIX;
    else
        p.saveProc = null;
    p.detectProc = &detectQOIX;
    return p;
}

// IMPORTANT: QOIX uses 3 possible codecs internally
//   - QOI2AVG in qoi2avg.d for RGB8 and RGBA8
//   - QOI-Plane for L8/LA8
//   - QOI-10b for 16-bit (lossy)

version(decodeQOIX)
void loadQOIX(ref Image image, IOStream *io, IOHandle handle, int page, int flags, void *data) @trusted
{
    // Read all available bytes from input
    // This is temporary.

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
    if (requestedComp == -1)
        requestedComp = 0; // auto

    ubyte* decoded;
    qoi_desc desc;

    // read all input at once.
    if (len != io.read(buf, 1, len, handle))
    {
        image.error(kStrImageDecodingIOFailure);
        return;
    }

    PixelType decodedToType;
    decoded = cast(ubyte*) qoix_lz4_decode(buf, len, &desc, flags, decodedToType);

    // Note: do not use desc.channels or desc.bits here, it doesn't mean anything anymore.

    if (decoded is null)
    {
        image.error(kStrImageDecodingFailed);
        return;
    }    

    if (!imageIsValidSize(1, desc.width, desc.height))
    {
        image.error(kStrImageTooLarge);
        free(decoded);
        return;
    }

    image._allocArea = decoded;
    image._data = decoded;
    image._width = desc.width;
    image._height = desc.height;

    // PERF: allocate a QOIX decoding buffer with proper layout by passing layoutConstraints to qoix_lz4_decode
    image._layoutConstraints = 0; // No particular constraint followed in QOIX decoder, for now.

    image._type = decodedToType;
    image._pitch = desc.pitchBytes;
    image._pixelAspectRatio = desc.pixelAspectRatio;
    image._resolutionY = desc.resolutionY;
    image._layerCount = 1;
    image._layerOffset = 0;

    // Convert to target type and constraints.
    image.convertTo(applyLoadFlags(image._type, flags), cast(LayoutConstraints) flags);
}


bool detectQOIX(IOStream *io, IOHandle handle) @trusted
{
    static immutable ubyte[4] qoixSignature = [0x71, 0x6f, 0x69, 0x78]; // "qoix"
    return fileIsStartingWithSignature(io, handle, qoixSignature);
}

version(encodeQOIX)
bool saveQOIX(ref const(Image) image, IOStream *io, IOHandle handle, int page, int flags, void *data) @trusted
{
    if (page != 0)
        return false;

    qoi_desc desc;
    desc.width = image._width;
    desc.height = image._height;
    desc.pitchBytes = image._pitch;
    desc.colorspace = QOI_SRGB;
    desc.compression = QOIX_COMPRESSION_NONE; // whatever, this will get overwritten. QOIX is valid with 0 or 1.
    desc.pixelAspectRatio = image._pixelAspectRatio;
    desc.resolutionY = image._resolutionY;

    switch (image._type)
    {
        case PixelType.l8: 
            desc.bitdepth = 8;
            desc.channels = 1; 
            break;
        case PixelType.la8:  
            desc.bitdepth = 8;
            desc.channels = 2; 
            break;
        case PixelType.rgb8: 
            desc.bitdepth = 8;
            desc.channels = 3; 
            break;
        case PixelType.rgba8:
            desc.bitdepth = 8;
            desc.channels = 4; 
            break;
        case PixelType.l16: 
            desc.channels = 1; 
            desc.bitdepth = 10;
            break;
        case PixelType.la16:   
            desc.channels = 2; 
            desc.bitdepth = 10;
            break;
        case PixelType.rgb16:  
            desc.channels = 3; 
            desc.bitdepth = 10;
            break;
        case PixelType.rgba16: 
            desc.channels = 4; 
            desc.bitdepth = 10;
            break;
        default: 
            return false; // not supported
    }
        
    int qoilen;

    // Note: this can, or not, encode to LZ4 the payload.
    ubyte* encoded = cast(ubyte*) qoix_lz4_encode(image._data, &desc, &qoilen);

    if (encoded == null)
        return false;
    scope(exit) free(encoded);

    // Write all output at once.
    if (qoilen != io.write(encoded, 1, qoilen, handle))
        return false;

    return true;
}

/// Encode in QOIX + LZ4. Result should be freed with `free()`.
/// File format of final QOIX:
///   QOIX header (QOIX_HEADER_SIZE bytes with compression = QOIX_COMPRESSION_LZ4)
///   Original data size (4 bytes)
///   LZ4 encoded opcodes
/// Note: desc.compression is ignored. This function chooses the compression.
version(encodeQOIX)
ubyte* qoix_lz4_encode(const(ubyte)* data, const(qoi_desc)* desc, int *out_len) @trusted
{
    // Encode to QOIX
    int qoilen;
    ubyte* qoix;

    // Choose a codec based upon input data.
    // 10-bit is always QOI-10b.
    // 8-bit with 1 or 2 channels is QOI-Plane.
    // 8-bit with 3 or 4 channels is QOI2AVG.
    // All these sub-codecs have the same header format, and can be LZ4-encoded further.
    if (desc.bitdepth == 10)
    {
        qoix = qoi10b_encode(data, desc, &qoilen);
    }
    else
    {
        assert(desc.bitdepth == 8);
        if (desc.channels == 1 || desc.channels == 2)
        {
            qoix = qoiplane_encode(data, desc, &qoilen);
        }
        else
        {
            qoix = qoix_encode(data, desc, &qoilen);
        }
    }

    if (qoix is null)
        return null;

    ubyte[] qoixHeader = qoix[0..QOIX_HEADER_SIZE];
    ubyte[] qoixData = qoix[QOIX_HEADER_SIZE..qoilen];
    int datalen = cast(int) qoixData.length;

    int originalDataSize = cast(int) qoixData.length;


    // Encode QOI in LZ4, except the header. Is it smaller?
    int maxsize = LZ4_compressBound(datalen);
    ubyte* lz4Data = cast(ubyte*) malloc(QOIX_HEADER_SIZE + 4 + maxsize);
    lz4Data[0..QOIX_HEADER_SIZE] = qoix[0..QOIX_HEADER_SIZE];
    int p = QOIX_HEADER_SIZE;
    qoi_write_32(lz4Data, &p, datalen);
    int lz4Size = LZ4_compress(cast(const(char)*)&qoixData[0], 
                               cast(char*)&lz4Data[QOIX_HEADER_SIZE + 4], 
                               datalen);
    if (lz4Size < 0)
    {
        free(qoix);
        return null; // compression attempt failed, this is an error
    }

    // Only use LZ4 compression in the end if it was actually smaller.
    bool useCompressed = lz4Size + 4 < originalDataSize;
    if (useCompressed)
    {
        free(qoix); // free original uncompressed QOIX
        *out_len = QOIX_HEADER_SIZE + 4 + lz4Size;
        lz4Data = cast(ubyte*) realloc(lz4Data, *out_len); // realloc this to fit memory to actually used
        lz4Data[QOIX_HEADER_OFFSET_COMPRESSION] = QOIX_COMPRESSION_LZ4;
        return lz4Data;
    }
    else
    {
        free(lz4Data);
        *out_len = qoilen;
        assert(qoix[QOIX_HEADER_OFFSET_COMPRESSION] == QOIX_COMPRESSION_NONE);

        // tighten the QOIX allocation in order to save bytes
        qoix = cast(ubyte*) realloc(qoix, qoilen);

        return qoix; // return original QOIX
    }
}

/// Decodes a QOIX + LZ4
/// File format:
///   QOIX header (15 bytes)
///   Original data size (4 bytes)
///   LZ4 encoded opcodes
/// Warning: qoi_desc.channels is the encoded channel count.
/// requestedType may or may not be followed as a wish.
/// The actual type, after flags applied, is in decodedType.
version(decodeQOIX)
ubyte* qoix_lz4_decode(const(ubyte)* data, 
                       int size, 
                       qoi_desc *desc, 
                       int flags,
                       out PixelType decodedType) @trusted
{
    if (size < QOIX_HEADER_SIZE)
        return null;

    if (!validLoadFlags(flags))
        return null;

    int compression    = data[QOIX_HEADER_OFFSET_COMPRESSION];
    int streamChannels = data[QOIX_HEADER_OFFSET_CHANNELS];
    int streamBitdepth = data[QOIX_HEADER_OFFSET_BITDEPTH];

    // What type should it be once decompressed?
    PixelType streamType;
    if (!identifyTypeFromStream(streamChannels, streamBitdepth, streamType))
    {
        // Corrupted stream, unknown type.
        return null;
    }

    int uncompressedQOIXSize;
    const(ubyte)* uncompressedQOIX = null;
    ubyte* decQOIX = null;

    if (compression == QOIX_COMPRESSION_LZ4)
    {
        if (size < QOIX_HEADER_SIZE + 4)
            return null;

        // Read original size of data.
        int p = QOIX_HEADER_SIZE;
        int orig = qoi_read_32(data, &p);

        if (orig < 0)
            return null; // too large, corrupted.

        // Allocate decoding buffer for uncompressed QOIX.
        decQOIX = cast(ubyte*) malloc(QOIX_HEADER_SIZE + orig);

        decQOIX[0..QOIX_HEADER_SIZE] = data[0..QOIX_HEADER_SIZE];
        decQOIX[QOIX_HEADER_OFFSET_COMPRESSION] = QOIX_COMPRESSION_NONE; // remove "compressed" label in header

        const(ubyte)[] lz4Data = data[QOIX_HEADER_SIZE + 4 ..size];

        int qoilen = LZ4_decompress_fast(cast(char*)&lz4Data[0], cast(char*)&decQOIX[QOIX_HEADER_SIZE], orig);

        if (qoilen < 0)
        {
            free(decQOIX);
            return null;
        }

        uncompressedQOIXSize = QOIX_HEADER_SIZE + orig;
        uncompressedQOIX = decQOIX;
    }
    else if (compression == QOIX_COMPRESSION_NONE)
    {
        uncompressedQOIXSize = size;
        uncompressedQOIX = data;
    }
    else
        return null;

 
    ubyte* image;
    if (streamBitdepth == 10)
    {
        // Using qoi10b.d codec
        decodedType = applyLoadFlags_QOI10b(streamType, flags);
        decodedType = streamType;
        int channels = pixelTypeNumChannels(decodedType);

        // This codec can convert 1/2/3/4 to 1/2/3/4 channels on decode, per scanline.
        image = qoi10b_decode(uncompressedQOIX, uncompressedQOIXSize, desc, channels);
    }
    else if (streamBitdepth == 8)
    {
        if (streamChannels == 1 || streamChannels == 2)
        {
            // Using qoiplane.d codec
            decodedType = applyLoadFlags_QOIPlane(streamType, flags);
            decodedType = streamType;
            int channels = pixelTypeNumChannels(decodedType);
            image = qoiplane_decode(uncompressedQOIX, uncompressedQOIXSize, desc, channels);
        }
        else if (streamChannels == 3 || streamChannels == 4)
        {
            // Using qoi2avg.d codec
            decodedType = applyLoadFlags_QOI2AVG(streamType, flags);
            decodedType = streamType;
            int channels = pixelTypeNumChannels(decodedType);
            image = qoix_decode(uncompressedQOIX, uncompressedQOIXSize, desc, channels);
        }
    }
    else
    {
        free(decQOIX);
        return null;
    }

    scope(exit) free(decQOIX);

    return image;
}

// Construct output type from channel count and bitness.
bool identifyTypeFromStream(int channels, int bitdepth, out PixelType type)
{
    if (bitdepth == 8)
    {
        if (channels == 1)
            type = PixelType.l8;
        else if (channels == 2)
            type = PixelType.la8;
        else if (channels == 3)
            type = PixelType.rgb8;
        else if (channels == 4)
            type = PixelType.rgba8;
        else
            return false;
    }
    else if (bitdepth == 10)
    {
        if (channels == 1)
            type = PixelType.l16;
        else if (channels == 2)
            type = PixelType.la16;
        else if (channels == 3)
            type = PixelType.rgb16;
        else if (channels == 4)
            type = PixelType.rgba16;
        else
            return false;
    }
    else
        return false;
    return true;
}

// Given those load flags, what is the best effort the decoder can do?
PixelType applyLoadFlags_QOI2AVG(PixelType type, LoadFlags flags)
{
    if (pixelTypeIs8Bit(type))
    {
        // QOI2AVG can only convert rgb8 <=> rgba8 at decode-time
        if (flags & LOAD_ALPHA)
            type = convertPixelTypeToAddAlphaChannel(type);

        if (flags & LOAD_NO_ALPHA)
            type = convertPixelTypeToDropAlphaChannel(type);
    }
    return type;
}

// Given those load flags, what is the best effort the decoder can do?
PixelType applyLoadFlags_QOIPlane(PixelType type, LoadFlags flags)
{
    if (pixelTypeIs8Bit(type))
    {
        // QOIPlane can convert ubyte8 <=> la8
        if (flags & LOAD_ALPHA)
            type = convertPixelTypeToAddAlphaChannel(type);

        if (flags & LOAD_NO_ALPHA)
            type = convertPixelTypeToDropAlphaChannel(type);
    }
    return type;
}

// Given those load flags, what is the best effort the decoder can do?
PixelType applyLoadFlags_QOI10b(PixelType type, LoadFlags flags)
{
    // QOI-10b can convert to 1/2/3/4 channels at decode-time
    if (pixelTypeIs16Bit(type))
    {
        if (flags & LOAD_GREYSCALE)
            type = convertPixelTypeToGreyscale(type);

        if (flags & LOAD_RGB)
            type = convertPixelTypeToRGB(type);

        if (flags & LOAD_ALPHA)
            type = convertPixelTypeToAddAlphaChannel(type);

        if (flags & LOAD_NO_ALPHA)
            type = convertPixelTypeToDropAlphaChannel(type);
    }
    return type;
}