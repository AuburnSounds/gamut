module main;

import core.stdc.stdlib;
import core.stdc.stdio;
import core.stdc.string;
//import std.stdio;
//import std.file;
import gamut;
import gamut.codecs.stbdec;

void main(string[] args)
{ 
    testDecodingVSTLogo();
    testIssue35();
    testIssue46();
    //testReallocSpeed();
    testCGBI();
    testDecodingGIF();
    testIssue63();
    testIssue65();
    testIssue67();
    testIssue77();
    testImageFmtCompat();
    testExtremePNGLevel();
}

void testIssue35()
{
    Image image;
    image.loadFromFile("test-images/issue35.jpg", LOAD_RGB | LOAD_8BIT | LOAD_ALPHA | LAYOUT_VERT_STRAIGHT | LAYOUT_GAPLESS);
    assert(image.layers == 1);
    assert(!image.isError);
    image.saveToFile("output/issue35.png");
}

// should not fail while loading an empty file, and report an error instead
void testIssue46()
{
    Image image;
    image.loadFromFile("test-images/issue46.jpg");
    assert(image.isError);

    image.loadFromFile("test-images/issue35.jpg");
    assert(!image.isError);

    image.loadFromFile("test-images/issue46.jpg");
    assert(image.isError);
}

void testDecodingVSTLogo()
{
    Image image;
    image.loadFromFile("test-images/vst3-compatible.png");
    assert(!image.isError);

    // Test decoding of first problem chunk in the image
    char[] bytes = cast(char[]) readFile("test-images/buggy-miniz-chunk.bin".ptr);
    assert(bytes.length == 25568);

    // initial_size is 594825, but more is returned by inflate, 594825 + 272 with both miniz and stbz
    // with stb_image, buffer is extended. But Miniz doesn't seem to support that, so we extend it externally.

    int initial_size = 594825;
    int outlen;
    ubyte* buf = stbi_zlib_decode_malloc_guesssize_headerflag(bytes.ptr, 25568, initial_size, &outlen, 1);
    assert(buf !is null);
    assert(outlen == 594825 + 272);
    free(buf);
}

void testCGBI()
{
    // Load an iPhone PNG, saves a normal PNG
    Image image;
    image.loadFromFile("test-images/issue51cgbi.png");
    assert(!image.isError);
    image.saveToFile("output/issue51cbgi.png");

    image.loadFromFile("test-images/issue51cgbi2.png");
    assert(!image.isError);
    image.saveToFile("output/issue51cbgi2.png");
}

void testDecodingGIF()
{
    Image image;
    image.loadFromFile("test-images/animated_loop.gif");
    assert(image.layers == 4);

    // This particular GIF has no pixel ratio information
    assert(image.pixelAspectRatio() == GAMUT_UNKNOWN_ASPECT_RATIO);

    // GIF doesn't have resolution information.
    assert(image.dotsPerInchX() == GAMUT_UNKNOWN_RESOLUTION);
    assert(image.dotsPerInchY() == GAMUT_UNKNOWN_RESOLUTION);

    image.layer(0).saveToFile("output/animated_loop_frame0.png");
    image.layer(1).saveToFile("output/animated_loop_frame1.png");
    image.layer(2).saveToFile("output/animated_loop_frame2.png");
    image.layer(3).saveToFile("output/animated_loop_frame3.png");
}

void testIssue63()
{
    const int w = 16;
    const int h = 16;
    enum scale = 16;
    const int frames = 1;
    size_t frameBytes = 4 * w * h;
    size_t numPixels = w*h;
    ubyte[4]* img = cast(ubyte[4]*) malloc(frameBytes);
    foreach (ubyte x; 0 .. w)
    {
        foreach (ubyte y; 0 .. h)
        {
            img[y * w + x] = [cast(ubyte)(scale * x), 
                              cast(ubyte)(scale * y), 
                              0, 
                              255];
        }
    }
    ubyte[4]* gif = cast(ubyte[4]*) malloc(frameBytes * frames);
    foreach (i; 0 .. frames)
        gif[numPixels*i .. numPixels*(i+1)] = img[0..numPixels];

    Image image;
    int pitchInBytes     = w * 4;
    int layerOffsetBytes = w * h * 4;

    image.createLayeredView(cast(void*) gif, w, h, frames, PixelType.rgba8,
                            pitchInBytes, layerOffsetBytes);
    image.saveToFile("output/issue63.gif");
}

