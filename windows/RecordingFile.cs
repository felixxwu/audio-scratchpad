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
    // WAV sizes are 32-bit, which limits a recording to about 3 hours.
    public const long LargestDataSize = uint.MaxValue - HeaderSize;

    readonly string path;
    readonly long maxDataSize;
    FileStream file;
    double? expectedTime;

    public bool HasStarted { get { return file != null; } }

    public RecordingFile(string path, long maxDataSize = LargestDataSize)
    {
        this.path = path;
        this.maxDataSize = maxDataSize;
    }

    // `samples` are interleaved, and `playedAt` is when the first of them played in seconds, or null if that isn't known.
    public void Append(double? playedAt, float[] samples)
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

        double? time = playedAt + (double)startFrame / SampleRate ?? expectedTime;
        // Capture skips time while an app is quiet, so the missing time is written back as silence.
        // Gaps under 10ms are ordinary timing jitter, and filling them would add clicks.
        long silentFrames = 0;
        if (time - expectedTime > 0.01)
            silentFrames = (long)Math.Round((time.Value - expectedTime.Value) * SampleRate);

        int frames = samples.Length / Channels - startFrame;
        if (file.Length - HeaderSize + (silentFrames + frames) * BytesPerFrame > maxDataSize)
            throw new IOException("The recording reached the largest size a WAV file can hold.");

        if (silentFrames > 0)
        {
            // Growing a file fills the new space with zeros, so the pause needs no loop of writes.
            file.SetLength(file.Length + silentFrames * BytesPerFrame);
            file.Seek(0, SeekOrigin.End);
        }
        var bytes = new byte[frames * BytesPerFrame];
        Buffer.BlockCopy(samples, startFrame * BytesPerFrame, bytes, 0, bytes.Length);
        file.Write(bytes, 0, bytes.Length);
        expectedTime = time + (double)frames / SampleRate;

        // Kept current after every write, so a crash still leaves a playable file.
        WriteHeader(file.Length - HeaderSize);
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
