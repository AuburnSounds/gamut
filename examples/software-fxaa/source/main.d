module main;

import std.stdio;
import gamut;
import inteli.emmintrin;
import colors;
import core.stdc.stdio;
import core.stdc.stdlib;
import fxaa;

void usage()
{
    writeln("Apply FXAA on an image.");
    writeln;
    writeln("Usage: software-fxaa <input.ext> <output.ext>\n");
    writeln;
    writeln("Params:");   
    writeln("  -h           Shows this help");
    writeln;
}

// TODO: should use a border, or coord clamping,
//       instead of processing only the center part of an image
// TODO: this is basically a ported shader, however probably sampling
//       with something better than linear interp would be good.
// TODO: only works with 8-bit images.

enum ubyte most_significant_color_bits = 0xf0;



int main(string[] args)
{
    try
    {
        string input = null;
        string output = null;
        bool help = false;

        for(int i = 1; i < args.length; ++i)
        {
            string arg = args[i];
            if (arg == "-h")
            {
                help = true;
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

        image.loadFromFile(input, LAYOUT_TRAILING_3 | LAYOUT_BORDER_1);

        if (image.isError)
        {
            throw new Exception("Couldn't open file " ~ input);
        }
        image.convertTo8Bit();
        image.convertToRGB();
        image.addAlphaChannel();

        // TODO: above operations should preserve layout...
        image.setLayout(LAYOUT_TRAILING_3 | LAYOUT_BORDER_1 | LAYOUT_SCANLINE_ALIGNED_4);

        writefln("Opened %s", input);
        writefln(" - width      = %s", image.width);
        writefln(" - height     = %s", image.height);
        writefln(" - layers     = %s", image.layers);
        writefln(" - type       = %s", image.type);

        // MLAA
        int W = image.width;
        int H = image.height;

        Image outimg;
        outimg.create(image.width, image.height, PixelType.rgba8, LAYOUT_TRAILING_3 | LAYOUT_BORDER_1 | LAYOUT_SCANLINE_ALIGNED_4);

        ubyte* mask = cast(ubyte*) malloc( (W * H + 3) / 4 );
        mask[0 .. (W * H + 3) / 4] = 0; // so that everything updated

        fxaa_32bit(
                SW_FXAA_OFFS,
                H - SW_FXAA_OFFS,
                (SW_FXAA_OFFS) & 0xFFFFFFFC,
                (W - SW_FXAA_OFFS) &0xFFFFFFFC,
                W,
                image.pitchInBytes(),
                outimg.pitchInBytes(),
                H,
                cast(ubyte*) image.scanptr(0),
                cast(ubyte*) outimg.scanptr(0),
                mask);


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