// See: https://github.com/AuburnSounds/gamut/issues/65
void testIssue65()
{
    Image img;
    if (!img.loadFromFile("test-images/issue65.png", LOAD_FP32 | LOAD_GREYSCALE))
        throw new Exception(img.errorMessage().mallocIDup);
    assert(img.hasData);
    assert(img.isValid);
    if (!img.isValid)
        throw new Exception(img.errorMessage().mallocIDup);
    assert(img.hasData);
    assert(img.isValid);
    if (!img.setLayout(LAYOUT_TRAILING_1))
        throw new Exception(img.errorMessage().mallocIDup);

    if (!img.setLayout(LAYOUT_TRAILING_0)) // <-- assert fails here
        throw new Exception(img.errorMessage().mallocIDup);
    assert(img.hasData);
    if (!img.convertTo8Bit()) // <-- or here if the above setLayout isn't there
        throw new Exception(img.errorMessage().mallocIDup);
    assert(img.hasData);
    if (!img.saveToFile("output/decoded.png")) // <-- this wouldn't assert fail, but it just emits an empty file with error set
        throw new Exception(img.errorMessage().mallocIDup);
}

void testIssue67()
{
    import core.math: fabs;
    Image img;
    if (!img.loadFromFile("test-images/issue67.bmp"))
        throw new Exception(img.errorMessage().mallocIDup);
    assert(fabs(img.dotsPerInchX() - 200) < 0.1);
    assert(fabs(img.dotsPerInchY() - 100) < 0.1);
    assert(fabs(img.pixelAspectRatio() - 2) < 0.01);
}

void testIssue76()
{
    Image img;
    if (!img.loadFromFile("test-images/issue76.png"))
        throw new Exception(img.errorMessage().mallocIDup);
    // Should load as greyscale L16
    assert(img.isValid);
    assert(img.type == PixelType.l16);
    // Should be 2x2
    assert(img.width == 2 && img.height == 2);
    ushort[] scan0 = cast(ushort[]) img.scanline(0);
    ushort[] scan1 = cast(ushort[]) img.scanline(1);
    assert(scan0.length == 2);
    assert(scan1.length == 2);
    assert(scan0[0] == 1875);
    assert(scan0[1] == 65535);
    assert(scan1[0] == 0);
    assert(scan1[1] == 2807);
}

void testImageFmtCompat()
{
    IFImage img = read_image("test-images/issue67.bmp");
    assert(img.e == 0);
    assert(img.w == 32);
    assert(img.h == 32);
    img.free();

    ubyte[36] greySmiley = 
    [  0, 255, 255, 255, 255,   0,
     255, 255,   0,   0, 255, 255,
     255,   0, 255, 255,   0, 255,
     255,   0,   0,   0,   0, 255,
     255, 255,   0,   0, 255, 255,
       0, 255, 255, 255, 255,   0 ];
    ubyte e = write_image("temp.png", 6, 6, greySmiley, 1);
    assert(e == 0);
    IFInfo info = read_info("temp.png");
    assert(info.w == 6);
    assert(info.h == 6);
    assert(info.c == 1);
}

void testIssue77()
{
    Image image;
    image.loadFromFile("test-images/vst3-compatible.png");
    image.convertTo(PixelType.rgb8, LAYOUT_VERT_FLIPPED | LAYOUT_BORDER_3);
    assert(image.saveToFile("temp.jpg"));
}

void testExtremePNGLevel()
{
    Image image;
    image.loadFromFile("test-images/issue51cgbi2.png");

    // check some encodes
    assert(image.saveToFile("qfast.png", ENCODE_PNG_COMPRESSION_FAST | ENCODE_PNG_FILTER_FAST));
    assert(image.saveToFile("qsmall.png", ENCODE_PNG_COMPRESSION_SMALL));
    assert(image.saveToFile("q0.png", ENCODE_PNG_COMPRESSION_0));
    assert(image.saveToFile("q10.png", ENCODE_PNG_COMPRESSION_10));
    image.loadFromFile("q0.png");
    assert(image.isValid);
    image.loadFromFile("qsmall.png");
    assert(image.isValid);
    image.loadFromFile("q10.png");
    assert(image.isValid);
    image.loadFromFile("qfast.png");
    assert(image.isValid);
}

