/// stb_image_write.h translations
/// Just the PNG encoder.
module gamut.codecs.stb_image_write;

/* stb_image_write - v1.16 - public domain - http://nothings.org/stb
   writes out PNG/BMP/TGA/JPEG/HDR images to C stdio - Sean Barrett 2010-2015
                                     no warranty implied; use at your own risk

   Before #including,

       #define STB_IMAGE_WRITE_IMPLEMENTATION

   in the file that you want to have the implementation.

   Will probably not work correctly with strict-aliasing optimizations.

ABOUT:

   This header file is a library for writing images to C stdio or a callback.

   The PNG output is not optimal; it is 20-50% larger than the file
   written by a decent optimizing implementation; though providing a custom
   zlib compress function (see STBIW_ZLIB_COMPRESS) can mitigate that.
   This library is designed for source code compactness and simplicity,
   not optimal image file size or run-time performance.


USAGE:

   There are one function:

     int stbi_write_bmp(char const *filename, int w, int h, int comp, const void *data);

   You can configure it with these global variables:
      int stbi_write_png_compression_level;    // defaults to 8; set to higher for more compression
      int stbi_write_force_png_filter;         // defaults to -1; set to 0..5 to force a filter mode

   Each function returns 0 on failure and non-0 on success.

   The functions create an image file defined by the parameters. The image
   is a rectangle of pixels stored from left-to-right, top-to-bottom.
   Each pixel contains 'comp' channels of data stored interleaved with 8-bits
   per channel, in the following order: 1=Y, 2=YA, 3=RGB, 4=RGBA. (Y is
   monochrome color.) The rectangle is 'w' pixels wide and 'h' pixels tall.
   The *data pointer points to the first byte of the top-left-most pixel.
   For PNG, "stride_in_bytes" is the distance in bytes from the first byte of
   a row of pixels to the first byte of the next row of pixels.

   PNG creates output files with the same number of components as the input.
   The BMP format expands Y to RGB in the file format and does not
   output alpha.

   PNG supports writing rectangles of data even when the bytes storing rows of
   data are not consecutive in memory (e.g. sub-rectangles of a larger image),
   by supplying the stride between the beginning of adjacent rows. The other
   formats do not. (Thus you cannot write a native-format BMP through the BMP
   writer, both because it is in BGR order and because it may have padding
   at the end of the line.)

   PNG allows you to set the deflate compression level by setting the global
   variable 'stbi_write_png_compression_level' (it defaults to 8).

CREDITS:


   Sean Barrett           -    PNG/BMP/TGA
   Baldur Karlsson        -    HDR
   Jean-Sebastien Guay    -    TGA monochrome
   Tim Kelsey             -    misc enhancements
   Alan Hickman           -    TGA RLE
   Emmanuel Julien        -    initial file IO callback implementation
   Jon Olick              -    original jo_jpeg.cpp code
   Daniel Gibson          -    integrate JPEG, allow external zlib
   Aarni Koskela          -    allow choosing PNG filter

   bugfixes:
      github:Chribba
      Guillaume Chereau
      github:jry2
      github:romigrou
      Sergio Gonzalez
      Jonas Karlsson
      Filip Wasil
      Thatcher Ulrich
      github:poppolopoppo
      Patrick Boettcher
      github:xeekworx
      Cap Petschulat
      Simon Rodriguez
      Ivan Tikhonov
      github:ignotion
      Adam Schackart
      Andrew Kensler

LICENSE

  See end of file for license information.

*/

version(encodePNG)
    version = compileSTBImageWrite;
version(encodeJPEG)
    version = compileSTBImageWrite;

version(compileSTBImageWrite):

import std.math: abs;
import core.stdc.stdlib: malloc, realloc, free;
import core.stdc.string: memcpy, memmove;
import gamut.codecs.miniz;

nothrow @nogc:

private:

alias STBIW_MALLOC = malloc;
alias STBIW_REALLOC = realloc;
alias STBIW_FREE = free;
alias STBIW_MEMMOVE = memmove;

void* STBIW_REALLOC_SIZED(void *ptr, size_t oldsz, size_t newsz)
{
    return realloc(ptr, newsz);
}

ubyte STBIW_UCHAR(int x)
{
    return cast(ubyte)(x);
}

enum int stbi_write_png_compression_level = 5;
enum int stbi_write_force_png_filter = -1;

// Useful?
enum int stbi__flip_vertically_on_write = 0;


alias stbiw_uint32 = uint;

//////////////////////////////////////////////////////////////////////////////
//
// PNG writer
//


// write context

alias stbi_write_func = void function(void *context, const(void)* data, int size);

struct stbi__write_context
{
    stbi_write_func func = null;
    void* context = null;
    ubyte[64] buffer;
    int buf_used = 0;
}

// initialize a callback-based context
void stbi__start_write_callbacks(stbi__write_context *s, stbi_write_func c, void *context)
{
    s.func    = c;
    s.context = context;
}

static void stbiw__putc(stbi__write_context *s, ubyte c)
{
    s.func(s.context, &c, 1);
}

/// Free result with free
ubyte * stbi_zlib_compress(ubyte *data, int data_len, int *out_len, int quality)
{
    size_t outLenSize_t;
    assert(quality >= 1 && quality <= 9);
    uint comp_flags = TDEFL_COMPUTE_ADLER32 
        | tdefl_create_comp_flags_from_zip_params(quality, MZ_DEFAULT_WINDOW_BITS, MZ_DEFAULT_STRATEGY);

    ubyte* res = cast(ubyte*) tdefl_compress_mem_to_heap(data, data_len, &outLenSize_t, comp_flags);

    if (res)
    {
        assert(outLenSize_t <= int.max); // else overflow, fix this library
        *out_len = cast(int) outLenSize_t;
    }
    return res;
}

