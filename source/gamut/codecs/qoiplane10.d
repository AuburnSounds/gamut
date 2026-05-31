module gamut.codecs.qoiplane10;

nothrow @nogc:

import core.stdc.stdlib: realloc, malloc, free;
import core.stdc.string: memset;

import gamut.codecs.qoi2avg;

/// A QOI-inspired codec for 10-bit greyscale (and greyscale + alpha) images,
/// called "QOI-Plane10".
///
/// Incompatible adaptation of QOI format - https://phoboslab.org
///
/// -- LICENSE: The MIT License(MIT)
/// Copyright(c) 2021 Dominic Szablewski (original QOI format)
/// Copyright(c) 2022 Guillaume Piolat (QOI-plane variant, 10-bit adaptation).
/// Permission is hereby granted, free of charge, to any person obtaining a copy of
/// this software and associated documentation files(the "Software"), to deal in
/// the Software without restriction, including without limitation the rights to
/// use, copy, modify, merge, publish, distribute, sublicense, and / or sell copies
/// of the Software, and to permit persons to whom the Software is furnished to do
/// so, subject to the following conditions :
/// The above copyright notice and this permission notice shall be included in all
/// copies or substantial portions of the Software.
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
/// SOFTWARE.
///
/// A QOI-Plane10 file has the standard 25-byte QOIX header. It is distinguished
/// from a QOI-10b stream (which can also carry 1/2 channels) by:
///   - (bitdepth == 10)  AND  (channels == 1 or 2)  AND  (version_ >= 2).
/// Older 1/2-channel 10-bit files written by qoi10b use version_ == 1 and keep
/// decoding on qoi10b; the plugin routes on this.
///
/// Values are 0..1023. The bitstream is 2-bit aligned (every opcode is an even
/// number of bits). All values have the most significant bit on the left.
///
/// luma residual = px.l - pred, where pred is the LOCO-I / MED prediction:
/// QOIPLANE10_DIFF1   0vvv                   ( 4b) => luma residual  -4..+3
/// QOIPLANE10_DIFF2   10vvvvvv               ( 8b) => luma residual -32..+31
/// QOIPLANE10_RUN     110xxx                 ( 6b) => repeat last pixel 1..7 (xxx==7 => + byte, 8..262)
/// QOIPLANE10_DIFF4   1110 vvvvvvvvvv        (14b) => luma residual -512..+511 (full range)
/// QOIPLANE10_DIFF3   11110vvvvvvv           (12b) => luma residual -64..+63
/// QOIPLANE10_ADIFF   111110 aaaaaa          (12b) => alpha residual -32..+31, then a luma opcode follows
/// QOIPLANE10_LA      11111110 LLLLLLLLLL AAAAAAAAAA (28b) => direct full 10-bit luma + alpha
/// QOIPLANE10_END     11111111               ( 8b) => end of stream
///
static immutable ubyte[5] qoiplane10_padding = [255,255,255,255,255];

enum ubyte QOIPLANE10_OP_ADIFF = 0xf8; // 111110xx
enum ubyte QOIPLANE10_OP_LA    = 0xfe; // 11111110
enum ubyte QOIPLANE10_OP_END   = 0xff; // 11111111

enum qoi_la10_t initialPredictor = { l:0, a:1023 };

struct qoi_la10_t
{
    ushort l;
    ushort a;
}


version(qoixStats)
{
    __gshared long qoiplane10_run;
    __gshared long qoiplane10_adiff;
    __gshared long qoiplane10_diff1;
    __gshared long qoiplane10_diff2;
    __gshared long qoiplane10_diff3;
    __gshared long qoiplane10_diff4;
    __gshared long qoiplane10_la;

    void qoiplane10_clear_stats() nothrow @nogc
    {
        qoiplane10_run = qoiplane10_adiff = qoiplane10_diff1 = qoiplane10_diff2 = qoiplane10_diff3 = qoiplane10_diff4 = qoiplane10_la = 0;
    }
}

int locoPredict(int left, int top, int topleft) nothrow @nogc
{
    int max_ab = left > top ? left : top;
    int min_ab = left < top ? left : top;
    if (topleft >= max_ab)
        return min_ab;
    else if (topleft <= min_ab)
        return max_ab;
    int d = left + top - topleft;
    if (d < 0) d = 0;
    if (d > 1023) d = 1023;
    return d;
}