/+
void testReallocSpeed()
{
    Clock a;
    a.initialize();

    Image image;


    long testRealloc(long delegate(int i) pure nothrow @nogc @safe getWidth, long delegate(int i) getHeight)
    {
        long before = a.getTickUs();
        foreach(n; 0..100)
        {
            foreach(i; 0..256)
            {
                int width  = cast(int) getWidth(cast(int)i);
                int height = cast(int) getHeight(cast(int)i);
                image.setStorage(width, height,PixelType.rgba8, 0, false);
            }
        }
        long after = a.getTickUs();
        return after - before;
    }

    writefln("image sizing with fixed      size = %s", testRealloc( i => 256, 
                                                                    j => 256 ) );
    writefln("image sizing with increasing size = %s", testRealloc( i => 1 + i, 
                                                                    j => 1 + j ) );
    writefln("image sizing with decreasing size = %s", testRealloc( (int j){ return (256 - j); }, 
                                                                    (int j){ return (256 - j); } ));
    writefln("image sizing with random     size = %s", testRealloc( (int i){ return 1 + ((i * cast(long)24986598365983) & 255); }, 
                                                                    (int i){ return 1 + ((i * cast(long)24986598421) & 255); } ));


}
+/

version(Windows)
{
    import core.sys.windows.windows;
}


struct Clock
{
    nothrow @nogc:

    void initialize()
    {
        version(Windows)
        {
            QueryPerformanceFrequency(&_qpcFrequency);
        }
    }

    /// Get us timestamp.
    /// Must be thread-safe.
    // It doesn't handle wrap-around superbly.
    long getTickUs() nothrow @nogc
    {
        version(Windows)
        {
            import core.sys.windows.windows;
            LARGE_INTEGER lint;
            QueryPerformanceCounter(&lint);
            double seconds = lint.QuadPart / cast(double)(_qpcFrequency.QuadPart);
            long us = cast(long)(seconds * 1_000_000);
            return us;
        }
        else
        {
            import core.time;
            return convClockFreq(MonoTime.currTime.ticks, MonoTime.ticksPerSecond, 1_000_000);
        }
    }

private:
    version(Windows)
    {
        LARGE_INTEGER _qpcFrequency;
    }
}


ubyte[] readFile(const(char)[] fileNameZ)
{
    // assuming that fileNameZ is zero-terminated, since it will in practice be
    // a static string
    FILE* file = fopen(assumeZeroTerminated(fileNameZ), "rb".ptr);
    if (file)
    {
        scope(exit) fclose(file);

        // finds the size of the file
        fseek(file, 0, SEEK_END);
        long size = ftell(file);
        fseek(file, 0, SEEK_SET);

        // Is this too large to read? 
        // Refuse to read more than 1gb file (if it happens, it's probably a bug).
        if (size > 1024*1024*1024)
            return null;

        // Read whole file in a mallocated slice
        ubyte[] fileBytes = mallocSliceNoInit!ubyte(cast(int)size + 1); // room for one additional '\0' byte
        size_t remaining = cast(size_t)size;

        ubyte* p = fileBytes.ptr;

        while (remaining > 0)
        {
            size_t bytesRead = fread(p, 1, remaining, file);
            if (bytesRead == 0)
            {
                freeSlice(fileBytes);
                return null;
            }
            p += bytesRead;
            remaining -= bytesRead;
        }

        fileBytes[cast(size_t)size] = 0;

        return fileBytes[0..cast(size_t)size];
    }
    else
        return null;
}
ubyte[] readFile(const(char)* fileNameZ)
{
    import core.stdc.string: strlen;
    return readFile(fileNameZ[0..strlen(fileNameZ)]);
}
T[] mallocDup(T)(const(T)[] slice) nothrow @nogc if (!is(T == struct))
{
    T[] copy = mallocSliceNoInit!T(slice.length);
    memcpy(copy.ptr, slice.ptr, slice.length * T.sizeof);
    return copy;
}

immutable(T)[] mallocIDup(T)(const(T)[] slice) nothrow @nogc if (!is(T == struct))
{
    return cast(immutable(T)[]) mallocDup!T(slice);
}


/// Allocates a slice with `malloc`, but does not initialize the content.
T[] mallocSliceNoInit(T)(size_t count) nothrow @nogc
{
    T* p = cast(T*) malloc(count * T.sizeof);
    return p[0..count];
}

const(char)* assumeZeroTerminated(const(char)[] input) nothrow @nogc
{
    if (input.ptr is null)
        return null;

    // Check that the null character is there
    assert(input.ptr[input.length] == '\0');
    return input.ptr;
}

/// Frees a slice allocated with `mallocSlice`.
void freeSlice(T)(const(T)[] slice) nothrow @nogc
{
    free(cast(void*)(slice.ptr)); // const cast here
}