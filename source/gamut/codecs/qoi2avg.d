module gamut.codecs.qoi2avg;

nothrow @nogc:

import core.stdc.stdlib: realloc, malloc, free;
import core.stdc.string: memset, memcpy;

import inteli.emmintrin;

/// Note: this is a translation of "QOI2" mods by @wbd73
/// revealed in https://github.com/nigeltao/qoi2-bikeshed/issues/34
/// Called "QOIX" in Gamut, since it has a few extensions again, such as LZ4.

/* 

QOI2 - Lossless image format inspired by QOI “Quite OK Image” format

Incompatible adaptation of QOI format - https://phoboslab.org

-- LICENSE: The MIT License(MIT)
Copyright(c) 2021 Dominic Szablewski (original QOI format)
Copyright(c) 2021 wbd73 @ GitHub (compression improvements)
Copyright(c) 2022 Guillaume Piolat (D translation, add pitch support)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files(the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and / or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions :
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.



-- Documentation

This library provides the following functions;
- qoi_decode  -- decode the raw bytes of a QOI image from memory
- qoi_encode  -- encode an rgba buffer into a QOI image in memory

See the function declaration below for the signature and more information.


-- Data Format

A QOI2AVG file has a 25 byte header, compatible with Gamut QOIX.
Followed by any number of data "chunks" and an 8-byte end marker.

struct qoix_header_t {
    char     magic[4];         // magic bytes "qoix"
    uint32_t width;            // image width in pixels (BE)
    uint32_t height;           // image height in pixels (BE)
    uint8_t  version_;         // Major version of QOIX format.
    uint8_t  channels;         // 3 = RGB, 4 = RGBA (1 and 2 indicate QOI-plane codec, see qoiplane.d)
    uint8_t  bitdepth;         // 8 = this qoi2avg codec is always 8-bit (10 indicates QOI-10 codec, see qoi10b.d)
    uint8_t  colorspace;       // 0 = sRGB with linear alpha, 1 = all channels linear
    uint8_t  compression;      // 0 = none, 1 = LZ4
    float    pixelAspectRatio; // -1 = unknown, else Pixel Aspect Ratio
    float    resolutionX;      // -1 = unknown, else physical resolution in DPI
};
*/

enum QOIX_HEADER_OFFSET_CHANNELS = 13;
enum QOIX_HEADER_OFFSET_BITDEPTH = 14;
enum QOIX_HEADER_OFFSET_COMPRESSION = 16;


