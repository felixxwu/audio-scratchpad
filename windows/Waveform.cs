// Reads recordings back, and reduces them to a short list of loudness values, one for each bar of the drawn waveform.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

// Holds a recording's loudness as it grows, merging older values so redrawing stays quick however long it runs.
sealed class LoudnessHistory
{
    readonly List<float> values = new List<float>();
    int reportsPerValue = 1;
    int pendingReports;

    public float[] Values { get { return values.ToArray(); } }

    public void Append(float value, int bars = 400)
    {
        if (pendingReports == 0) values.Add(value);
        else values[values.Count - 1] = Math.Max(values[values.Count - 1], value);
        pendingReports++;
        if (pendingReports < reportsPerValue) return;
        pendingReports = 0;
        if (values.Count < bars * 2) return;
        for (int i = 0; i < values.Count / 2; i++) values[i] = Math.Max(values[i * 2], values[i * 2 + 1]);
        values.RemoveRange(values.Count / 2, values.Count / 2);
        reportsPerValue *= 2;
    }
}

static class Waveform
{
    sealed class Wav
    {
        public int Channels, SampleRate, Bits, Tag;
        public long DataStart, DataBytes;
    }

    static Wav ReadHeader(BinaryReader r)
    {
        var s = r.BaseStream;
        if (Encoding.ASCII.GetString(r.ReadBytes(4)) != "RIFF") throw new InvalidDataException("Not a WAV file");
        s.Position = 12;
        var wav = new Wav();
        while (s.Position + 8 <= s.Length)
        {
            string id = Encoding.ASCII.GetString(r.ReadBytes(4));
            long size = r.ReadUInt32();
            long next = s.Position + size + (size & 1);
            if (id == "fmt ")
            {
                wav.Tag = r.ReadInt16();
                wav.Channels = r.ReadInt16();
                wav.SampleRate = r.ReadInt32();
                r.ReadBytes(6);
                wav.Bits = r.ReadInt16();
            }
            else if (id == "data")
            {
                if (wav.Channels <= 0 || wav.SampleRate <= 0 || wav.Bits <= 0) throw new InvalidDataException("WAV has no format");
                wav.DataStart = s.Position;
                wav.DataBytes = Math.Min(size, s.Length - s.Position);
                return wav;
            }
            s.Position = next;
        }
        throw new InvalidDataException("WAV has no audio");
    }

    static BinaryReader Open(string path)
    {
        return new BinaryReader(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete));
    }

    public static double Duration(string path)
    {
        using (var r = Open(path))
        {
            var wav = ReadHeader(r);
            return (double)wav.DataBytes / (wav.Channels * wav.Bits / 8) / wav.SampleRate;
        }
    }

    public static float[] Peaks(string path, int bars = 400)
    {
        var peaks = new float[bars];
        using (var r = Open(path))
        {
            var wav = ReadHeader(r);
            if (wav.Tag != 3 || wav.Bits != 32) throw new InvalidDataException("Only 32-bit float WAV files are drawn");
            long total = wav.DataBytes / 4 / wav.Channels;
            if (total == 0) return peaks;

            r.BaseStream.Position = wav.DataStart;
            var bytes = new byte[65536 * 4 * wav.Channels];
            var samples = new float[bytes.Length / 4];
            long position = 0;
            while (position < total)
            {
                int read = r.Read(bytes, 0, (int)Math.Min(bytes.Length, (total - position) * 4 * wav.Channels));
                int frames = read / 4 / wav.Channels;
                if (frames == 0) break;
                Buffer.BlockCopy(bytes, 0, samples, 0, frames * 4 * wav.Channels);
                for (int frame = 0; frame < frames; frame++)
                {
                    int bar = (int)Math.Min(bars - 1, (position + frame) * bars / total);
                    for (int channel = 0; channel < wav.Channels; channel++)
                        peaks[bar] = Math.Max(peaks[bar], Math.Abs(samples[frame * wav.Channels + channel]));
                }
                position += frames;
            }
        }
        return Fit(peaks, bars);
    }

    // Squeezes loudness values into at most `bars`, scaled to the loudest so quiet audio is still readable.
    public static float[] Fit(float[] values, int bars = 400)
    {
        var fitted = (float[])values.Clone();
        if (values.Length > bars)
        {
            fitted = new float[bars];
            for (int i = 0; i < values.Length; i++)
            {
                int bar = (int)((long)i * bars / values.Length);
                fitted[bar] = Math.Max(fitted[bar], values[i]);
            }
        }
        float loudest = fitted.Length > 0 ? fitted.Max() : 0;
        return loudest > 0 ? fitted.Select(v => v / loudest).ToArray() : fitted;
    }
}