version(encodeQOIX)
ubyte* qoiplane10_encode(const(ubyte)* data, const(qoi_desc)* desc, int *out_len)
{
    if ( (desc.channels != 1 && desc.channels != 2) ||
        desc.width == 0 || desc.height == 0 ||
        desc.height >= QOIX_PIXELS_MAX / desc.width ||
          desc.compression != QOIX_COMPRESSION_NONE
    ) {
        return null;
    }

    if (desc.bitdepth != 10)
        return null;

    int channels = desc.channels;

    // Worst case bits per pixel: 1ch DIFF4 = 14 bits; 2ch LA = 28 bits.
    int num_pixels = desc.width * desc.height;
    int worst_bits = (channels == 1) ? 14 : 28;
    int max_size = cast(int)((cast(long)num_pixels * worst_bits + 7) / 8)
                 + QOIX_HEADER_SIZE + cast(int)(qoiplane10_padding.sizeof);

    int p = 0; // write index into output stream
    ubyte* bytes = cast(ubyte*) QOI_MALLOC(max_size);
    if (!bytes)
        return null;

    qoi_write_32(bytes, &p, QOIX_MAGIC);
    qoi_write_32(bytes, &p, desc.width);
    qoi_write_32(bytes, &p, desc.height);
    bytes[p++] = 2; // 1 would signal QOI-10b instead
    bytes[p++] = desc.channels; // 1 or 2
    bytes[p++] = desc.bitdepth; // 10
    bytes[p++] = desc.colorspace;
    bytes[p++] = QOIX_COMPRESSION_NONE;
    qoi_write_32f(bytes, &p, desc.pixelAspectRatio);
    qoi_write_32f(bytes, &p, desc.resolutionY);

    int currentBit = 7; // beginning of a byte
    bytes[p] = 0;

    // Write the nbits last bits of x, starting from the highest one (2-bit aligned).
    void outputBits(uint x, int nbits) nothrow @nogc
    {
        assert(nbits >= 2 && nbits <= 16);
        assert((nbits % 2) == 0);
        for (int b = nbits - 2; b >= 0; b -= 2)
        {
            ubyte pairOfBits = (x >>> b) & 3;
            bytes[p] |= (pairOfBits << (currentBit - 1));
            currentBit -= 2;
            if (currentBit == -1)
            {
                p++;
                bytes[p] = 0;
                currentBit = 7;
            }
        }
    }

    void outputByte(ubyte b) nothrow @nogc
    {
        outputBits(b, 8);
    }

    int run = 0;
    int run1_pred = 0; // predictor + value of the run's first pixel, so a length-1
    int run1_val = 0;  // run can be re-encoded as DIFF1 when that is cheaper (4b vs 6b)

    void encodeRun() nothrow @nogc
    {
        assert(run > 0 && run <= 256);
        run--;
        version(qoixStats) qoiplane10_run++;
        if (run < 7)
        {
            outputBits( (0x6 << 3) | run, 6 ); // QOIPLANE10_RUN '110xxx'
        }
        else
        {
            outputBits( (0x6 << 3) | 7, 6 );   // '110111' escape
            outputBits(run - 7, 8);
        }
        run = 0;
    }

    void flushRun() nothrow @nogc
    {
        if (run == 1)
        {
            // Is DIFF1 smaller?
            int vg = (run1_val - run1_pred) & 1023;
            if (vg < 4 || vg >= (1024 - 4))
            {
                version(qoixStats) qoiplane10_diff1++;
                outputBits(vg & 0x07, 4); // QOIPLANE10_DIFF1
                run = 0;
                return;
            }
        }
        encodeRun();
    }

    qoi_la10_t px = initialPredictor;
    qoi_la10_t px_ref = initialPredictor;

    int pixels_encoded = 0;

    for (int posy = 0; posy < desc.height; ++posy)
    {
        const(ushort)* line = cast(const(ushort)*)(data + desc.pitchBytes * posy);
        const(ushort)* lineAbove = (posy > 0) ? cast(const(ushort)*)(data + desc.pitchBytes * (posy - 1)) : null;

        for (int posx = 0; posx < desc.width; ++posx)
        {
            px_ref = px;

            // take next pixel to encode, reduce 16-bit -> 10-bit
            if (channels == 1)
            {
                px.l = cast(ushort)(line[posx] >>> 6);
            }
            else
            {
                px.l = cast(ushort)(line[posx * 2 + 0] >>> 6);
                px.a = cast(ushort)(line[posx * 2 + 1] >>> 6);
            }

            // LOCO-I / MED prediction of luma from left/top/topleft (computed for
            // every pixel so a length-1 run can fall back to DIFF1 at flush time).
            int pred;
            if (posy == 0)
                pred = px_ref.l; // no row above: predict from the left pixel
            else if (posx == 0)
                pred = lineAbove[0] >>> 6; // first column: predict from the pixel above
            else
                pred = locoPredict(px_ref.l,
                                   lineAbove[posx * channels] >>> 6,
                                   lineAbove[(posx - 1) * channels] >>> 6);

            if (px == px_ref)
            {
                if (run == 0)
                {
                    run1_pred = pred;  // remember the first run pixel in case the
                    run1_val  = px.l;  // run turns out to be length 1
                }
                run++;
                if (run == 256 || (pixels_encoded + 1 == num_pixels))
                    flushRun();
            }
            else
            {
                if (run > 0)
                    flushRun();

                bool encoded = false;
                int va = (cast(int)px.a - cast(int)px_ref.a) & 1023;
                if (va)
                {
                    assert(channels == 2);
                    if (va < 32 || va >= (1024 - 32)) // fits 6-bit signed?
                    {
                        version(qoixStats) qoiplane10_adiff++;
                        outputBits((0x3e << 6) | (va & 0x3f), 12); // QOIPLANE10_ADIFF, then luma below
                    }
                    else
                    {
                        version(qoixStats) qoiplane10_la++;
                        outputByte(QOIPLANE10_OP_LA);
                        outputBits(px.l, 10);
                        outputBits(px.a, 10);
                        encoded = true;
                    }
                }

                if (!encoded)
                {
                    int vg = (cast(int)px.l - pred) & 1023;

                    if (vg < 4 || vg >= (1024 - 4))
                    {
                        version(qoixStats) qoiplane10_diff1++;
                        outputBits(vg & 0x07, 4); // QOIPLANE10_DIFF1
                    }
                    else if (vg < 32 || vg >= (1024 - 32))
                    {
                        version(qoixStats) qoiplane10_diff2++;
                        outputBits(0x80 | (vg & 0x3f), 8); // QOIPLANE10_DIFF2
                    }
                    else if (vg < 64 || vg >= (1024 - 64)) 
                    {
                        version(qoixStats) qoiplane10_diff3++;
                        outputBits((0x1e << 7) | (vg & 0x7f), 12); // QOIPLANE10_DIFF3
                    }
                    else
                    {
                        version(qoixStats) qoiplane10_diff4++;
                        outputBits((0xe << 10) | (vg & 0x3ff), 14); // QOIPLANE10_DIFF4
                    }
                }
            }

            pixels_encoded++;
        }
    }

    foreach (i; 0 .. cast(int)(qoiplane10_padding.sizeof))
        outputByte(qoiplane10_padding[i]);

    if (currentBit != 7)
        outputBits(0xff, currentBit + 1);
    assert(currentBit == 7);

    *out_len = p;
    return bytes;
}