/*

The decoder and encoder start with {r: 0, g: 0, b: 0, a: 255} as the previous
pixel value. Pixels are either encoded as
 - a run of the previous pixel
 - an index into an array of previously seen pixels
 - a difference to the previous pixel value in r,g,b
 - full r,g,b or a or gray values

The color channels are assumed to not be premultiplied with the alpha channel 
("un-premultiplied alpha").

Each chunk starts with a tag, followed by a number of data bits. The bit length
of chunks is divisible by 8 - i.e. all chunks are byte aligned. All values
encoded in these data bits have the most significant bit on the left.

The byte stream's end is marked with 4 0xff bytes.

A running FIFO array[64] (zero-initialized) of pixel values is maintained by the
encoder and decoder. Every pixel en-/decoded by the QOI_OP_LUMA (and variants),
QOI_OP_GRAY and QOI_OP_RGB chunks is written to this array. The write position
starts at 0 and is incremented with each pixel written. The position wraps back
to 0 when it reaches 64. I.e:
    index[index_pos % 64] = current_pixel;
    index_pos = index_pos + 1;

An encoder can search this array for the current pixel value and, if a match is
found, emit a QOI_OP_INDEX with the position within the array.


The possible chunks are:


.- QOI_OP_INDEX ----------.
|         Byte[0]         |
|  7  6  5  4  3  2  1  0 |
|-------+-----------------|
|  1  0 |     index       |
`-------------------------`
2-bit tag b10
6-bit index into the color index array: 0..63


.- QOI_OP_LUMA -----(232)-. 
|         Byte[0]         |
|  7  6  5  4  3  2  1  0 |
|----+--------+-----+-----|
|  0 | g diff | drg | dbg |
`-------------------------`
1-bit tag b0
3-bit green channel difference from the reference -4..3
2-bit   red channel difference minus green channel difference -1..2 or -2..1
2-bit  blue channel difference minus green channel difference -1..2 or -2..1

For the first line of pixels the reference is the previous pixel.
For the next lines of pixels the reference is the rounded down average of the
previous pixel and the one above the current pixel.
The green channel is used to indicate the general direction of change and is 
encoded in 3 bits. The red and green channels (dr and db) base their diffs off
of the green channel difference and are encoded in 2 bits. I.e.:
    dr_dg = (ref.r - cur_px.r) - (ref.g - cur_px.g)
    db_dg = (ref.b - cur_px.b) - (ref.g - cur_px.g)

The difference to the current channel values are using a wraparound operation, 
so "1 - 2" will result in 255, while "255 + 1" will result in 0.

Values are stored as unsigned integers with a bias of 4 for the green channel 
and a bias of 1 or 2 for the red and blue channel depending on the direction
(sign bit) of the green channel.


.- QOI_OP_LUMA2 ------------------------------(454)-. 
|         Byte[0]         |         Byte[1]         |
|  7  6  5  4  3  2  1  0 |  7  6  5  4  3  2  1  0 |
|----------+--------------+-------------+-----------|
|  1  1  0 |  green diff  |   dr - dg   |  db - dg  |
`---------------------------------------------------`
3-bit tag b110
5-bit green channel difference from the reference -16..15
4-bit   red channel difference minus green channel difference -8..7
4-bit  blue channel difference minus green channel difference -8..7

The green channel is used to indicate the general direction of change and is 
encoded in 5 bits. The red and green channels (dr and db) base their diffs off
of the green channel difference and are encoded in 4 bits.

Values are stored as unsigned integers with a bias of 16 for the green channel 
and a bias of 8 for the red and blue channel.


.- QOI_OP_LUMA3 ------------------------------------.-------------------(676)-. 
|         Byte[0]         |         Byte[1]         |         Byte[2]         |
|  7  6  5  4  3  2  1  0 |  7  6  5  4  3  2  1  0 |  7  6  5  4  3  2  1  0 |
|----------------+----------------------+-------------------+-----------------|
|  1  1  1  0  0 |     green diff       |      dr - dg      |     db - dg     |
`-----------------------------------------------------------------------------`
4-bit tag b1110
7-bit green channel difference from the reference -64..63
6-bit   red channel difference minus green channel difference -32..31
6-bit  blue channel difference minus green channel difference -32..31

The green channel is used to indicate the general direction of change and is 
encoded in 7 bits. The red and green channels (dr and db) base their diffs off
of the green channel difference and are encoded in 6 bits.

Values are stored as unsigned integers with a bias of 64 for the green channel 
and a bias of 32 for the red and blue channel.


.- QOI_OP_RUN ------------.
|         Byte[0]         |
|  7  6  5  4  3  2  1  0 |
|----------------+--------|
|  1  1  1  1  0 |  run   |
`-------------------------`
5-bit tag b11110
3-bit run-length repeating the previous pixel: 1..8

The run-length is stored with a bias of 1.


.- QOI_OP_RUN2 ---------------------.
|         Byte[0]         | Byte[1] |
|  7  6  5  4  3  2  1  0 | 7 .. 0  |
|-------------------+-----+---------|
|  1  1  1  1  1  0 |      run      |
`-----------------------------------`
6-bit tag b111110
10-bit run-length repeating the previous pixel: 1..1024

The run-length is stored with a bias of 1.


.- QOI_OP_GRAY ---------------------.
|         Byte[0]         | Byte[1] |
|  7  6  5  4  3  2  1  0 | 7 .. 0  |
|-------------------------+---------|
|  1  1  1  1  1  1  0  0 |  gray   |
`-----------------------------------`
8-bit tag b11111100
8-bit gray channel value


.- QOI_OP_RGB ------------------------------------------.
|         Byte[0]         | Byte[1] | Byte[2] | Byte[3] |
|  7  6  5  4  3  2  1  0 | 7 .. 0  | 7 .. 0  | 7 .. 0  |
|-------------------------+---------+---------+---------|
|  1  1  1  1  1  1  0  1 |   red   |  green  |  blue   |
`-------------------------------------------------------`
8-bit tag b11111101
8-bit   red channel value
8-bit green channel value
8-bit  blue channel value


.- QOI_OP_A ------------------------.
|         Byte[0]         | Byte[1] |
|  7  6  5  4  3  2  1  0 | 7 .. 0  |
|-------------------------+---------|
|  1  1  1  1  1  1  1  0 |  alpha  |
`-----------------------------------`
8-bit tag b11111110
8-bit alpha channel value


.- QOI_OP_END ------------.
|         Byte[0]         |
|  7  6  5  4  3  2  1  0 |
|-------------------------|
|  1  1  1  1  1  1  1  1 |
`-------------------------`
8-bit tag b11111111


The byte stream is padded at the end with four 0xff bytes. Since the longest 
legal chunk is 4 bytes (QOI_OP_RGB), with this padding it is possible to check 
for an overrun only once per decode loop iteration. These 0xff bytes also mark 
the end of the data stream, as an encoder should never produce four consecutive
0xff bytes within the stream.

*/