static uint stbiw__crc32(ubyte *buffer, int len)
{
    static immutable uint[256] crc_table =
    [
        0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA, 0x076DC419, 0x706AF48F, 0xE963A535, 0x9E6495A3,
        0x0eDB8832, 0x79DCB8A4, 0xE0D5E91E, 0x97D2D988, 0x09B64C2B, 0x7EB17CBD, 0xE7B82D07, 0x90BF1D91,
        0x1DB71064, 0x6AB020F2, 0xF3B97148, 0x84BE41DE, 0x1ADAD47D, 0x6DDDE4EB, 0xF4D4B551, 0x83D385C7,
        0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC, 0x14015C4F, 0x63066CD9, 0xFA0F3D63, 0x8D080DF5,
        0x3B6E20C8, 0x4C69105E, 0xD56041E4, 0xA2677172, 0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B,
        0x35B5A8FA, 0x42B2986C, 0xDBBBC9D6, 0xACBCF940, 0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59,
        0x26D930AC, 0x51DE003A, 0xC8D75180, 0xBFD06116, 0x21B4F4B5, 0x56B3C423, 0xCFBA9599, 0xB8BDA50F,
        0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924, 0x2F6F7C87, 0x58684C11, 0xC1611DAB, 0xB6662D3D,
        0x76DC4190, 0x01DB7106, 0x98D220BC, 0xEFD5102A, 0x71B18589, 0x06B6B51F, 0x9FBFE4A5, 0xE8B8D433,
        0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818, 0x7F6A0DBB, 0x086D3D2D, 0x91646C97, 0xE6635C01,
        0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E, 0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457,
        0x65B0D9C6, 0x12B7E950, 0x8BBEB8EA, 0xFCB9887C, 0x62DD1DDF, 0x15DA2D49, 0x8CD37CF3, 0xFBD44C65,
        0x4DB26158, 0x3AB551CE, 0xA3BC0074, 0xD4BB30E2, 0x4ADFA541, 0x3DD895D7, 0xA4D1C46D, 0xD3D6F4FB,
        0x4369E96A, 0x346ED9FC, 0xAD678846, 0xDA60B8D0, 0x44042D73, 0x33031DE5, 0xAA0A4C5F, 0xDD0D7CC9,
        0x5005713C, 0x270241AA, 0xBE0B1010, 0xC90C2086, 0x5768B525, 0x206F85B3, 0xB966D409, 0xCE61E49F,
        0x5EDEF90E, 0x29D9C998, 0xB0D09822, 0xC7D7A8B4, 0x59B33D17, 0x2EB40D81, 0xB7BD5C3B, 0xC0BA6CAD,
        0xEDB88320, 0x9ABFB3B6, 0x03B6E20C, 0x74B1D29A, 0xEAD54739, 0x9DD277AF, 0x04DB2615, 0x73DC1683,
        0xE3630B12, 0x94643B84, 0x0D6D6A3E, 0x7A6A5AA8, 0xE40ECF0B, 0x9309FF9D, 0x0A00AE27, 0x7D079EB1,
        0xF00F9344, 0x8708A3D2, 0x1E01F268, 0x6906C2FE, 0xF762575D, 0x806567CB, 0x196C3671, 0x6E6B06E7,
        0xFED41B76, 0x89D32BE0, 0x10DA7A5A, 0x67DD4ACC, 0xF9B9DF6F, 0x8EBEEFF9, 0x17B7BE43, 0x60B08ED5,
        0xD6D6A3E8, 0xA1D1937E, 0x38D8C2C4, 0x4FDFF252, 0xD1BB67F1, 0xA6BC5767, 0x3FB506DD, 0x48B2364B,
        0xD80D2BDA, 0xAF0A1B4C, 0x36034AF6, 0x41047A60, 0xDF60EFC3, 0xA867DF55, 0x316E8EEF, 0x4669BE79,
        0xCB61B38C, 0xBC66831A, 0x256FD2A0, 0x5268E236, 0xCC0C7795, 0xBB0B4703, 0x220216B9, 0x5505262F,
        0xC5BA3BBE, 0xB2BD0B28, 0x2BB45A92, 0x5CB36A04, 0xC2D7FFA7, 0xB5D0CF31, 0x2CD99E8B, 0x5BDEAE1D,
        0x9B64C2B0, 0xEC63F226, 0x756AA39C, 0x026D930A, 0x9C0906A9, 0xEB0E363F, 0x72076785, 0x05005713,
        0x95BF4A82, 0xE2B87A14, 0x7BB12BAE, 0x0CB61B38, 0x92D28E9B, 0xE5D5BE0D, 0x7CDCEFB7, 0x0BDBDF21,
        0x86D3D2D4, 0xF1D4E242, 0x68DDB3F8, 0x1FDA836E, 0x81BE16CD, 0xF6B9265B, 0x6FB077E1, 0x18B74777,
        0x88085AE6, 0xFF0F6A70, 0x66063BCA, 0x11010B5C, 0x8F659EFF, 0xF862AE69, 0x616BFFD3, 0x166CCF45,
        0xA00AE278, 0xD70DD2EE, 0x4E048354, 0x3903B3C2, 0xA7672661, 0xD06016F7, 0x4969474D, 0x3E6E77DB,
        0xAED16A4A, 0xD9D65ADC, 0x40DF0B66, 0x37D83BF0, 0xA9BCAE53, 0xDEBB9EC5, 0x47B2CF7F, 0x30B5FFE9,
        0xBDBDF21C, 0xCABAC28A, 0x53B39330, 0x24B4A3A6, 0xBAD03605, 0xCDD70693, 0x54DE5729, 0x23D967BF,
        0xB3667A2E, 0xC4614AB8, 0x5D681B02, 0x2A6F2B94, 0xB40BBE37, 0xC30C8EA1, 0x5A05DF1B, 0x2D02EF8D
    ];

    uint crc = ~0u;
    int i;
    for (i=0; i < len; ++i)
        crc = (crc >> 8) ^ crc_table[buffer[i] ^ (crc & 0xff)];
    return ~crc;
}

void stbiw__wpng4(ref ubyte* o, ubyte a, ubyte b, ubyte c, ubyte d)
{
    o[0] = a;
    o[1] = b;
    o[2] = c;
    o[3] = d;
    o += 4;
}

