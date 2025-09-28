module main;

import std.conv;
import std.stdio;

import gamut;
import stb_image_resize2;

void usage()
{
    writeln("Resize image, for now this changes it to rgba8 though!");
    writeln;
    writeln("Usage: image-resize <input.ext> -w <width> -h <height> <output.ext>\n");
    writeln;
    writeln("Params:");   
    writeln("  -w               Set width (default: keep)");
    writeln("  -h               Set height  (default: keep)");
    writeln("  --help           Shows this help");
    writeln;
}


int main(string[] args)
{
    try
    {
        string inputPath = null;
        string outputPath = null;
        int w = -1; // -1 means "keep"
        int h = -1;
        bool help = false;

        for(int i = 1; i < args.length; ++i)
        {
            string arg = args[i];
            if (arg == "--help")
            {
                help = true;
            }
            else if (arg == "-w")
            {
                w = to!int(args[++i]);
            }
            else if (arg == "-h")
            {
                h = to!int(args[++i]);
            }
             else
            {
                if (inputPath)
                {
                    if (outputPath)
                        throw new Exception("Too many files provided");
                    else
                        outputPath = arg;
                }
                else
                    inputPath = arg;
            }
        }

        if (help || inputPath is null || outputPath is null)
        {
            usage();
            return 0;
        }

        Image inimg;
        inimg.loadFromFile(inputPath);
        if (inimg.isError)
            throw new Exception("Couldn't open file " ~ inputPath);

        inimg.convertTo8Bit();
        inimg.convertToRGB();
        inimg.addAlphaChannel();
        assert(inimg.type == PixelType.rgba8);

        writefln("Resize %s", inputPath);
        writefln(" - width      = %s", inimg.width);
        writefln(" - height     = %s", inimg.height);
        writefln(" - layers     = %s", inimg.layers);
        writefln(" - type       = %s", inimg.type);

        int targetW = (w == -1) ? inimg.width : w;
        int targetH = (h == -1) ? inimg.height : h;

        writefln("To: %s x %s pixels", targetW, targetH);

        Image outimg;
        outimg.create(targetW, targetH, PixelType.rgba8);


        void* res = stbir_resize(inimg.scanptr(0), inimg.width, inimg.height, inimg.pitchInBytes,
                                 outimg.scanptr(0), outimg.width, outimg.height, outimg.pitchInBytes,
                                 STBIR_RGBA,
                                 STBIR_TYPE_UINT8_SRGB,
                                 STBIR_EDGE_CLAMP,
                                 STBIR_FILTER_DEFAULT);

        assert(res);


    

        // resize

        bool r = outimg.saveToFile(outputPath);
        if (!r)
        {
            throw new Exception("Couldn't save file " ~ outputPath);
        }

        writefln(" => Written to %s", outputPath);
        return 0;
    }
    catch(Exception e)
    {
        writefln("error: %s", e.message);
        usage();
        return 1;
    }
}