/* A pointer to a qoi_desc struct has to be supplied to all of qoi's functions. 
It describes either the input format (for qoi_write and qoi_encode), or is 
filled with the description read from the file header (for qoi_read and
qoi_decode).

The colorspace in this qoi_desc is an enum where 
    0 = sRGB, i.e. gamma scaled RGB channels and a linear alpha channel
    1 = all channels are linear
You may use the constants QOI_SRGB or QOI_LINEAR. The colorspace is purely 
informative. It will be saved to the file header, but does not affect
en-/decoding in any way. */

enum QOI_SRGB = 0;
enum QOI_LINEAR = 1;

struct qoi_desc
{
    uint width;
    uint height;
    int pitchBytes; // number of bytes between start of lines.
    ubyte channels;
    ubyte bitdepth;
    ubyte colorspace;
    ubyte compression;
    float pixelAspectRatio; // PAR, in Gamut format
    float resolutionY;      // Vertical DPI, in Gamut format
}

alias QOI_MALLOC = malloc;
alias QOI_FREE = free;


enum int QOI_OP_LUMA   = 0x00; /* 0xxxxxxx */
enum int QOI_OP_INDEX  = 0x80; /* 10xxxxxx */
enum int QOI_OP_LUMA2  = 0xc0; /* 110xxxxx */
enum int QOI_OP_LUMA3  = 0xe0; /* 11100xxx */
enum int QOI_OP_ADIFF  = 0xe8; /* 11101xxx */
enum int QOI_OP_RUN    = 0xf0; /* 11110xxx */
enum int QOI_OP_RUN2   = 0xf8; /* 111110xx */
enum int QOI_OP_GRAY   = 0xfc; /* 11111100 */
enum int QOI_OP_RGB    = 0xfd; /* 11111101 */
enum int QOI_OP_RGBA   = 0xfe; /* 11111110 */
enum int QOI_OP_END    = 0xff; /* 11111111 */

enum uint QOIX_MAGIC = 0x716F6978; // "qoix"
enum QOIX_HEADER_SIZE = 15 + 1 /* version */ + 4 /* PAR */ + 4 /* DPI */ + 1 /* compression */;
enum ubyte QOIX_COMPRESSION_NONE = 0;
enum ubyte QOIX_COMPRESSION_LZ4  = 1;

/* To not have to linearly search through the color index array, we use a hash 
of the color value to quickly lookup the index position in a hash table. */
uint QOI_COLOR_HASH(qoi_rgba_t C)
{
    return (((C.v * 2654435769) >> 22) & 1023);
}

/* 2GB is the max file size that this implementation can safely handle. We guard
against anything larger than that, assuming the worst case with 5 bytes per 
pixel, rounded down to a nice clean value. 400 million pixels ought to be 
enough for anybody. */
enum uint QOIX_PIXELS_MAX = 400000000;

struct RGBA
{
    ubyte r, g, b, a;
}
static assert(RGBA.sizeof == 4);

struct qoi_rgba_t 
{   
    union
    {
        RGBA rgba;
        uint v;
    }
}

static immutable ubyte[4] qoi_padding = [255,255,255,255];

