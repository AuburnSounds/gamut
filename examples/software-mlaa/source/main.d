module main;

import std.stdio;
import gamut;
import mlaa;

void usage()
{
    writeln("Apply MLAA on an image.");
    writeln;
    writeln("Usage: software-mlaa <input.ext> <output.ext>\n");
    writeln;
    writeln("Params:");
    writeln("  -h           Shows this help");
    writeln("  -edges       Output the detected edges instead (debug)");
    writeln;
}

// MLAA is a single-image post-process: the output only depends
// on the input image, there is no history buffer, no jitter
// and no motion vectors. It is not a temporal anti-aliasing.

// TODO: only works with 8-bit images.

int main(string[] args)
{
    try
    {
        string input = null;
        string output = null;
        bool help = false;
        bool showEdges = false;

        for(int i = 1; i < args.length; ++i)
        {
            string arg = args[i];
            if (arg == "-h")
            {
                help = true;
            }
            else if (arg == "-edges")
            {
                showEdges = true;
            }
            else
            {
                if (input)
                {
                    if (output)
                        throw new Exception("Too many files provided");
                    else
                        output = arg;
                }
                else
                    input = arg;
            }
        }

        if (help || input is null || output is null)
        {
            usage();
            return 0;
        }

        Image image;

        image.loadFromFile(input);

        if (image.isError)
        {
            throw new Exception("Couldn't open file " ~ input);
        }
        image.convertTo8Bit();
        image.convertToRGBA();

        writefln("Opened %s", input);
        writefln(" - width      = %s", image.width);
        writefln(" - height     = %s", image.height);
        writefln(" - layers     = %s", image.layers);
        writefln(" - type       = %s", image.type);

        int W = image.width;
        int H = image.height;

        Image outimg;
        outimg.create(W, H, PixelType.rgba8);

        mlaa_32bit(W,
                   H,
                   cast(const(ubyte)*) image.scanptr(0),
                   image.pitchInBytes(),
                   cast(ubyte*) outimg.scanptr(0),
                   outimg.pitchInBytes(),
                   showEdges);

        bool r = outimg.saveToFile(output);
        if (!r)
        {
            throw new Exception("Couldn't save file " ~ output);
        }

        writefln(" => Written to %s", output);
        return 0;
    }
    catch(Exception e)
    {
        writefln("error: %s", e.message);
        usage();
        return 1;
    }
}