void stbiw__wp32(ref ubyte* data, uint v)
{
    stbiw__wpng4(data, v >> 24, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
}

void stbiw__wptag(ref ubyte* data, char[4] s)
{
    stbiw__wpng4(data, s[0], s[1], s[2], s[3]);
}

static void stbiw__wpcrc(ubyte **data, int len)
{
   uint crc = stbiw__crc32(*data - len - 4, len+4);
   stbiw__wp32(*data, crc);
}

ubyte stbiw__paeth(int a, int b, int c)
{
   int p = a + b - c, pa = abs(p-a), pb = abs(p-b), pc = abs(p-c);
   if (pa <= pb && pa <= pc) return STBIW_UCHAR(a);
   if (pb <= pc) return STBIW_UCHAR(b);
   return STBIW_UCHAR(c);
}

// @OPTIMIZE: provide an option that always forces left-predict or paeth predict
static void stbiw__encode_png_line(ubyte *pixels, 
                                   int stride_bytes, 
                                   int width, 
                                   int height, 
                                   int y, 
                                   int n,
                                   bool is16bit,
                                   int filter_type, 
                                   byte* line_buffer)
{
   static immutable int[5] mapping  = [ 0,1,2,3,4 ];
   static immutable int[5] firstmap = [ 0,1,0,5,6 ];
   immutable(int)* mymap = (y != 0) ? mapping.ptr : firstmap.ptr;
   int i;
   int type = mymap[filter_type];
   ubyte *z = pixels + stride_bytes * (stbi__flip_vertically_on_write ? height-1-y : y);
   int signed_stride = stbi__flip_vertically_on_write ? -stride_bytes : stride_bytes;

   int line_bytes = width * n * (is16bit ? 2 : 1);

   if (type==0) {

      if (is16bit)
      {
          version(LittleEndian)
          {
               // 16-bit PNG samples are actually in Big Endian
               for (int x = 0; x < width*n; ++x)
               {
                   line_buffer[x*2  ] = z[x*2+1];
                   line_buffer[x*2+1] = z[x*2  ];
               }
          }
          else
              memcpy(line_buffer, z, line_bytes);
      }
      else
      {
          memcpy(line_buffer, z, line_bytes);
      }
      return;
   }

   int bytePerSample = n * (is16bit ? 2 : 1);
   int leftOffset = bytePerSample;

   // first loop isn't optimized since it's just one pixel
   for (i = 0; i < bytePerSample; ++i) {
      switch (type) {
         case 1: line_buffer[i] = z[i]; break;
         case 2: line_buffer[i] = cast(byte)(z[i] - z[i-signed_stride]); break;
         case 3: line_buffer[i] = cast(byte)(z[i] - (z[i-signed_stride]>>1)); break;
         case 4: line_buffer[i] = cast(byte) (z[i] - stbiw__paeth(0,z[i-signed_stride],0)); break;
         case 5: line_buffer[i] = z[i]; break;
         case 6: line_buffer[i] = z[i]; break;
         default: assert(0);
      }
   }
   switch (type) {
      case 1: for (i=bytePerSample; i < line_bytes; ++i) line_buffer[i] = cast(byte)(z[i] - z[i-leftOffset]); break;
      case 2: for (i=bytePerSample; i < line_bytes; ++i) line_buffer[i] = cast(byte)(z[i] - z[i-signed_stride]); break;
      case 3: for (i=bytePerSample; i < line_bytes; ++i) line_buffer[i] = cast(byte)(z[i] - ((z[i-leftOffset] + z[i-signed_stride])>>1)); break;
      case 4: for (i=bytePerSample; i < line_bytes; ++i) line_buffer[i] = cast(byte)(z[i] - stbiw__paeth(z[i-leftOffset], z[i-signed_stride], z[i-signed_stride-leftOffset])); break;
      case 5: for (i=bytePerSample; i < line_bytes; ++i) line_buffer[i] = cast(byte)(z[i] - (z[i-leftOffset]>>1)); break;
      case 6: for (i=bytePerSample; i < line_bytes; ++i) line_buffer[i] = cast(byte)(z[i] - stbiw__paeth(z[i-leftOffset], 0,0)); break;
      default: assert(0);
   }

   version(LittleEndian)
   {
       if (is16bit)
       {
           // swap bytes
           // 16-bit PNG samples are actually in Big Endian
           // Note that the whole prediction is happening in the native endianness.
           // (Gamut stores 16-bit samples in native endianness).
           for (int x = 0; x < width*n; ++x)
           {
               ubyte b = line_buffer[x*2  ];
               line_buffer[x*2  ] = line_buffer[x*2+1];
               line_buffer[x*2+1] = b;
           }
       }
   }
}

public ubyte *stbi_write_png_to_mem(const(ubyte*) pixels, int stride_bytes, int x, int y, int n, int *out_len, bool is16bit)
{
    int force_filter = stbi_write_force_png_filter;

    static immutable int[5] ctype = [ -1, 0, 4, 2, 6 ];
    static immutable ubyte[8] sig = [ 137,80,78,71,13,10,26,10 ];
    ubyte *out_, o, filt, zlib;
    byte* line_buffer;
    int j, zlen;

    int lineBytes = x * n * (is16bit ? 2 : 1);

    if (force_filter >= 5) 
    {
        force_filter = -1;
    }

    filt = cast(ubyte *) STBIW_MALLOC((lineBytes + 1) * y); // +1 byte for the filter type
    if (!filt) 
        return null;
    line_buffer = cast(byte *) STBIW_MALLOC(lineBytes); 
    if (!line_buffer) 
    { 
        STBIW_FREE(filt); 
        return null; 
    }

   for (j=0; j < y; ++j) 
   {
      int filter_type;
      if (force_filter > -1) {
         filter_type = force_filter;
         stbiw__encode_png_line(cast(ubyte*)(pixels), stride_bytes, x, y, j, n, is16bit, force_filter, line_buffer);

      } else { // Estimate the best filter by running through all of them:
         int best_filter = 0, best_filter_val = 0x7fffffff, est, i;
         for (filter_type = 0; filter_type < 5; filter_type++) {
            stbiw__encode_png_line(cast(ubyte*)(pixels), stride_bytes, x, y, j, n, is16bit, filter_type, line_buffer);

            // Estimate the entropy of the line using this filter; the less, the better.
            est = 0;
            for (i = 0; i < x*n; ++i) { // Note: adapting that entropy for 16-bit samples wins nothing.
               est += abs(line_buffer[i]);
            }
            if (est < best_filter_val) {
               best_filter_val = est;
               best_filter = filter_type;
            }
         }
         if (filter_type != best_filter)   // If the last iteration already got us the best filter, don't redo it
         {
            stbiw__encode_png_line(cast(ubyte*)(pixels), stride_bytes, x, y, j, n, is16bit, best_filter, line_buffer);
            filter_type = best_filter;
         }
      }
      // when we get here, filter_type contains the filter type, and line_buffer contains the data
      filt[j*(lineBytes+1)] = cast(ubyte) filter_type;
      STBIW_MEMMOVE(filt+j*(lineBytes+1)+1, line_buffer, lineBytes);
   }
   STBIW_FREE(line_buffer);
   zlib = stbi_zlib_compress(filt, y*(lineBytes+1), &zlen, stbi_write_png_compression_level);
   STBIW_FREE(filt);
   if (!zlib) 
       return null;

   // each tag requires 12 bytes of overhead
   out_ = cast(ubyte *) STBIW_MALLOC(8 + 12+13 + 12+zlen + 12);
   if (!out_) return null;
   *out_len = 8 + 12+13 + 12+zlen + 12;

   o = out_;
   STBIW_MEMMOVE(o, sig.ptr, 8); 
   o+= 8;
   stbiw__wp32(o, 13); // header length
   stbiw__wptag(o, "IHDR");
   stbiw__wp32(o, x);
   stbiw__wp32(o, y);
   *o++ = (is16bit ? 16 : 8);
   *o++ = STBIW_UCHAR(ctype[n]);
   *o++ = 0;
   *o++ = 0;
   *o++ = 0;
   stbiw__wpcrc(&o,13);

   stbiw__wp32(o, zlen);
   stbiw__wptag(o, "IDAT");
   STBIW_MEMMOVE(o, zlib, zlen);
   o += zlen;
   STBIW_FREE(zlib);
   stbiw__wpcrc(&o, zlen);

   stbiw__wp32(o,0);
   stbiw__wptag(o, "IEND");
   stbiw__wpcrc(&o,0);

   assert(o == out_ + *out_len);

   return out_;
}



// JPEG encoder


/* ***************************************************************************
*
* JPEG writer
*
* This is based on Jon Olick's jo_jpeg.cpp:
* public domain Simple, Minimalistic JPEG writer - http://www.jonolick.com/code.html
*/

static immutable ubyte[64] stbiw__jpg_ZigZag = 
[ 0,1,5,6,14,15,27,28,2,4,7,13,16,26,29,42,3,8,12,17,25,30,41,43,9,11,18,
24,31,40,44,53,10,19,23,32,39,45,52,54,20,22,33,38,46,51,55,60,21,34,37,47,50,56,59,61,35,36,48,49,57,58,62,63 ];

void stbiw__jpg_writeBits(stbi__write_context *s, int *bitBufP, int *bitCntP, const(ushort)* bs) 
{
    int bitBuf = *bitBufP;
    int bitCnt = *bitCntP;
    bitCnt += bs[1];
    bitBuf |= bs[0] << (24 - bitCnt);
    while(bitCnt >= 8) 
    {
        ubyte c = (bitBuf >> 16) & 255;
        stbiw__putc(s, c);
        if(c == 255) {
            stbiw__putc(s, 0);
        }
        bitBuf <<= 8;
        bitCnt -= 8;
    }
    *bitBufP = bitBuf;
    *bitCntP = bitCnt;
}

void stbiw__jpg_DCT(float *d0p, float *d1p, float *d2p, float *d3p, float *d4p, float *d5p, float *d6p, float *d7p) 
{
    float d0 = *d0p, d1 = *d1p, d2 = *d2p, d3 = *d3p, d4 = *d4p, d5 = *d5p, d6 = *d6p, d7 = *d7p;
    float z1, z2, z3, z4, z5, z11, z13;

    float tmp0 = d0 + d7;
    float tmp7 = d0 - d7;
    float tmp1 = d1 + d6;
    float tmp6 = d1 - d6;
    float tmp2 = d2 + d5;
    float tmp5 = d2 - d5;
    float tmp3 = d3 + d4;
    float tmp4 = d3 - d4;

    // Even part
    float tmp10 = tmp0 + tmp3;   // phase 2
    float tmp13 = tmp0 - tmp3;
    float tmp11 = tmp1 + tmp2;
    float tmp12 = tmp1 - tmp2;

    d0 = tmp10 + tmp11;       // phase 3
    d4 = tmp10 - tmp11;

    z1 = (tmp12 + tmp13) * 0.707106781f; // c4
    d2 = tmp13 + z1;       // phase 5
    d6 = tmp13 - z1;

    // Odd part
    tmp10 = tmp4 + tmp5;       // phase 2
    tmp11 = tmp5 + tmp6;
    tmp12 = tmp6 + tmp7;

    // The rotator is modified from fig 4-8 to avoid extra negations.
    z5 = (tmp10 - tmp12) * 0.382683433f; // c6
    z2 = tmp10 * 0.541196100f + z5; // c2-c6
    z4 = tmp12 * 1.306562965f + z5; // c2+c6
    z3 = tmp11 * 0.707106781f; // c4

    z11 = tmp7 + z3;      // phase 5
    z13 = tmp7 - z3;

    *d5p = z13 + z2;         // phase 6
    *d3p = z13 - z2;
    *d1p = z11 + z4;
    *d7p = z11 - z4;

    *d0p = d0;  
    *d2p = d2;  
    *d4p = d4;  
    *d6p = d6;
}

void stbiw__jpg_calcBits(int val, ushort* bits) 
{
    int tmp1 = val < 0 ? -val : val;
    val = val < 0 ? val-1 : val;
    bits[1] = 1;
    while(tmp1 >>= 1) 
    {
        ++bits[1];
    }
    bits[0] = cast(ushort)(val & ((1<<bits[1])-1));
}

int stbiw__jpg_processDU(stbi__write_context *s, int *bitBuf, int *bitCnt, 
                         float *CDU, int du_stride, float *fdtbl, int DC, 
                         const(ushort[2])* HTDC, 
                         const(ushort[2])* HTAC) 
{
    const(ushort[2]) EOB = [ HTAC[0x00][0], HTAC[0x00][1] ];
    const(ushort[2]) M16zeroes = [ HTAC[0xF0][0], HTAC[0xF0][1] ];
    int dataOff, i, j, n, diff, end0pos, x, y;
    int[64] DU;

    // DCT rows
    for(dataOff=0, n=du_stride*8; dataOff<n; dataOff+=du_stride) 
    {
        stbiw__jpg_DCT(&CDU[dataOff], &CDU[dataOff+1], &CDU[dataOff+2], &CDU[dataOff+3], &CDU[dataOff+4], &CDU[dataOff+5], &CDU[dataOff+6], &CDU[dataOff+7]);
    }
    // DCT columns
    for(dataOff=0; dataOff<8; ++dataOff) 
    {
        stbiw__jpg_DCT(&CDU[dataOff], &CDU[dataOff+du_stride], &CDU[dataOff+du_stride*2], &CDU[dataOff+du_stride*3], &CDU[dataOff+du_stride*4],
                       &CDU[dataOff+du_stride*5], &CDU[dataOff+du_stride*6], &CDU[dataOff+du_stride*7]);
    }
    // Quantize/descale/zigzag the coefficients
    for(y = 0, j=0; y < 8; ++y) 
    {
        for(x = 0; x < 8; ++x,++j) 
        {
            float v;
            i = y*du_stride+x;
            v = CDU[i]*fdtbl[j];
            // DU[stbiw__jpg_ZigZag[j]] = (int)(v < 0 ? ceilf(v - 0.5f) : floorf(v + 0.5f));
            // ceilf() and floorf() are C99, not C89, but I /think/ they're not needed here anyway?
            DU[stbiw__jpg_ZigZag[j]] = cast(int)(v < 0 ? v - 0.5f : v + 0.5f);
        }
    }

    // Encode DC
    diff = DU[0] - DC;
    if (diff == 0) {
        stbiw__jpg_writeBits(s, bitBuf, bitCnt, HTDC[0].ptr);
    } else {
        ushort[2] bits;
        stbiw__jpg_calcBits(diff, bits.ptr);
        stbiw__jpg_writeBits(s, bitBuf, bitCnt, HTDC[bits[1]].ptr);
        stbiw__jpg_writeBits(s, bitBuf, bitCnt, bits.ptr);
    }
    // Encode ACs
    end0pos = 63;
    for(; (end0pos>0)&&(DU[end0pos]==0); --end0pos) {
    }
    // end0pos = first element in reverse order !=0
    if(end0pos == 0) {
        stbiw__jpg_writeBits(s, bitBuf, bitCnt, EOB.ptr);
        return DU[0];
    }
    for(i = 1; i <= end0pos; ++i) {
        int startpos = i;
        int nrzeroes;
        ushort[2] bits;
        for (; DU[i]==0 && i<=end0pos; ++i) {
        }
        nrzeroes = i-startpos;
        if ( nrzeroes >= 16 ) {
            int lng = nrzeroes>>4;
            int nrmarker;
            for (nrmarker=1; nrmarker <= lng; ++nrmarker)
                stbiw__jpg_writeBits(s, bitBuf, bitCnt, M16zeroes.ptr);
            nrzeroes &= 15;
        }
        stbiw__jpg_calcBits(DU[i], bits.ptr);
        stbiw__jpg_writeBits(s, bitBuf, bitCnt, HTAC[(nrzeroes<<4)+bits[1]].ptr);
        stbiw__jpg_writeBits(s, bitBuf, bitCnt, bits.ptr);
    }
    if(end0pos != 63) {
        stbiw__jpg_writeBits(s, bitBuf, bitCnt, EOB.ptr);
    }
    return DU[0];
}

int stbi_write_jpg_core(stbi__write_context *s, int width, int height, int comp, const void* data, int quality) 
{
    // Constants that don't pollute global namespace
    static immutable ubyte[17] std_dc_luminance_nrcodes = [0,0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0];
    static immutable ubyte[12] std_dc_luminance_values  = [0,1,2,3,4,5,6,7,8,9,10,11];
    static immutable ubyte[17] std_ac_luminance_nrcodes = [0,0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d];
    static immutable ubyte[162] std_ac_luminance_values = [
        0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12, 0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,
        0x22,0x71,0x14,0x32,0x81,0x91,0xa1,0x08, 0x23,0x42,0xb1,0xc1,0x15,0x52,0xd1,0xf0,
        0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16, 0x17,0x18,0x19,0x1a,0x25,0x26,0x27,0x28,
        0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39, 0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,
        0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59, 0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,
        0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79, 0x7a,0x83,0x84,0x85,0x86,0x87,0x88,0x89,
        0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98, 0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,
        0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6, 0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,
        0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4, 0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe1,0xe2,
        0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea, 0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,
        0xf9,0xfa
    ];

    static immutable ubyte[17] std_dc_chrominance_nrcodes = [0,0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0];
    static immutable ubyte[12] std_dc_chrominance_values  = [0,1,2,3,4,5,6,7,8,9,10,11];
    static immutable ubyte[17] std_ac_chrominance_nrcodes = [0,0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,0x77];
    static immutable ubyte[162] std_ac_chrominance_values = [
        0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21, 0x31,0x06,0x12,0x41,0x51,0x07,0x61,0x71,
        0x13,0x22,0x32,0x81,0x08,0x14,0x42,0x91, 0xa1,0xb1,0xc1,0x09,0x23,0x33,0x52,0xf0,
        0x15,0x62,0x72,0xd1,0x0a,0x16,0x24,0x34, 0xe1,0x25,0xf1,0x17,0x18,0x19,0x1a,0x26,
        0x27,0x28,0x29,0x2a,0x35,0x36,0x37,0x38, 0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,
        0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58, 0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,
        0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78, 0x79,0x7a,0x82,0x83,0x84,0x85,0x86,0x87,
        0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96, 0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,
        0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4, 0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,
        0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2, 0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,
        0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9, 0xea,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,
        0xf9,0xfa
    ];

    // Huffman tables
    static immutable ushort[2][256] YDC_HT = 
    [ [0,2],[2,3],[3,3],[4,3],[5,3],[6,3],[14,4],[30,5],[62,6],[126,7],[254,8],[510,9] ];

    static immutable ushort[2][256] UVDC_HT = 
    [ [0,2],[1,2],[2,2],[6,3],[14,4],[30,5],[62,6],[126,7],[254,8],[510,9],[1022,10],[2046,11]];

    static immutable ushort[2][256] YAC_HT = 
    [
        [10,4],[0,2],[1,2],[4,3],[11,4],[26,5],[120,7],[248,8],[1014,10],[65410,16],[65411,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [12,4],[27,5],[121,7],[502,9],[2038,11],[65412,16],[65413,16],[65414,16],[65415,16],[65416,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [28,5],[249,8],[1015,10],[4084,12],[65417,16],[65418,16],[65419,16],[65420,16],[65421,16],[65422,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [58,6],[503,9],[4085,12],[65423,16],[65424,16],[65425,16],[65426,16],[65427,16],[65428,16],[65429,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [59,6],[1016,10],[65430,16],[65431,16],[65432,16],[65433,16],[65434,16],[65435,16],[65436,16],[65437,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [122,7],[2039,11],[65438,16],[65439,16],[65440,16],[65441,16],[65442,16],[65443,16],[65444,16],[65445,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [123,7],[4086,12],[65446,16],[65447,16],[65448,16],[65449,16],[65450,16],[65451,16],[65452,16],[65453,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [250,8],[4087,12],[65454,16],[65455,16],[65456,16],[65457,16],[65458,16],[65459,16],[65460,16],[65461,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [504,9],[32704,15],[65462,16],[65463,16],[65464,16],[65465,16],[65466,16],[65467,16],[65468,16],[65469,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [505,9],[65470,16],[65471,16],[65472,16],[65473,16],[65474,16],[65475,16],[65476,16],[65477,16],[65478,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [506,9],[65479,16],[65480,16],[65481,16],[65482,16],[65483,16],[65484,16],[65485,16],[65486,16],[65487,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [1017,10],[65488,16],[65489,16],[65490,16],[65491,16],[65492,16],[65493,16],[65494,16],[65495,16],[65496,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [1018,10],[65497,16],[65498,16],[65499,16],[65500,16],[65501,16],[65502,16],[65503,16],[65504,16],[65505,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [2040,11],[65506,16],[65507,16],[65508,16],[65509,16],[65510,16],[65511,16],[65512,16],[65513,16],[65514,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [65515,16],[65516,16],[65517,16],[65518,16],[65519,16],[65520,16],[65521,16],[65522,16],[65523,16],[65524,16],[0,0],[0,0],[0,0],[0,0],[0,0],
        [2041,11],[65525,16],[65526,16],[65527,16],[65528,16],[65529,16],[65530,16],[65531,16],[65532,16],[65533,16],[65534,16],[0,0],[0,0],[0,0],[0,0],[0,0]
    ];
    static immutable ushort[2][256] UVAC_HT = [
        [0,2],[1,2],[4,3],[10,4],[24,5],[25,5],[56,6],[120,7],[500,9],[1014,10],[4084,12],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [11,4],[57,6],[246,8],[501,9],[2038,11],[4085,12],[65416,16],[65417,16],[65418,16],[65419,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [26,5],[247,8],[1015,10],[4086,12],[32706,15],[65420,16],[65421,16],[65422,16],[65423,16],[65424,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [27,5],[248,8],[1016,10],[4087,12],[65425,16],[65426,16],[65427,16],[65428,16],[65429,16],[65430,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [58,6],[502,9],[65431,16],[65432,16],[65433,16],[65434,16],[65435,16],[65436,16],[65437,16],[65438,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [59,6],[1017,10],[65439,16],[65440,16],[65441,16],[65442,16],[65443,16],[65444,16],[65445,16],[65446,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [121,7],[2039,11],[65447,16],[65448,16],[65449,16],[65450,16],[65451,16],[65452,16],[65453,16],[65454,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [122,7],[2040,11],[65455,16],[65456,16],[65457,16],[65458,16],[65459,16],[65460,16],[65461,16],[65462,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [249,8],[65463,16],[65464,16],[65465,16],[65466,16],[65467,16],[65468,16],[65469,16],[65470,16],[65471,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [503,9],[65472,16],[65473,16],[65474,16],[65475,16],[65476,16],[65477,16],[65478,16],[65479,16],[65480,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [504,9],[65481,16],[65482,16],[65483,16],[65484,16],[65485,16],[65486,16],[65487,16],[65488,16],[65489,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [505,9],[65490,16],[65491,16],[65492,16],[65493,16],[65494,16],[65495,16],[65496,16],[65497,16],[65498,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [506,9],[65499,16],[65500,16],[65501,16],[65502,16],[65503,16],[65504,16],[65505,16],[65506,16],[65507,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [2041,11],[65508,16],[65509,16],[65510,16],[65511,16],[65512,16],[65513,16],[65514,16],[65515,16],[65516,16],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],
        [16352,14],[65517,16],[65518,16],[65519,16],[65520,16],[65521,16],[65522,16],[65523,16],[65524,16],[65525,16],[0,0],[0,0],[0,0],[0,0],[0,0],
        [1018,10],[32707,15],[65526,16],[65527,16],[65528,16],[65529,16],[65530,16],[65531,16],[65532,16],[65533,16],[65534,16],[0,0],[0,0],[0,0],[0,0],[0,0]
    ];
    static immutable int[] YQT = [16,11,10,16,24,40,51,61,12,12,14,19,26,58,60,55,14,13,16,24,40,57,69,56,14,17,22,29,51,87,80,62,18,22,
    37,56,68,109,103,77,24,35,55,64,81,104,113,92,49,64,78,87,103,121,120,101,72,92,95,98,112,100,103,99];

    static immutable int[] UVQT = [17,18,24,47,99,99,99,99,18,21,26,66,99,99,99,99,24,26,56,99,99,99,99,99,47,66,99,99,99,99,99,99,
    99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99];

    static immutable float[] aasf = [ 1.0f * 2.828427125f, 1.387039845f * 2.828427125f, 1.306562965f * 2.828427125f, 1.175875602f * 2.828427125f,
    1.0f * 2.828427125f, 0.785694958f * 2.828427125f, 0.541196100f * 2.828427125f, 0.275899379f * 2.828427125f ];

    int row, col, i, k, subsample;
    float[64] fdtbl_Y, fdtbl_UV;
    ubyte[64] YTable, UVTable;

    if(!data || !width || !height || comp > 4 || comp < 1) {
        return 0;
    }

    quality = quality ? quality : 90;
    subsample = quality <= 90 ? 1 : 0;
    quality = quality < 1 ? 1 : quality > 100 ? 100 : quality;
    quality = quality < 50 ? 5000 / quality : 200 - quality * 2;

    for(i = 0; i < 64; ++i) {
        int uvti, yti = (YQT[i]*quality+50)/100;
        YTable[stbiw__jpg_ZigZag[i]] = cast(ubyte) (yti < 1 ? 1 : yti > 255 ? 255 : yti);
        uvti = (UVQT[i]*quality+50)/100;
        UVTable[stbiw__jpg_ZigZag[i]] = cast(ubyte) (uvti < 1 ? 1 : uvti > 255 ? 255 : uvti);
    }

    for(row = 0, k = 0; row < 8; ++row) {
        for(col = 0; col < 8; ++col, ++k) {
            fdtbl_Y[k]  = 1 / (YTable [stbiw__jpg_ZigZag[k]] * aasf[row] * aasf[col]);
            fdtbl_UV[k] = 1 / (UVTable[stbiw__jpg_ZigZag[k]] * aasf[row] * aasf[col]);
        }
    }

    // Write Headers
    {
        static immutable ubyte[] head0 = [ 0xFF,0xD8,0xFF,0xE0,0,0x10,'J','F','I','F',0,1,1,0,0,1,0,1,0,0,0xFF,0xDB,0,0x84,0 ];
        static immutable ubyte[] head2 = [ 0xFF,0xDA,0,0xC,3,1,0,2,0x11,3,0x11,0,0x3F,0 ];
        immutable ubyte[24] head1 = 
        [ 
            0xFF, 0xC0, 0, 0x11, 8, 
            cast(ubyte)(height>>8),
            cast(ubyte)(height),
            cast(ubyte)(width>>8),
            cast(ubyte)(width),
        3,1,cast(ubyte)(subsample?0x22:0x11),0,2,0x11,1,3,0x11,1,0xFF,0xC4,0x01,0xA2,0 ];


        s.func(s.context, head0.ptr, cast(int)head0.length);
        s.func(s.context, YTable.ptr, cast(int)YTable.length);
        stbiw__putc(s, 1);
        s.func(s.context, UVTable.ptr, cast(int)UVTable.length);
        s.func(s.context, head1.ptr, cast(int)head1.sizeof);
        s.func(s.context, (std_dc_luminance_nrcodes.ptr+1), cast(int)std_dc_luminance_nrcodes.length - 1);
        s.func(s.context, std_dc_luminance_values.ptr, cast(int)std_dc_luminance_values.length);
        stbiw__putc(s, 0x10); // HTYACinfo
        s.func(s.context, (std_ac_luminance_nrcodes.ptr+1), cast(int)std_ac_luminance_nrcodes.length-1);
        s.func(s.context, std_ac_luminance_values.ptr, cast(int)std_ac_luminance_values.length);
        stbiw__putc(s, 1); // HTUDCinfo
        s.func(s.context, (std_dc_chrominance_nrcodes.ptr+1), cast(int)std_dc_chrominance_nrcodes.length-1);
        s.func(s.context, std_dc_chrominance_values.ptr, cast(int)std_dc_chrominance_values.length);
        stbiw__putc(s, 0x11); // HTUACinfo
        s.func(s.context, (std_ac_chrominance_nrcodes.ptr+1), cast(int)std_ac_chrominance_nrcodes.length-1);
        s.func(s.context, std_ac_chrominance_values.ptr, cast(int)std_ac_chrominance_values.length);
        s.func(s.context, head2.ptr, cast(int) head2.length);
    }

    // Encode 8x8 macroblocks
    {
        static immutable ushort[2] fillBits = [0x7F, 7];
        int DCY=0, DCU=0, DCV=0;
        int bitBuf=0, bitCnt=0;
        // comp == 2 is grey+alpha (alpha is ignored)
        int ofsG = comp > 2 ? 1 : 0, ofsB = comp > 2 ? 2 : 0;
        const(ubyte)* dataR = cast(const(ubyte)*)data;
        const(ubyte)* dataG = dataR + ofsG;
        const(ubyte)* dataB = dataR + ofsB;
        int x, y, pos;
        if(subsample) {
            for(y = 0; y < height; y += 16) {
                for(x = 0; x < width; x += 16) {
                    float[256] Y = void;
                    float[256] U = void;
                    float[256] V = void;
                    for(row = y, pos = 0; row < y+16; ++row) {
                        // row >= height => use last input row
                        int clamped_row = (row < height) ? row : height - 1;
                        int base_p = (stbi__flip_vertically_on_write ? (height-1-clamped_row) : clamped_row)*width*comp;
                        for(col = x; col < x+16; ++col, ++pos) {
                            // if col >= width => use pixel from last input column
                            int p = base_p + ((col < width) ? col : (width-1))*comp;
                            float r = dataR[p], g = dataG[p], b = dataB[p];
                            Y[pos]= +0.29900f*r + 0.58700f*g + 0.11400f*b - 128;
                            U[pos]= -0.16874f*r - 0.33126f*g + 0.50000f*b;
                            V[pos]= +0.50000f*r - 0.41869f*g - 0.08131f*b;
                        }
                    }
                    DCY = stbiw__jpg_processDU(s, &bitBuf, &bitCnt, Y.ptr+0,   16, fdtbl_Y.ptr, DCY, YDC_HT.ptr, YAC_HT.ptr);
                    DCY = stbiw__jpg_processDU(s, &bitBuf, &bitCnt, Y.ptr+8,   16, fdtbl_Y.ptr, DCY, YDC_HT.ptr, YAC_HT.ptr);
                    DCY = stbiw__jpg_processDU(s, &bitBuf, &bitCnt, Y.ptr+128, 16, fdtbl_Y.ptr, DCY, YDC_HT.ptr, YAC_HT.ptr);
                    DCY = stbiw__jpg_processDU(s, &bitBuf, &bitCnt, Y.ptr+136, 16, fdtbl_Y.ptr, DCY, YDC_HT.ptr, YAC_HT.ptr);

                    // subsample U,V
                    {
                        float[64] subU = void;
                        float[64] subV = void;
                        int yy, xx;
                        for(yy = 0, pos = 0; yy < 8; ++yy) {
                            for(xx = 0; xx < 8; ++xx, ++pos) {
                                int j = yy*32+xx*2;
                                subU[pos] = (U[j+0] + U[j+1] + U[j+16] + U[j+17]) * 0.25f;
                                subV[pos] = (V[j+0] + V[j+1] + V[j+16] + V[j+17]) * 0.25f;
                            }
                        }
                        DCU = stbiw__jpg_processDU(s, &bitBuf, &bitCnt, subU.ptr, 8, fdtbl_UV.ptr, DCU, UVDC_HT.ptr, UVAC_HT.ptr);
                        DCV = stbiw__jpg_processDU(s, &bitBuf, &bitCnt, subV.ptr, 8, fdtbl_UV.ptr, DCV, UVDC_HT.ptr, UVAC_HT.ptr);
                    }
                }
            }
        } else {
            for(y = 0; y < height; y += 8) {
                for(x = 0; x < width; x += 8) {
                    float[64] Y = void;
                    float[64] U = void;
                    float[64] V = void;                    
                    for(row = y, pos = 0; row < y+8; ++row) {
                        // row >= height => use last input row
                        int clamped_row = (row < height) ? row : height - 1;
                        int base_p = (stbi__flip_vertically_on_write ? (height-1-clamped_row) : clamped_row)*width*comp;
                        for(col = x; col < x+8; ++col, ++pos) {
                            // if col >= width => use pixel from last input column
                            int p = base_p + ((col < width) ? col : (width-1))*comp;
                            float r = dataR[p], g = dataG[p], b = dataB[p];
                            Y[pos]= +0.29900f*r + 0.58700f*g + 0.11400f*b - 128;
                            U[pos]= -0.16874f*r - 0.33126f*g + 0.50000f*b;
                            V[pos]= +0.50000f*r - 0.41869f*g - 0.08131f*b;
                        }
                    }

                    DCY = stbiw__jpg_processDU(s, &bitBuf, &bitCnt, Y.ptr, 8, fdtbl_Y.ptr,  DCY, YDC_HT.ptr, YAC_HT.ptr);
                    DCU = stbiw__jpg_processDU(s, &bitBuf, &bitCnt, U.ptr, 8, fdtbl_UV.ptr, DCU, UVDC_HT.ptr, UVAC_HT.ptr);
                    DCV = stbiw__jpg_processDU(s, &bitBuf, &bitCnt, V.ptr, 8, fdtbl_UV.ptr, DCV, UVDC_HT.ptr, UVAC_HT.ptr);
                }
            }
        }

        // Do the bit alignment of the EOI marker
        stbiw__jpg_writeBits(s, &bitBuf, &bitCnt, fillBits.ptr);
    }

    // EOI
    stbiw__putc(s, 0xFF);
    stbiw__putc(s, 0xD9);

    return 1;
}

public int stbi_write_jpg_to_func(stbi_write_func func, void *context, int x, int y, int comp, const(void) *data, int quality)
{
    stbi__write_context s;
    stbi__start_write_callbacks(&s, func, context);
    return stbi_write_jpg_core(&s, x, y, comp, cast(void *) data, quality); // const_cast here
}


/* Revision history
      1.16  (2021-07-11)
             make Deflate code emit uncompressed blocks when it would otherwise expand
             support writing BMPs with alpha channel
      1.15  (2020-07-13) unknown
      1.14  (2020-02-02) updated JPEG writer to downsample chroma channels
      1.13
      1.12
      1.11  (2019-08-11)

      1.10  (2019-02-07)
             support utf8 filenames in Windows; fix warnings and platform ifdefs
      1.09  (2018-02-11)
             fix typo in zlib quality API, improve STB_I_W_STATIC in C++
      1.08  (2018-01-29)
             add stbi__flip_vertically_on_write, external zlib, zlib quality, choose PNG filter
      1.07  (2017-07-24)
             doc fix
      1.06 (2017-07-23)
             writing JPEG (using Jon Olick's code)
      1.05   ???
      1.04 (2017-03-03)
             monochrome BMP expansion
      1.03   ???
      1.02 (2016-04-02)
             avoid allocating large structures on the stack
      1.01 (2016-01-16)
             STBIW_REALLOC_SIZED: support allocators with no realloc support
             avoid race-condition in crc initialization
             minor compile issues
      1.00 (2015-09-14)
             installable file IO function
      0.99 (2015-09-13)
             warning fixes; TGA rle support
      0.98 (2015-04-08)
             added STBIW_MALLOC, STBIW_ASSERT etc
      0.97 (2015-01-18)
             fixed HDR asserts, rewrote HDR rle logic
      0.96 (2015-01-17)
             add HDR output
             fix monochrome BMP
      0.95 (2014-08-17)
             add monochrome TGA output
      0.94 (2014-05-31)
             rename private functions to avoid conflicts with stb_image.h
      0.93 (2014-05-27)
             warning fixes
      0.92 (2010-08-01)
             casts to unsigned char to fix warnings
      0.91 (2010-07-17)
             first public release
      0.90   first internal release
*/

/*
------------------------------------------------------------------------------
This software is available under 2 licenses -- choose whichever you prefer.
------------------------------------------------------------------------------
ALTERNATIVE A - MIT License
Copyright (c) 2017 Sean Barrett
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
------------------------------------------------------------------------------
ALTERNATIVE B - Public Domain (www.unlicense.org)
This is free and unencumbered software released into the public domain.
Anyone is free to copy, modify, publish, use, compile, sell, or distribute this
software, either in source code form or as a compiled binary, for any purpose,
commercial or non-commercial, and by any means.
In jurisdictions that recognize copyright laws, the author or authors of this
software dedicate any and all copyright interest in the software to the public
domain. We make this dedication for the benefit of the public at large and to
the detriment of our heirs and successors. We intend this dedication to be an
overt act of relinquishment in perpetuity of all present and future rights to
this software under copyright law.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
------------------------------------------------------------------------------
*/
