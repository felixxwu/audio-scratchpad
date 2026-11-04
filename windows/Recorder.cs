// Captures one app and its child processes through WASAPI process loopback into a single file. Needs Windows 10 2004 or newer.
using System;
using System.Runtime.InteropServices;
using System.Threading;

sealed class Recorder
{
    public Action<Exception> OnUnexpectedStop;
    public Action<float> OnLoudness;
    public Action OnAudioStarted;

    Thread thread;
    RecordingFile output;
    volatile bool stopping;
    float pendingLoudness;
    int pendingFrames;

    public void Start(int processId, string path)
    {
        output = new RecordingFile(path);
        // Audio interfaces activated this way need a thread outside the window's single-threaded apartment.
        thread = new Thread(() => Capture(processId)) { IsBackground = true, Name = "recorder.audio" };
        thread.Start();
    }

    // Returns false when no audio ever arrived, in which case no file is left behind.
    public bool Stop()
    {
        stopping = true;
        thread.Join();
        output.Dispose();
        return output.HasStarted;
    }

    void Capture(int processId)
    {
        IAudioClient client = null;
        try
        {
            client = Native.ActivateProcessLoopback(processId);
            var format = new WaveFormatEx
            {
                wFormatTag = 3, // IEEE float
                nChannels = RecordingFile.Channels,
                nSamplesPerSec = RecordingFile.SampleRate,
                nAvgBytesPerSec = RecordingFile.SampleRate * RecordingFile.Channels * 4,
                nBlockAlign = RecordingFile.Channels * 4,
                wBitsPerSample = 32,
            };
            const uint loopback = 0x00020000, eventCallback = 0x00040000, autoConvert = 0x80000000;
            client.Initialize(0, loopback | eventCallback | autoConvert, 2000000, 0, ref format, IntPtr.Zero);

            using (var ready = new AutoResetEvent(false))
            {
                client.SetEventHandle(ready.SafeWaitHandle.DangerousGetHandle());
                var iid = typeof(IAudioCaptureClient).GUID;
                object service;
                client.GetService(ref iid, out service);
                var capture = (IAudioCaptureClient)service;
                client.Start();
                // The timeout is only so a stop request is noticed while the app is quiet.
                while (!stopping)
                {
                    ready.WaitOne(100);
                    Drain(capture);
                }
                client.Stop();
                Drain(capture);
                Marshal.ReleaseComObject(capture);
            }
        }
        catch (Exception error)
        {
            if (!stopping && OnUnexpectedStop != null) OnUnexpectedStop(error);
        }
        finally
        {
            if (client != null) Marshal.ReleaseComObject(client);
        }
    }

    void Drain(IAudioCaptureClient capture)
    {
        while (true)
        {
            uint size;
            capture.GetNextPacketSize(out size);
            if (size == 0) return;

            IntPtr data;
            uint frames, flags;
            ulong devicePosition, time;
            capture.GetBuffer(out data, out frames, out flags, out devicePosition, out time);
            var samples = new float[frames * RecordingFile.Channels];
            const uint silent = 2;
            if ((flags & silent) == 0) Marshal.Copy(data, samples, 0, samples.Length);
            capture.ReleaseBuffer(frames);

            bool wasStarted = output.HasStarted;
            output.Append(time / 1e7, samples);
            if (!output.HasStarted) continue;
            if (!wasStarted && OnAudioStarted != null) OnAudioStarted();
            ReportLoudness(samples);
        }
    }

    // Hands the window one loudness value per 50ms, so it can draw the waveform while recording.
    void ReportLoudness(float[] samples)
    {
        foreach (float sample in samples) pendingLoudness = Math.Max(pendingLoudness, Math.Abs(sample));
        pendingFrames += samples.Length / RecordingFile.Channels;
        if (pendingFrames < 2400) return;
        if (OnLoudness != null) OnLoudness(pendingLoudness);
        pendingLoudness = 0;
        pendingFrames = 0;
    }
}

[StructLayout(LayoutKind.Sequential, Pack = 2)]
struct WaveFormatEx
{
    public short wFormatTag, nChannels;
    public int nSamplesPerSec, nAvgBytesPerSec;
    public short nBlockAlign, wBitsPerSample, cbSize;
}

[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioClient
{
    void Initialize(int shareMode, uint streamFlags, long bufferDuration, long periodicity, ref WaveFormatEx format, IntPtr sessionGuid);
    void GetBufferSize(out uint frames);
    void GetStreamLatency(out long latency);
    void GetCurrentPadding(out uint frames);
    void IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
    void GetMixFormat(out IntPtr format);
    void GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
    void Start();
    void Stop();
    void Reset();
    void SetEventHandle(IntPtr handle);
    void GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
}

[ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioCaptureClient
{
    void GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
    void ReleaseBuffer(uint frames);
    void GetNextPacketSize(out uint frames);
}

[ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IActivateAudioInterfaceAsyncOperation
{
    void GetActivateResult(out int result, [MarshalAs(UnmanagedType.IUnknown)] out object activated);
}

[ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IActivateAudioInterfaceCompletionHandler
{
    void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation);
}

[ComImport, Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAgileObject { }

static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    struct ActivationParams
    {
        public int ActivationType, TargetProcessId, ProcessLoopbackMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BlobPropVariant
    {
        public ushort vt, reserved1, reserved2, reserved3;
        public uint cbSize;
        public IntPtr pBlobData;
    }

    sealed class Completion : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        public readonly ManualResetEvent Done = new ManualResetEvent(false);
        public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation) { Done.Set(); }
    }

    [DllImport("mmdevapi.dll", ExactSpelling = true)]
    static extern int ActivateAudioInterfaceAsync(
        [MarshalAs(UnmanagedType.LPWStr)] string device, ref Guid iid, ref BlobPropVariant parameters,
        IActivateAudioInterfaceCompletionHandler handler, out IActivateAudioInterfaceAsyncOperation operation);

    public static IAudioClient ActivateProcessLoopback(int processId)
    {
        const int processLoopback = 1, includeTargetProcessTree = 0;
        var activation = new ActivationParams
        {
            ActivationType = processLoopback,
            TargetProcessId = processId,
            ProcessLoopbackMode = includeTargetProcessTree,
        };
        var pin = GCHandle.Alloc(activation, GCHandleType.Pinned);
        try
        {
            const ushort vtBlob = 65;
            var parameters = new BlobPropVariant
            {
                vt = vtBlob,
                cbSize = (uint)Marshal.SizeOf(typeof(ActivationParams)),
                pBlobData = pin.AddrOfPinnedObject(),
            };
            var iid = typeof(IAudioClient).GUID;
            var completion = new Completion();
            IActivateAudioInterfaceAsyncOperation operation;
            Marshal.ThrowExceptionForHR(ActivateAudioInterfaceAsync(
                "VAD\\Process_Loopback", ref iid, ref parameters, completion, out operation));
            completion.Done.WaitOne();

            int result;
            object activated;
            operation.GetActivateResult(out result, out activated);
            Marshal.ThrowExceptionForHR(result);
            return (IAudioClient)activated;
        }
        finally
        {
            pin.Free();
        }
    }
}