void qoi_write_32(ubyte* bytes, int *p, uint v) 
{
    bytes[(*p)++] = (0xff000000 & v) >> 24;
    bytes[(*p)++] = (0x00ff0000 & v) >> 16;
    bytes[(*p)++] = (0x0000ff00 & v) >> 8;
    bytes[(*p)++] = (0x000000ff & v);
}

uint qoi_read_32(const(ubyte)* bytes, int *p) 
{
    uint a = bytes[(*p)++];
    uint b = bytes[(*p)++];
    uint c = bytes[(*p)++];
    uint d = bytes[(*p)++];
    return a << 24 | b << 16 | c << 8 | d;
}

void qoi_write_32f(ubyte* bytes, int *p, float f) 
{
    qoi_write_32(bytes, p, *cast(uint*)&f);
}

float qoi_read_32f(const(ubyte)* bytes, int *p) 
{
    uint r = qoi_read_32(bytes, p);
    return *cast(float*)&r;
}

/* Encode raw RGB or RGBA pixels into a QOI2AVG image in memory.

The function either returns null on failure (invalid parameters or malloc 
failed) or a pointer to the encoded data on success. On success the out_len 
is set to the size in bytes of the encoded data.

The returned qoi data should be free()d after use. */
version(encodeQOIX)
ubyte* qoix_encode(const(ubyte)* data, const(qoi_desc)* desc, int *out_len) 
{
    int i, stride, p, run;
    int px_len, px_end, px_pos, channels;
    ubyte* bytes;
    ubyte[1024] index_lookup;
    uint index_pos = 0;
    qoi_rgba_t[64] index;
    qoi_rgba_t px, px_ref;

    if (
        data == null || out_len == null || desc == null ||
        desc.width == 0 || desc.height == 0 ||
        desc.channels < 3 || desc.channels > 4 ||
        desc.colorspace > 1 ||
        desc.bitdepth != 8 ||
        desc.compression != QOIX_COMPRESSION_NONE ||
        desc.height >= QOIX_PIXELS_MAX / desc.width
    ) {
        return null;
    }

    int pixel_data_size = desc.width * desc.height * channels;

    // Before encoding a scanline, it is converted to RGBA8.
    // This is double buffered, to help with prediction.
    int converted_scanline_size = desc.width * 4;  

    // Allocated 3 rgba8 scanlines for the need of encoding.
    int extraAllocSize = converted_scanline_size*2;

    // Overallocate to make room for everything.
    int max_size = desc.width * desc.height * (desc.channels + 1) + QOIX_HEADER_SIZE + cast(int)(qoi_padding.sizeof);

    p = 0;
    bytes = cast(ubyte*) QOI_MALLOC(max_size + extraAllocSize);
    if (!bytes) 
    {
        return null;
    }

    // double-buffered scanline, this is intended to speed up decoding
    qoi_rgba_t* inputScanline     = cast(qoi_rgba_t*)(bytes + max_size);
    qoi_rgba_t* lastInputScanline = cast(qoi_rgba_t*)(bytes + max_size + converted_scanline_size);

    qoi_write_32(bytes, &p, QOIX_MAGIC);
    qoi_write_32(bytes, &p, desc.width);
    qoi_write_32(bytes, &p, desc.height);
    bytes[p++] = 1; // Put a version number :)
    bytes[p++] = desc.channels; // 3, or 4
    bytes[p++] = desc.bitdepth; // 8, or 10
    bytes[p++] = desc.colorspace;
    bytes[p++] = QOIX_COMPRESSION_NONE;
    qoi_write_32f(bytes, &p, desc.pixelAspectRatio);
    qoi_write_32f(bytes, &p, desc.resolutionY);

    //pixels = cast(const(ubyte)*) data;

    memset(index.ptr, 0, 64 * qoi_rgba_t.sizeof);
    index_lookup[] = 0;

    run = 0;
    px.rgba.r = 0;
    px.rgba.g = 0;
    px.rgba.b = 0;
    px.rgba.a = 255;
    
    channels = desc.channels;
    stride = desc.width * channels;
    px_len = desc.width * desc.height * channels;
    px_end = px_len - channels;

    assert (channels != 1 && channels != 2);



    for (int posy = 0; posy < desc.height; ++posy)
    {
        const(ubyte)* line = data + desc.pitchBytes * posy;

        // Convert one input scanline at once to rgba8
        if (desc.channels == 4)
        {
            // PERF: replace by pointer swap
            memcpy(inputScanline, line, desc.pitchBytes);
        }
        else
        {
            assert(desc.channels == 3);
            for (int posx = 0; posx < desc.width; ++posx)
            {
                inputScanline[posx].rgba = RGBA(line[posx * 3 + 0], line[posx * 3 + 1], line[posx * 3 + 2], 255);
            }
        }

        for (int posx = 0; posx < desc.width; ++posx)
        {
            px_ref.v = px.v;
            px = inputScanline[posx];

            if (px.v == px_ref.v) {
                run++;
                if (run == 1024 || px_pos == px_end) {
                    run--;
                    bytes[p++] = QOI_OP_RUN2 | ((run >> 8) & 3);
                    bytes[p++] = run & 0xff;
                    run = 0;
                }
            }
            else {
                int hash = QOI_COLOR_HASH(px);

                if (run > 0) {
                    run--;
                    if (run < 8) {
                        bytes[p++] = cast(ubyte)(QOI_OP_RUN | run);
                    }
                    else {
                        bytes[p++] = QOI_OP_RUN2 | ((run >> 8) & 3);
                        bytes[p++] = run & 0xff;
                    }
                    run = 0;
                }

                if (index[index_lookup[hash]].v == px.v) {
                    bytes[p++] = QOI_OP_INDEX | index_lookup[hash];
                }
                else {
                    index_lookup[hash] = cast(ubyte) index_pos;
                    index[index_pos] = px;
                    index_pos = (index_pos + 1) & 63;

                    byte va = cast(byte)(px.rgba.a - px_ref.rgba.a);

                    if (va) {
                        if (va >= -4 && va <= 3){
                            bytes[p++] = cast(ubyte)(QOI_OP_ADIFF | (va + 4));
                        } else { 
                            bytes[p++] = QOI_OP_RGBA; // make a grey + alpha opcode?
                            bytes[p++] = px.rgba.r;
                            bytes[p++] = px.rgba.g;
                            bytes[p++] = px.rgba.b;
                            bytes[p++] = px.rgba.a;
                            goto pixel_encoded;
                        }
                    }

                    // Note: computing this predictor for the whole scanline in advance, even with 2x pixels at once, was slower.
                    // because in normal times, you don't compute this predictor all the time.
                    if (posy > 0)
                    {
                        if (posx == 0)
                        {
                            // first pixel in the row, take above pixel
                            RGBA pred = lastInputScanline[posx].rgba;
                            px_ref.rgba.r = pred.r;
                            px_ref.rgba.g = pred.g;
                            px_ref.rgba.b = pred.b;
                        }
                        else 
                        {
                            RGBA pred = locoIntraPredictionSIMD(px_ref.rgba, lastInputScanline[posx].rgba, lastInputScanline[posx-1].rgba);
                            px_ref.rgba.r = pred.r;
                            px_ref.rgba.g = pred.g;
                            px_ref.rgba.b = pred.b;
                        }
                    }

                    byte vg   = cast(byte)(px.rgba.g - px_ref.rgba.g);
                    byte vg_r = cast(byte)(px.rgba.r - px_ref.rgba.r - vg);
                    byte vg_b = cast(byte)(px.rgba.b - px_ref.rgba.b - vg);

                    if (
                        vg   >= -4 && vg   <  0 && 
                        vg_r >= -1 && vg_r <= 2 &&
                        vg_b >= -1 && vg_b <= 2
                    ) {
                        bytes[p++] = cast(ubyte)( QOI_OP_LUMA | (vg + 4) << 4 | (vg_r + 1) << 2 | (vg_b + 1) );
                    }
                    else if (
                        vg   >=  0 && vg   <= 3 && 
                        vg_r >= -2 && vg_r <= 1 &&
                        vg_b >= -2 && vg_b <= 1
                    ) {
                        bytes[p++] = cast(ubyte)( QOI_OP_LUMA | (vg + 4) << 4 | (vg_r + 2) << 2 | (vg_b + 2) );
                    }
                    else if (
                        px.rgba.g == px.rgba.r &&
                        px.rgba.g == px.rgba.b
                    ) {
                        bytes[p++] = QOI_OP_GRAY;
                        bytes[p++] = px.rgba.g;
                    }
                    else if (
                        vg_r >=  -8 && vg_r <=  7 && 
                        vg   >= -16 && vg   <= 15 && 
                        vg_b >=  -8 && vg_b <=  7
                    ) {
                        bytes[p++] = cast(ubyte)( QOI_OP_LUMA2    | (vg   + 16) );
                        bytes[p++] = cast(ubyte)( (vg_r + 8) << 4 | (vg_b +  8) );
                    }
                    else if (
                        vg_r >= -32 && vg_r <= 31 && 
                        vg   >= -64 && vg   <= 63 && 
                        vg_b >= -32 && vg_b <= 31
                    ) {
                        int dv = ((vg + 64) << 12) | ((vg_r + 32) << 6) | (vg_b + 32);
                        bytes[p++] = QOI_OP_LUMA3 | ((dv >> 16) & 31);
                        bytes[p++] = (dv >> 8) & 255;
                        bytes[p++] = dv & 255;
                    } else {
                        bytes[p++] = QOI_OP_RGB;
                        bytes[p++] = px.rgba.r;
                        bytes[p++] = px.rgba.g;
                        bytes[p++] = px.rgba.b;
                    }
                }
            }

            pixel_encoded:

            px_pos += channels;
        }

        // swap input scanline buffers
        {
            qoi_rgba_t* temp = inputScanline;
            inputScanline = lastInputScanline;
            lastInputScanline = temp;
        }
    }

    for (i = 0; i < cast(int)(qoi_padding.sizeof); i++) 
    {
        bytes[p++] = qoi_padding[i];
    }

    *out_len = p;
    return bytes;
}

