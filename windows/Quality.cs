// Judges a recording's real quality (lossless, lossy, or upsampled from a lower sample rate) by running the shared
// web/audio-quality.js in Chakra, the JavaScript engine built into Windows, so the Mac, Windows and web versions agree.
using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;

sealed class QualityReport
{
    public string Verdict;
    // A word or two for the list, such as "Lossy" or "22.05 kHz". Empty when there's nothing to judge.
    public string Label;
    public string Summary;
}

static class Quality
{
    // The app carries the script inside the exe; the self-check passes the web folder's copy.
    public static string LoadScript(string path = null)
    {
        if (path != null) return File.ReadAllText(path);
        using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("audio-quality.js"))
        using (var reader = new StreamReader(stream))
            return reader.ReadToEnd();
    }

    // Reads only the parts of the file the script asks for (about 36 seconds in all), so long recordings stay quick.
    // Chakra runs on the calling thread, so call this from a background thread.
    public static QualityReport Check(string path, string script)
    {
        IntPtr runtime;
        Call(JsCreateRuntime(0, IntPtr.Zero, out runtime));
        GCHandle pinned = default(GCHandle);
        try
        {
            IntPtr context;
            Call(JsCreateContext(runtime, out context));
            Call(JsSetCurrentContext(context));
            Run(script);

            int channels, sampleRate;
            long frames;
            using (var r = new BinaryReader(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)))
            {
                long dataStart = Waveform.FindFloatData(r, out channels, out sampleRate, out frames);
                long[] ranges = Run("AudioQuality.excerptRanges(" + frames + ", " + sampleRate + ").join(',')")
                    .Split(',').Select(long.Parse).ToArray();

                long total = 0;
                for (int i = 1; i < ranges.Length; i += 2) total += ranges[i];
                var samples = new float[total * channels];
                var bytes = new byte[samples.Length * 4];
                long filled = 0;
                for (int i = 0; i < ranges.Length; i += 2)
                {
                    r.BaseStream.Position = dataStart + ranges[i] * channels * 4;
                    int wanted = (int)(ranges[i + 1] * channels * 4);
                    int read = 0, count;
                    while (read < wanted && (count = r.Read(bytes, (int)filled + read, wanted - read)) > 0) read += count;
                    filled += read;
                }
                Buffer.BlockCopy(bytes, 0, samples, 0, (int)filled);

                // Chakra reads the samples where they are, so they mustn't move until the runtime is gone.
                pinned = GCHandle.Alloc(samples, GCHandleType.Pinned);
                IntPtr buffer, array;
                Call(JsCreateExternalArrayBuffer(pinned.AddrOfPinnedObject(), (uint)filled, IntPtr.Zero, IntPtr.Zero, out buffer));
                Call(JsCreateTypedArray(7 /* Float32Array */, buffer, 0, (uint)(filled / 4), out array));
                IntPtr global, name;
                Call(JsGetGlobalObject(out global));
                Call(JsGetPropertyIdFromName("excerptSamples", out name));
                Call(JsSetProperty(global, name, array, true));

                string[] parts = Run("(function (r) { return [r.verdict, r.label, r.summary].join('\\n'); })(" +
                    "AudioQuality.analyzeExcerpts(excerptSamples, " + channels + ", " + sampleRate + ", [" + string.Join(",", ranges) + "]))")
                    .Split('\n');
                return new QualityReport { Verdict = parts[0], Label = parts[1], Summary = parts[2] };
            }
        }
        finally
        {
            JsSetCurrentContext(IntPtr.Zero);
            JsDisposeRuntime(runtime);
            if (pinned.IsAllocated) pinned.Free();
        }
    }

    static string Run(string code)
    {
        IntPtr result, text, chars;
        UIntPtr length;
        Call(JsRunScript(code, UIntPtr.Zero, "", out result));
        Call(JsConvertValueToString(result, out text));
        Call(JsStringToPointer(text, out chars, out length));
        return Marshal.PtrToStringUni(chars, (int)length);
    }

    static void Call(int error)
    {
        if (error == 0) return;
        string message = "error " + error.ToString("X");
        IntPtr exception, text, chars;
        UIntPtr length;
        // 0x30001 means the script threw and 0x30002 that it didn't compile; either way the exception says why.
        if ((error == 0x30001 || error == 0x30002) && JsGetAndClearException(out exception) == 0 &&
            JsConvertValueToString(exception, out text) == 0 && JsStringToPointer(text, out chars, out length) == 0)
            message = Marshal.PtrToStringUni(chars, (int)length);
        throw new InvalidOperationException("The quality check failed: " + message);
    }

    // The JsRT API of chakra.dll, which ships with Windows 10 and 11. Each returns 0 on success.
    [DllImport("chakra.dll")] static extern int JsCreateRuntime(int attributes, IntPtr threadService, out IntPtr runtime);
    [DllImport("chakra.dll")] static extern int JsDisposeRuntime(IntPtr runtime);
    [DllImport("chakra.dll")] static extern int JsCreateContext(IntPtr runtime, out IntPtr context);
    [DllImport("chakra.dll")] static extern int JsSetCurrentContext(IntPtr context);
    [DllImport("chakra.dll", CharSet = CharSet.Unicode)]
    static extern int JsRunScript(string script, UIntPtr sourceContext, string sourceUrl, out IntPtr result);
    [DllImport("chakra.dll")] static extern int JsConvertValueToString(IntPtr value, out IntPtr text);
    [DllImport("chakra.dll")] static extern int JsStringToPointer(IntPtr value, out IntPtr chars, out UIntPtr length);
    [DllImport("chakra.dll")] static extern int JsGetAndClearException(out IntPtr exception);
    [DllImport("chakra.dll")] static extern int JsGetGlobalObject(out IntPtr global);
    [DllImport("chakra.dll", CharSet = CharSet.Unicode)]
    static extern int JsGetPropertyIdFromName(string name, out IntPtr propertyId);
    [DllImport("chakra.dll")]
    static extern int JsSetProperty(IntPtr target, IntPtr propertyId, IntPtr value, [MarshalAs(UnmanagedType.U1)] bool useStrictRules);
    [DllImport("chakra.dll")]
    static extern int JsCreateExternalArrayBuffer(IntPtr data, uint byteLength, IntPtr finalize, IntPtr state, out IntPtr result);
    [DllImport("chakra.dll")]
    static extern int JsCreateTypedArray(int arrayType, IntPtr baseArray, uint byteOffset, uint elementLength, out IntPtr result);
}
