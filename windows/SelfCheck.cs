// Fails the build if waveforms are drawn wrongly, or recordings don't start, pause and store samples as intended.
using System;
using System.IO;
using System.Linq;
using System.Text;

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
            Require(Math.Abs(Waveform.Duration(path) - (2 + 48000 + 2) / 48000.0) < 1e-9, "a file still being written should already be playable");
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

    // A compressed WAV from elsewhere, with an extra odd-sized chunk before its format.
    static void CheckForeignWav(string path)
    {
        using (var w = new BinaryWriter(File.Create(path)))
        {
            w.Write(Encoding.ASCII.GetBytes("RIFF"));
            w.Write(0);
            w.Write(Encoding.ASCII.GetBytes("WAVELIST"));
            w.Write(3);
            w.Write(new byte[4]);
            w.Write(Encoding.ASCII.GetBytes("fmt "));
            w.Write(16);
            w.Write((short)17);
            w.Write((short)1);
            w.Write(44100);
            w.Write(22000);
            w.Write((short)512);
            w.Write((short)0);
            w.Write(Encoding.ASCII.GetBytes("data"));
            w.Write(11000);
            w.Write(new byte[11000]);
        }
        Require(Waveform.Duration(path) == 0.5, "duration should skip unknown chunks and use the file's byte rate");
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

        bool refused = false;
        using (var second = new RecordingFile(path))
        {
            try { second.Append(0, Stereo(1)); }
            catch (IOException) { refused = true; }
        }
        Require(refused && new FileInfo(path).Length == 44 + 16, "should never overwrite an existing recording");
    }

    // Runs real recordings through the shared quality check, to catch mistakes in handing audio to JavaScript. The check's
    // own judgement is tested against real music in quality/.
    static void CheckQuality(string path)
    {
        string script = Quality.LoadScript(Path.Combine("..", "web", "audio-quality.js"));
        ulong seed = 1;
        Func<double> random = () =>
        {
            seed = (seed * 1103515245 + 12345) % 2147483648;
            return seed / 2147483648.0;
        };
        Func<float[], QualityReport> check = values =>
        {
            File.Delete(path);
            using (var recording = new RecordingFile(path)) recording.Append(0, Stereo(values));
            return Quality.Check(path, script);
        };

        // A minute of 16-bit noise, the same in both channels, is long enough to be read in parts.
        var noise = new float[48000 * 60];
        for (int i = 0; i < noise.Length; i++) noise[i] = (float)(Math.Round((random() - 0.5) * 16384) / 32768);
        QualityReport clean;
        try { clean = check(noise); }
        catch (DllNotFoundException)
        {
            Console.WriteLine("Skipped the quality check: this machine has no chakra.dll");
            return;
        }
        Require(clean.Verdict == "lossless" && clean.Label == "Lossless", "noise should be lossless, got " + clean.Summary);
        Require(clean.Summary.Contains("16-bit"), "samples should reach the check unchanged, got " + clean.Summary);
        Require(clean.Summary.Contains("really mono"), "channels should reach the check in order, got " + clean.Summary);

        // A thousand tones below 16 kHz and nothing above, the way a 128 kbps MP3 cuts off.
        var tones = new float[48000 * 5];
        for (int tone = 0; tone < 1000; tone++)
        {
            double step = 2 * Math.PI * (100 + random() * 15900) / 48000, phase = random() * 2 * Math.PI;
            double turnRe = Math.Cos(step), turnIm = Math.Sin(step), re = Math.Cos(phase), im = Math.Sin(phase);
            for (int i = 0; i < tones.Length; i++)
            {
                tones[i] += (float)(0.002 * re);
                double next = re * turnRe - im * turnIm;
                im = re * turnIm + im * turnRe;
                re = next;
            }
        }
        var lossy = check(tones);
        Require(lossy.Verdict == "lossy" && lossy.Label == "Lossy", "a 16 kHz cutoff should look lossy, got " + lossy.Summary);
    }

    static void Main()
    {
        foreach (Action<string> check in new Action<string>[] { CheckRecordingFile, CheckWaveform, CheckUnknownFirstTime, CheckForeignWav, CheckSizeLimit, CheckQuality })
        {
            string path = Path.Combine(Path.GetTempPath(), "recording-check-" + Guid.NewGuid() + ".wav");
            try { check(path); }
            finally { File.Delete(path); }
        }
        Console.WriteLine("Self-check passed");
    }
}
