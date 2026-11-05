// Fails the build if waveforms are drawn wrongly, or recordings don't start, pause and store samples as intended.
using System;
using System.IO;
using System.Linq;

static class SelfCheck
{
    static void Require(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    static float[] Stereo(params float[] values)
    {
        return values.SelectMany(v => new[] { v, v }).ToArray();
    }

    static void CheckRecordingFile(string path)
    {
        using (var recording = new RecordingFile(path))
        {
            recording.Append(100, Stereo(0, 0, 0, 0));
            Require(!recording.HasStarted, "silence alone should not start a recording");
            Require(!File.Exists(path), "silence alone should not create a file");

            recording.Append(101, Stereo(0, 0, 1.5f, 0.25f));
            Require(recording.HasStarted, "a non-zero sample should start the recording");
            // The first buffer ends at 101 + 4 frames, so this leaves a one second pause.
            recording.Append(102 + 4.0 / 48000, Stereo(0.5f, 0.5f));
            // Jitter under 10ms must not add silence.
            recording.Append(102 + 6.0 / 48000 + 0.005, Stereo(0.75f));
            // A packet whose time Windows flags as unreliable carries straight on.
            recording.Append(null, Stereo(0.125f));
        }

        var bytes = File.ReadAllBytes(path);
        Require(BitConverter.ToInt16(bytes, 20) == 3, "file should store float samples");
        Require(BitConverter.ToInt16(bytes, 34) == 32, "file should store 32-bit samples");
        const int frames = 2 + 48000 + 2 + 1 + 1;
        Require(BitConverter.ToInt32(bytes, 40) == frames * 8, "should drop the lead-in and keep the pause");
        Require(BitConverter.ToInt32(bytes, 4) == 36 + frames * 8, "RIFF size should match");
        Require(bytes.Length == 44 + frames * 8, "file length should match its header");

        Func<int, float> left = frame => BitConverter.ToSingle(bytes, 44 + frame * 8);
        Require(left(0) == 1.5f, "should start on the first non-zero sample and keep peaks above full scale");
        Require(left(1) == 0.25f, "should keep the rest of the first buffer");
        Require(Enumerable.Range(2, 48000).All(f => left(f) == 0), "the pause should be silent");
        Require(left(48002) == 0.5f, "audio should resume after the pause");
        Require(left(48004) == 0.75f, "jitter should not add silence");
        Require(left(48005) == 0.125f, "an unreliable time should not add silence");
        Require(Math.Abs(Waveform.Duration(path) - frames / 48000.0) < 1e-9, "duration should come from the header");
    }

    static void CheckWaveform(string path)
    {
        using (var recording = new RecordingFile(path))
        {
            var loud = new float[200000];
            for (int i = 0; i < loud.Length; i++) loud[i] = i % 2 == 0 ? 0.5f : -0.5f;
            recording.Append(0, loud);
            // A pause as long as the sound, then one last frame in the final bar.
            recording.Append(100000 / 48000.0 * 2, Stereo(0.5f));
        }
        var peaks = Waveform.Peaks(path, 100);
        Require(peaks.Length == 100, "should return one value per bar");
        Require(peaks.Take(50).All(p => p == 1), "loud half should fill the height");
        Require(peaks.Skip(50).Take(49).All(p => p == 0), "silent half should be flat");
        Require(Waveform.Fit(new[] { 0.25f, 0.5f }).SequenceEqual(new[] { 0.5f, 1f }), "short input keeps every value");
        Require(Waveform.Fit(new[] { 0f, 0f, 0.5f, 0.25f }, 2).SequenceEqual(new[] { 0f, 1f }), "long input keeps each group's loudest");

        var history = new LoudnessHistory();
        for (int i = 0; i < 5000; i++) history.Append(i == 1234 ? 1f : 0.1f);
        Require(history.Values.Length <= 800, "a long recording's history should stay small");
        Require(history.Values.Max() == 1f, "merging should keep the loudest moment");
    }

    static void CheckUnknownFirstTime(string path)
    {
        using (var recording = new RecordingFile(path))
        {
            recording.Append(null, Stereo(1));
            recording.Append(5000, Stereo(1));
        }
        Require(new FileInfo(path).Length == 44 + 2 * 8, "a first packet with no time should not add silence");
    }

    static void CheckSizeLimit(string path)
    {
        using (var recording = new RecordingFile(path, 16))
        {
            recording.Append(0, Stereo(1, 1));
            bool stopped = false;
            // An hour's gap must be refused before any of its silence reaches the disk.
            try { recording.Append(3600, Stereo(1)); }
            catch (IOException) { stopped = true; }
            Require(stopped, "should stop before the file outgrows what a WAV can hold");
        }
        Require(new FileInfo(path).Length == 44 + 16, "a full recording should stay playable");
    }

    static void Main()
    {
        foreach (Action<string> check in new Action<string>[] { CheckRecordingFile, CheckWaveform, CheckUnknownFirstTime, CheckSizeLimit })
        {
            string path = Path.Combine(Path.GetTempPath(), "recording-check-" + Guid.NewGuid() + ".wav");
            try { check(path); }
            finally { File.Delete(path); }
        }
        Console.WriteLine("Self-check passed");
    }
}
