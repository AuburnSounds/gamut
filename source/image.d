/**
* In-memory Image type.
*
* Copyright: Copyright Guillaume Piolat 2021.
* License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamut.image;

nothrow @nogc @safe:

struct Image
{
nothrow @nogc @safe:
public:

    // This is the public API.
    // We do not use an `interface` because of -betterC.

    // By default, an Image is an invalid buffer since no data is pointed to.

    ~this()
    {
    }

    /// Image width in pixels.
    int width() pure
    {
        return _width;
    }

    /// Image height in pixels.
    int height() pure
    {
        return _height;
    }

    /// Number of channels.
    int numChannels() pure
    {
        return 4;
    }

    /// Number of bits per component.
    int bitsPerSample() pure
    {
        return 8;
    }


private:

    int _width = 0;  // Note: maximum width and height in gamut is 0x7fffffff.
    int _height = 0;

    /// Adress of the first meaningful pixel.
    void* _pixels;

    /// Row pitch in bytes.
    int _rowPitch;

    /// Address of the allocation/data itself
    void* _buffer = null;

    /// Size of left, top and bottom borders, around the meaningful area.
    int _border = 0;

    /// Size of border at the right of the meaningful area (most positive X).
    int _borderRight = 0;

    void* _userData;

    // Should it be here?
    //float pixelAspectRatio;
    //float DPIx; // if printed, how much DPI would the image have (eg: 300)
}

static assert(Image.sizeof <= 64);