/* Decode a QOI2AVG image from memory.

The function either returns null on failure (invalid parameters or malloc 
failed) or a pointer to the decoded pixels. On success, the qoi_desc struct 
is filled with the description from the file header.

The returned pixel data should be free()d after use. */
version(decodeQOIX)
ubyte* qoix_decode(const(void)* data, int size, qoi_desc *desc, int channels) {
    const(ubyte)* bytes;
    uint header_magic;
    qoi_rgba_t[64] index;
    qoi_rgba_t px, px_ref;
    int chunks_len;
    int p = 0, run = 0;
    int index_pos = 0;

    if (
        data == null || desc == null ||
        (channels != 0 && channels !=  3 && channels !=  4) ||
        size < QOIX_HEADER_SIZE + cast(int)(qoi_padding.sizeof)
    ) {
        return null;
    }

    bytes = cast(const(ubyte)*)data;

    header_magic = qoi_read_32(bytes, &p);
    desc.width = qoi_read_32(bytes, &p);
    desc.height = qoi_read_32(bytes, &p);
    int qoix_version = bytes[p++];
    desc.channels = bytes[p++];
    desc.bitdepth = bytes[p++];
    desc.colorspace = bytes[p++];
    desc.compression = bytes[p++];
    desc.pixelAspectRatio = qoi_read_32f(bytes, &p);
    desc.resolutionY = qoi_read_32f(bytes, &p);

    if (
        desc.width == 0 || desc.height == 0 || 
        desc.channels < 3 || desc.channels > 4 ||
        desc.colorspace > 1 ||
        desc.bitdepth != 8 ||
        qoix_version > 1 ||
        desc.compression != QOIX_COMPRESSION_NONE ||
        header_magic != QOIX_MAGIC ||
        desc.height >= QOIX_PIXELS_MAX / desc.width
    ) {
        return null;
    }

    if (channels == 0) {
        channels = desc.channels;
    }

    int samplesPerRow = desc.width * channels;

    desc.pitchBytes = samplesPerRow;

    int pixel_data_size = desc.width * desc.height * channels;
    int decoded_scanline_size = desc.width * 4;  

    int num_samples = desc.width * desc.height * channels;
    ubyte* pixels = cast(ubyte *) QOI_MALLOC(pixel_data_size + 2 * decoded_scanline_size);
    if (!pixels) {
        return null;
    }

    // double-buffered scanline, this is intended to speed up decoding
    qoi_rgba_t* decodedScanline = cast(qoi_rgba_t*)(&pixels[pixel_data_size]);
    qoi_rgba_t* lastDecodedScanline = cast(qoi_rgba_t*)(&pixels[pixel_data_size + decoded_scanline_size]);

    assert(channels != 1 && channels != 2);

    memset(index.ptr, 0, 64 * qoi_rgba_t.sizeof);
    px.rgba.r = 0;
    px.rgba.g = 0;
    px.rgba.b = 0;
    px.rgba.a = 255;

    chunks_len = size - cast(int)(qoi_padding.sizeof);

    int px_pos = 0;

    for (int posy = 0; posy < desc.height; ++posy)
    {
        for (int posx = 0; posx < desc.width; ++posx)
        {
            if (run > 0) 
            {
                run--;
            }
            else if (p < chunks_len) 
            {
                px_ref.v = px.v;

                if (posy > 0)
                {
                    if (posx == 0)
                    {
                        // first pixel in the row, take above pixel
                        px_ref.rgba.r = lastDecodedScanline[posx].rgba.r;
                        px_ref.rgba.g = lastDecodedScanline[posx].rgba.g;
                        px_ref.rgba.b = lastDecodedScanline[posx].rgba.b;
                    }
                    else 
                    {
                        // Called I-LOCO intra prediction
                        RGBA pred = locoIntraPredictionSIMD(px.rgba, lastDecodedScanline[posx].rgba, lastDecodedScanline[posx-1].rgba);
                        px_ref.rgba.r = pred.r;
                        px_ref.rgba.g = pred.g;
                        px_ref.rgba.b = pred.b;
                    }
                }

                decode_op:

                int b1 = bytes[p++];
                if (b1 < 0x80) {        /* QOI_OP_LUMA */
                    int vg = ((b1 >> 4) & 7) - 4;
                    px.rgba.g = cast(ubyte)(px_ref.rgba.g + vg);
                    if (vg < 0) {
                        px.rgba.r = cast(ubyte)( px_ref.rgba.r + vg - 1 + ((b1 >> 2) & 3) );
                        px.rgba.b = cast(ubyte)( px_ref.rgba.b + vg - 1 +  (b1 &  3) );
                    }
                    else {
                        px.rgba.r = cast(ubyte)( px_ref.rgba.r + vg - 2 + ((b1 >> 2) & 3) );
                        px.rgba.b = cast(ubyte)( px_ref.rgba.b + vg - 2 +  (b1 &  3) );
                    }
                    index[index_pos++ & 63] = px;
                }
                else if (b1 < 0xc0) {       /* QOI_OP_INDEX */
                    px = index[b1 & 63];
                }
                else if (b1 < 0xe0) {       /* QOI_OP_LUMA2 */
                    int b2 = bytes[p++];
                    int vg = (b1 & 0x1f) - 16;
                    px.rgba.r = cast(ubyte)( px_ref.rgba.r + vg - 8 + ((b2 >> 4) & 0x0f) );
                    px.rgba.g = cast(ubyte)( px_ref.rgba.g + vg );
                    px.rgba.b = cast(ubyte)( px_ref.rgba.b + vg - 8 +  (b2       & 0x0f) );
                    index[index_pos++ & 63] = px;
                }
                else if (b1 < 0xe8) {       /* QOI_OP_LUMA3 */
                    int dv = (b1 << 8) | bytes[p++];
                    dv = (dv << 8) | bytes[p++];
                    int vg = ((dv >> 12) & 0x7f) - 64;
                    px.rgba.r = cast(ubyte)( px_ref.rgba.r + vg + ((dv >> 6) & 0x3f) - 32 );
                    px.rgba.g = cast(ubyte)( px_ref.rgba.g + vg );
                    px.rgba.b = cast(ubyte)( px_ref.rgba.b + vg + (dv & 0x3f) - 32 );
                    index[index_pos++ & 63] = px;
                }
                else if (b1 < 0xf0) {       /* QOI_OP_ADIFF */
                    px.rgba.a += (b1 & 7) - 4;
                    goto decode_op;
                }
                else if (b1 < 0xf8) {       /* QOI_OP_RUN */
                    run = b1 & 7;
                }
                else if (b1 < 0xfc) {       /* QOI_OP_RUN2 */
                    run = ((b1 & 3) << 8) | bytes[p++];
                }
                else if (b1 == QOI_OP_GRAY) {
                    ubyte vg = bytes[p++];
                    px.rgba.r = vg;
                    px.rgba.g = vg;
                    px.rgba.b = vg;
                    index[index_pos++ & 63] = px;
                }
                else if (b1 == QOI_OP_RGB) {
                    px.rgba.r = bytes[p++];
                    px.rgba.g = bytes[p++];
                    px.rgba.b = bytes[p++];
                    index[index_pos++ & 63] = px;
                }
                else if (b1 == QOI_OP_RGBA) {
                    px.rgba.r = bytes[p++];
                    px.rgba.g = bytes[p++];
                    px.rgba.b = bytes[p++];
                    px.rgba.a = bytes[p++];
                    index[index_pos++ & 63] = px;
                }
                else {              /* QOI_OP_END */
                    break;
                }
            }

            decodedScanline[posx] = px;
            px_pos += channels;
        }

        // convert just-decoded scanline into output type
        ubyte* line = cast(ubyte*)(pixels + desc.pitchBytes * posy);

        switch(channels)
        {
            case 4:
                // No particular conversion to do
                memcpy(line, &decodedScanline[0], desc.width * 4);
                break;

            case 3:
                for (int posx = 0; posx < desc.width; ++posx)
                {
                    qoi_rgba_t decodedPx = decodedScanline[posx]; // No particular conversion to do
                    line[posx * 3 + 0] = decodedPx.rgba.r;
                    line[posx * 3 + 1] = decodedPx.rgba.g;
                    line[posx * 3 + 2] = decodedPx.rgba.b;
                }
                break;
            default:
                assert(false);
        }

        // swap decoded scanline buffers
        {
            qoi_rgba_t* temp = decodedScanline;
            decodedScanline = lastDecodedScanline;
            lastDecodedScanline = temp;
        }
    }

    return pixels;
}