version(decodeQOIX)
ubyte* qoiplane10_decode(const(ubyte)* data, int size, qoi_desc *desc, int channels)
{
    if ((channels < 0 || channels > 2) ||
            size < QOIX_HEADER_SIZE + cast(int)(qoiplane10_padding.sizeof))
    {
        return null;
    }

    const(ubyte)* bytes = data;
    int p = 0;

    uint header_magic = qoi_read_32(bytes, &p);
    desc.width = qoi_read_32(bytes, &p);
    desc.height = qoi_read_32(bytes, &p);
    int qoix_version = bytes[p++];
    desc.channels = bytes[p++];
    desc.bitdepth = bytes[p++];
    desc.colorspace = bytes[p++];
    desc.compression = bytes[p++];
    desc.pixelAspectRatio = qoi_read_32f(bytes, &p);
    desc.resolutionY = qoi_read_32f(bytes, &p);

    if (desc.width == 0 || desc.height == 0 ||
        desc.channels < 1 || desc.channels > 2 ||
        desc.colorspace > 1 ||
        desc.bitdepth != 10 ||
        qoix_version != 2 ||
        desc.compression != QOIX_COMPRESSION_NONE ||
        header_magic != QOIX_MAGIC ||
        desc.height >= QOIX_PIXELS_MAX / desc.width
        )
    {
        return null;
    }

    if (channels == 0)
        channels = desc.channels;

    int stride = desc.width * channels * 2; // 16-bit output
    desc.pitchBytes = stride;

    int num_pixels = desc.width * desc.height;
    int output_bytes = stride * desc.height;

    ubyte* pixels = cast(ubyte*) QOI_MALLOC(output_bytes);
    if (!pixels)
        return null;

    int currentBit = 7;

    void rewindInputBit() nothrow @nogc
    {
        if (currentBit == 7)
        {
            p--;
            currentBit = -1;
        }
        currentBit++;
    }

    int read2Bits() nothrow @nogc
    {
        int bit = (bytes[p] >>> (currentBit - 1)) & 3;
        currentBit -= 2;
        if (currentBit == -1)
        {
            currentBit = 7;
            p++;
        }
        return bit;
    }

    uint readBits(int nbits) nothrow @nogc
    {
        assert(nbits % 2 == 0);
        uint r = 0;
        for (int b = 0; b < nbits; b += 2)
            r = (r << 2) | read2Bits();
        return r;
    }

    ubyte readByte() nothrow @nogc
    {
        return cast(ubyte) readBits(8);
    }

    qoi_la10_t px = initialPredictor;
    qoi_la10_t px_ref = initialPredictor;

    int decoded_pixels = 0;
    int run = 0;

    for (int posy = 0; posy < desc.height; ++posy)
    {
        ushort* line = cast(ushort*)(pixels + desc.pitchBytes * posy);
        
        // Only read .l from the line above (alpha may be absent when decoding 2ch->1ch).
        const(ushort)* lineAbove = (posy > 0) ? cast(const(ushort)*)(pixels + desc.pitchBytes * (posy - 1)) : null;

        for (int posx = 0; posx < desc.width; ++posx)
        {
            px_ref = px;

            if (run > 0)
            {
                run--;
            }
            else if (decoded_pixels < num_pixels)
            {
                int pred;
                if (posy == 0)
                    pred = px_ref.l; // no row above: predict from the left pixel
                else if (posx == 0)
                    pred = lineAbove[0] >>> 6; // first column: predict from the pixel above
                else
                    pred = locoPredict(px_ref.l,
                                       lineAbove[posx * channels] >>> 6,
                                       lineAbove[(posx - 1) * channels] >>> 6);

                decode_op:
                ubyte op = readByte();

                if (op < 0x80) // QOIPLANE10_DIFF1
                {
                    int vg = (op >> 4) & 0x07;
                    vg = (vg << 29) >> 29; // sign-extend 3-bit
                    rewindInputBit();
                    rewindInputBit();
                    rewindInputBit();
                    rewindInputBit();
                    px.l = cast(ushort)((pred + vg) & 1023);
                }
                else if (op < 0xc0) // QOIPLANE10_DIFF2
                {
                    int vg = op & 0x3f;
                    vg = (vg << 26) >> 26; // sign-extend 6-bit
                    px.l = cast(ushort)((pred + vg) & 1023);
                }
                else if (op < 0xe0) // QOIPLANE10_RUN '110xxx' (6-bit)
                {
                    run = (op >> 2) & 7;
                    rewindInputBit(); // 6-bit opcode: rewind the 2 over-read bits
                    rewindInputBit();
                    if (run == 7)
                        run = readBits(8) + 7;
                }
                else if (op < 0xf0) // QOIPLANE10_DIFF4 (full range)
                {
                    int vg = ((op & 0x0f) << 6) | readBits(6);
                    vg = (vg << 22) >> 22; // sign-extend 10-bit
                    px.l = cast(ushort)((pred + vg) & 1023);
                }
                else if (op < 0xf8) // QOIPLANE10_DIFF3 '11110vvvvvvv' (12-bit)
                {
                    int vg = ((op & 0x07) << 4) | readBits(4);
                    vg = (vg << 25) >> 25; // sign-extend 7-bit
                    px.l = cast(ushort)((pred + vg) & 1023);
                }
                else if (op < 0xfc) // QOIPLANE10_ADIFF '111110xx'
                {
                    int va = ((op & 3) << 4) | readBits(4);
                    va = (va << 26) >> 26; // sign-extend 6-bit
                    px.a = cast(ushort)((px_ref.a + va) & 1023);
                    goto decode_op; // a luma opcode follows
                }
                else if (op == QOIPLANE10_OP_LA)
                {
                    px.l = cast(ushort) readBits(10);
                    px.a = cast(ushort) readBits(10);
                }
                else if (op == QOIPLANE10_OP_END)
                {
                    goto finished;
                }
                else
                {
                    assert(false); // 0xfc, 0xfd reserved
                }
                decoded_pixels++;
            }

            // expand 10-bit -> 16-bit
            ushort l16 = cast(ushort)((px.l << 6) | (px.l >>> 4));
            if (channels == 1)
            {
                line[posx] = l16;
            }
            else
            {
                ushort a16 = cast(ushort)((px.a << 6) | (px.a >>> 4));
                line[posx * 2 + 0] = l16;
                line[posx * 2 + 1] = a16;
            }
        }
    }

    finished:
    return pixels;
}
