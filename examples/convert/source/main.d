module main;

import std.stdio;
import std.file;
import std.format;
import gamut;
import consolecolors;

void usage()
{
    writeln("Convert image from one format to another.");
    writeln;
    writeln("Usage: convert input.ext output.ext [-bitness {8|16|auto}]\n");
    writeln;
    writeln("Params:");
    writeln("  -i           Specify an input file");
    writeln("  --grey       Convert to greyscale before encoding");
    writeln("  --rgb        Convert to RGB before encoding");
    writeln("  --alpha      Force alpha channel before encoding");
    writeln("  --drop-alpha Drop alpha channel before encoding");
    writeln("  -f/--flag    Specify encode flags to Gamut (eg: --flag ENCODE_SQZ_QUALITY_BPP1_5)");
    writeln("  -b/--bitness Change bitness of file");
    writeln("  -p/--premul  Encode with premultiplied alpha (if any alpha)");
    writeln("  --unpremul   Encode with unpremultiplied alpha");
    writeln("  -h           Shows this help");
    writeln;
}

int main(string[] args)
{
    try
    {
        string input = null;
        string output = null;
        bool help = false;
        bool premul = false;
        bool unpremul = false;
        bool forceGrey = false;
        bool forceRgb = false;
        bool forceAlpha = false;
        bool forceNoAlpha = false;
        int bitness = -1; // auto

        assert(ENCODE_NORMAL == 0);
        int encodeFlags = ENCODE_NORMAL;


        for(int i = 1; i < args.length; ++i)
        {
            string arg = args[i];
            if (arg == "-b" || arg == "--bitness")
            {
                ++i;
                if (args[i] == "8") bitness = 8;
                else if (args[i] == "16") bitness = 16;
                else if (args[i] == "auto") bitness = -1;
                else throw new Exception("Must specify 8, 16, or auto after -bitness");
            }
            else if (arg == "-p" || arg == "--premul")
            {
                premul = true;
            }
            else if (arg == "--unpremul")
            {
                unpremul = true;
            }
            else if (arg == "-h")
            {
                help = true;
            }
            else if (arg == "--grey")
            {
                forceGrey = true;
            }
            else if (arg == "--rgb")
            {
                forceRgb = true;
            }
            else if (arg == "--alpha")
            {
                forceAlpha = true;
            }
            else if (arg == "--drop-alpha")
            {
                forceNoAlpha = true;
            }
            else if (arg == "-f" || arg == "--flag")
            {
                ++i;
                encodeFlags |= convertEncodeFlagStringToValue(args[i]);
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

        if (forceRgb && forceGrey)
            throw new Exception("Can't use --grey and --rgb at the same time");

        if (forceAlpha && forceNoAlpha)
            throw new Exception("Can't use --alpha and --drop-alpha at the same time");

        if (help || input is null || output is null)
        {
            usage();
            return 0;
        }

        Image image;
        Image* result = &image;

        image.loadFromFile(input, LAYOUT_VERT_STRAIGHT | LAYOUT_GAPLESS);

      


        if (image.isError)
        {
            throw new Exception("Couldn't open file " ~ input);
        }

  
        if (bitness == 8)
            image.convertTo8Bit();
        else if (bitness == 16)
            image.convertTo16Bit();

        if (forceRgb)
            image.convertToRGB();
        else if (forceGrey)
            image.convertToGreyscale();

        if (forceAlpha)
            image.addAlphaChannel();
        else if (forceNoAlpha)
            image.dropAlphaChannel();

        if (premul && unpremul) throw new Exception("Cannot have both --premul and --unpremul");
        if (premul) image.premultiply();
        if (unpremul) image.unpremultiply();

        // TODO: SQZ encoder doesn't support any other layout yet
        image.setLayout(LAYOUT_VERT_STRAIGHT | LAYOUT_GAPLESS);

        bool r = result.saveToFile(output, encodeFlags);
        if (!r)
        {
            throw new Exception("Couldn't save file " ~ output);
        }

        string fileSize(const(char)[] path)
        {
            long bytes = getSize(path);
            if (bytes < 1024)
                return format("%4s  B", bytes);
            else if (bytes < 1024 * 1024)
                return format("%4s kB", bytes / 1024);
            else
                return format("%4s MB", bytes / (1024*1024));
        }

        cwritef("<lcyan>%20s (<yellow>%s</yellow>)</lcyan>", input, fileSize(input));
        cwritef(" encoded to ");
        cwritef("<lgreen>%20s (<yellow>%s</yellow>, %s)</lgreen>\n", output, fileSize(output), image.type);

        return 0;
    }
    catch(Exception e)
    {
        writefln("error: %s", e.message);
        usage();
        return 1;
    }
}


int convertEncodeFlagStringToValue(string s)
{
    if (s in allEncodeFlags)
        return allEncodeFlags[s];
    else
        throw new Exception("Unknown encode flag: " ~ s);
}

// Note: keep in sync with types.d

enum allEncodeFlags = buildEncodeFlags();

int[string] buildEncodeFlags()
{
    int[string] flags = 
    [
        "ENCODE_NORMAL": 0,
        
        "ENCODE_PNG_COMPRESSION_DEFAULT": 0,
        "ENCODE_PNG_COMPRESSION_FAST":    2,
        "ENCODE_PNG_COMPRESSION_SMALL":  10,

        "ENCODE_PNG_COMPRESSION_0":       1,
        "ENCODE_PNG_COMPRESSION_1":       2,
        "ENCODE_PNG_COMPRESSION_2":       3,
        "ENCODE_PNG_COMPRESSION_3":       4,
        "ENCODE_PNG_COMPRESSION_4":       5,
        "ENCODE_PNG_COMPRESSION_5":       6,
        "ENCODE_PNG_COMPRESSION_6":       7,
        "ENCODE_PNG_COMPRESSION_7":       8,
        "ENCODE_PNG_COMPRESSION_8":       9,
        "ENCODE_PNG_COMPRESSION_9":       10,
        "ENCODE_PNG_COMPRESSION_10":      11,

        "ENCODE_PNG_FILTER_DEFAULT":      0,
        "ENCODE_PNG_FILTER_SMALL":        0,
        "ENCODE_PNG_FILTER_FAST":  (1 << 4),


        "ENCODE_SQZ_QUALITY_DEFAULT":         0, 
        "ENCODE_SQZ_QUALITY_BPP1_0":  0x20 << 5, 
        "ENCODE_SQZ_QUALITY_BPP1_25": 0x28 << 5, 
        "ENCODE_SQZ_QUALITY_BPP1_5":  0x30 << 5, 
        "ENCODE_SQZ_QUALITY_BPP1_75": 0x38 << 5, 
        "ENCODE_SQZ_QUALITY_BPP2_0":  0x40 << 5, 
        "ENCODE_SQZ_QUALITY_BPP2_25": 0x48 << 5, 
        "ENCODE_SQZ_QUALITY_BPP2_5":  0x50 << 5, // if you want to beat guetzli this is alright
        "ENCODE_SQZ_QUALITY_BPP2_75": 0x58 << 5, 
        "ENCODE_SQZ_QUALITY_MAX":     0xff << 5,
    ];
    return flags;
}
      