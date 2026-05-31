module main;

import std.stdio;
import std.file;
import std.conv;
import std.path;
import std.string;
import std.algorithm;
import gamut;
import core.stdc.stdlib: free;
version(qoixStats) import gamut.codecs.qoi10b;
version(qoixStats) import gamut.codecs.qoiplane10;

void usage()
{
    writeln();
    writeln("Usage: qoix\n");
    writeln("   This just run the test suite. Used to optimize one format in either speed or compression.");
    writeln;
}

int main(string[] args)
{    
    auto files = filter!`endsWith(a.name,".png") || endsWith(a.name,".jpg") || endsWith(a.name,".jxl")`(dirEntries("test-images",SpanMode.depth));

    double mean_encode_mpps = 0;
    double mean_decode_mpps = 0;
    double mean_bpp = 0;

    long timeStart = getTickUs();

    int N = 0;
    foreach(f; files)
    {
        writeln();

        ubyte[] originalImage = cast(ubyte[]) std.file.read(f);

        double original_size_kb = originalImage.length / 1024.0;
        writef("*** image of size %.1f kb: %s", original_size_kb, f);

        Image image;
        double orig_decode_ms = measure( { image.loadFromMemory(originalImage); } );
        if (image.isError)
            throw new Exception(to!string(image.errorMessage));

        // Always test the 10-bit plane codec: convert to greyscale (l16/la16).
        image.convertToGreyscale(); // -> l or la (preserves alpha if present)
        image.convertTo16Bit();     // -> l16 or la16
        image.setLayout(LAYOUT_GAPLESS | LAYOUT_VERT_STRAIGHT);

        int width = image.width;
        int height = image.height;

        if (image.isError)
            throw new Exception(to!string(image.errorMessage));

        writefln(" (%s)", image.type);

        ImageFormat codec = ImageFormat.QOIX;

        // Encode in a particular codec
        version(qoixStats) qoi10b_clear_stats();
        version(qoixStats) qoiplane10_clear_stats();
        ubyte[] encoded;
        double encode_ms = measure( { encoded = image.saveToMemory(codec); } );
        scope(exit) freeEncodedImage(encoded);

        if (encoded is null)
            throw new Exception("encoding failed");

        double size_kb = encoded.length / 1024.0;
        double decode_ms = measure( { image.loadFromMemory(encoded); } );
        double encode_mpps = (width * height * 1.0e-6) / (encode_ms * 0.001);
        double decode_mpps = (width * height * 1.0e-6) / (decode_ms * 0.001);
        double bit_per_pixel = (encoded.length * 8.0) / (width * height);

        mean_encode_mpps += encode_mpps;
        mean_decode_mpps += decode_mpps;
        mean_bpp += bit_per_pixel;
        double size_vs_original = size_kb / original_size_kb;

        writefln("    orig dec          decode      decode mpps   encode mpps      bit-per-pixel        size        reduction");
        writefln("  %8.2f ms      %8.2f ms       %8.2f      %8.2f           %8.5f     %9.1f kb  %9.4f", orig_decode_ms, decode_ms, decode_mpps, encode_mpps, bit_per_pixel, size_kb, size_vs_original);

        version(qoixStats)
        {
            long total_ops = qoiplane10_run + qoiplane10_adiff + qoiplane10_diff1 + qoiplane10_diff2
                + qoiplane10_diff3 + qoiplane10_diff4 + qoiplane10_la;
            writefln("  Opcodes (total=%d):", total_ops);
            writefln("    run=%d  adiff=%d qoiplane10_la=%d",
                     qoiplane10_run, qoiplane10_adiff, qoiplane10_la);
            writefln("    diff1=%d  diff2=%d  diff3=%d  diff4=%d",
                     qoiplane10_diff1, qoiplane10_diff2, qoiplane10_diff3, qoiplane10_diff4);
            double pct(long n) { return total_ops > 0 ? 100.0 * n / total_ops : 0.0; }
            writefln("    %%run=%.1f%%  %%diff1=%.1f%%  %%diff2=%.1f%%  %%diff3=%.1f%% %%diff4=%.1f%%",
                     pct(qoiplane10_run), pct(qoiplane10_diff1), pct(qoiplane10_diff2), pct(qoiplane10_diff3),  pct(qoiplane10_diff4));
        }
        


        N += 1;

        // To check visually if encoding is properly done.
        {
            Image image2;
            image2.loadFromMemory(encoded);
            assert(!image2.isError);

            string path = "output/" ~ baseName(f) ~ ".png";
            image2.saveToFile(path, ImageFormat.PNG);

            // Idempotency round-trip check: re-encoding the decoded image must
            // reproduce identical bytes. Catches bit-packing / predictor bugs.
            ubyte[] encoded2 = image2.saveToMemory(codec);
            scope(exit) freeEncodedImage(encoded2);
            if (encoded2 is null || encoded2.length != encoded.length
                || encoded2[] != encoded[])
            {
                throw new Exception("round-trip mismatch (codec not self-consistent) for " ~ to!string(f));
            }
        }
    }
    long timeTotal = getTickUs() - timeStart;
    mean_encode_mpps /= N;
    mean_decode_mpps /= N;
    mean_bpp /= N;
    writefln("\nTOTAL  decode mpps   encode mpps      bit-per-pixel");
    writefln("          %8.2f      %8.2f           %8.5f", mean_decode_mpps, mean_encode_mpps, mean_bpp);
   
    
    double totalSecs = timeTotal / 1000000.0;
    writefln("\nTOTAL  time = %s secs\n", totalSecs);

    return 0;
}

long getTickUs() nothrow @nogc
{
    import core.time;
    return convClockFreq(MonoTime.currTime.ticks, MonoTime.ticksPerSecond, 1_000_000);
}



double measure(void  delegate() nothrow @nogc dg) nothrow @nogc
{
    long A = getTickUs();
    dg();
    long B = getTickUs();
    return cast(double)( (B - A) / 1000.0 );
}