private:

/* Perform LOCO-I prediction independently over the 4 channels.


    int max_ab = a > b ? a : b;
    int min_ab = a < b ? a : b;
    if (c >= max_ab)
        return cast(ubyte)min_ab;
    else if (c <= min_ab)
        return cast(ubyte)max_ab;
    else
    {
        int d = a + b - c;
        if (d < 0)
            d = 0;
        if (d > 255)
            d = 0;
        return cast(ubyte)d;
    }
*/

static RGBA locoIntraPredictionSIMD(RGBA a, RGBA b, RGBA c)
{
    // load RGBA8 pixels
    __m128i A = _mm_loadu_si32(&a); 
    __m128i B = _mm_loadu_si32(&b);
    __m128i C = _mm_loadu_si32(&c);

    // extend to 16-bits
    __m128i Z = _mm_setzero_si128();
    A = _mm_unpacklo_epi8(A, Z);
    B = _mm_unpacklo_epi8(B, Z);
    C = _mm_unpacklo_epi8(C, Z);

    // Max predictor (A + B - C)
    __m128i P = _mm_sub_epi16(_mm_add_epi16(A, B), C);
    __m128i maxAB = _mm_max_epi16(A, B);
    __m128i minAB = _mm_min_epi16(A, B);

    // 1111 where we should use max(A, B)
    __m128i maxMask = _mm_cmple_epi16(C, minAB);

    // 1111 where we should use min(A, B)
    __m128i minMask = _mm_cmpge_epi16(C, maxAB);

    P = (P & (~minMask)) | (minAB & minMask);
    P = (P & (~maxMask)) | (maxAB & maxMask);

    // Get back to u8
    P = _mm_packus_epi16(P, Z);

    RGBA r;
    _mm_storeu_si32(&r, P);

    return r;
}

private __m128i _mm_cmple_epi16(__m128i a, __m128i b) pure @safe
{
    return _mm_or_si128(_mm_cmplt_epi16(a, b), _mm_cmpeq_epi16(a, b));
}

private __m128i _mm_cmpge_epi16(__m128i a, __m128i b)
{
    return _mm_or_si128(_mm_cmpgt_epi16(a, b), _mm_cmpeq_epi16(a, b));
}