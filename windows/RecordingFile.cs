// Saves captured audio to a 32-bit float .wav, starting at the first non-zero sample and keeping pauses as silence.
using System;
using System.IO;
using System.Text;

sealed class RecordingFile : IDisposable
{
    public const int SampleRate = 48000;
    public const int Channels = 2;
    const int BytesPerFrame = Channels * 4;
    const int HeaderSize = 44;

    readonly string path;
    FileStream file;
    double? expectedTime;

    public bool HasStarted { get { return file != null; } }

    public RecordingFile(string path)
    {
        this.path = path;
    }

    // `samples` are interleaved, and `time` is when the first of them played, in seconds.
    public void Append(double time, float[] samples)
    {
        int startFrame = 0;
        if (file == null)
        {
            int first = Array.FindIndex(samples, s => s != 0);
            if (first < 0) return;
            startFrame = first / Channels;
            file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            WriteHeader(0);
        }

        time += (double)startFrame / SampleRate;
        // Capture skips time while an app is quiet, so the missing time is written back as silence.
        // Gaps under 10ms are ordinary timing jitter, and filling them would add clicks.
        if (expectedTime.HasValue && time - expectedTime.Value > 0.01)
            WriteSilence((long)Math.Round((time - expectedTime.Value) * SampleRate));

        int frames = samples.Length / Channels - startFrame;
        var bytes = new byte[frames * BytesPerFrame];
        Buffer.BlockCopy(samples, startFrame * BytesPerFrame, bytes, 0, bytes.Length);
        file.Write(bytes, 0, bytes.Length);
        expectedTime = time + (double)frames / SampleRate;

        // ponytail: WAV sizes are 32-bit, so a recording ends at about 3 hours; move to RF64 if that's ever too short.
        if (file.Length > uint.MaxValue - SampleRate * BytesPerFrame)
            throw new IOException("The recording reached the largest size a WAV file can hold.");
        // Kept current after every write, so a crash still leaves a playable file.
        WriteHeader(file.Length - HeaderSize);
    }

    void WriteSilence(long frames)
    {
        var silence = new byte[SampleRate * BytesPerFrame];
        for (long remaining = frames * BytesPerFrame; remaining > 0; remaining -= silence.Length)
            file.Write(silence, 0, (int)Math.Min(remaining, silence.Length));
    }

    void WriteHeader(long dataBytes)
    {
        file.Position = 0;
        var w = new BinaryWriter(file, Encoding.ASCII, true);
        w.Write(Encoding.ASCII.GetBytes("RIFF"));
        w.Write((uint)(HeaderSize - 8 + dataBytes));
        w.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        w.Write(16);
        w.Write((short)3); // IEEE float
        w.Write((short)Channels);
        w.Write(SampleRate);
        w.Write(SampleRate * BytesPerFrame);
        w.Write((short)BytesPerFrame);
        w.Write((short)32);
        w.Write(Encoding.ASCII.GetBytes("data"));
        w.Write((uint)dataBytes);
        w.Flush();
        file.Seek(0, SeekOrigin.End);
    }

    public void Dispose()
    {
        if (file != null) file.Dispose();
    }
}
