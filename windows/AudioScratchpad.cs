// A small Windows app that records the sound of one chosen app to .wav files and lists them.
using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Shell;
using System.Windows.Threading;
using Microsoft.VisualBasic.FileIO;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using Image = System.Windows.Controls.Image;
using Path = System.IO.Path;
using Shape = System.Windows.Shapes.Path;
using Point = System.Windows.Point;
using Size = System.Windows.Size;

sealed class AudioSource
{
    public int ProcessId;
    public string Name;
    public ImageSource Icon;
}

sealed class WaveformView : FrameworkElement
{
    float[] peaks = new float[0];
    double? playhead;
    public Action<double> OnSeek;

    public float[] Peaks { set { peaks = value; InvalidateVisual(); } }
    public double? Playhead { set { if (playhead != value) { playhead = value; InvalidateVisual(); } } }

    // Without this, screen readers skip the waveform and never hear the recording's name.
    protected override AutomationPeer OnCreateAutomationPeer()
    {
        return new FrameworkElementAutomationPeer(this);
    }

    protected override void OnRender(DrawingContext context)
    {
        // Painted so empty space between bars still takes clicks.
        context.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        double width = RenderSize.Width, height = RenderSize.Height;
        if (peaks.Length > 0)
        {
            // One shape rather than a rectangle per bar, because separate edges leave faint seams between bars.
            double barWidth = width / peaks.Length;
            var shape = new StreamGeometry();
            using (var figure = shape.Open())
            {
                for (int i = 0; i < peaks.Length; i++)
                {
                    double bar = Math.Max(1, peaks[i] * height);
                    double left = i * barWidth, top = (height - bar) / 2;
                    figure.BeginFigure(new Point(left, top), true, true);
                    figure.PolyLineTo(new[] { new Point(left + barWidth, top), new Point(left + barWidth, top + bar), new Point(left, top + bar) }, false, false);
                }
            }
            shape.Freeze();
            context.DrawGeometry(Theme.Accent, null, shape);
        }
        if (playhead.HasValue)
            context.DrawRectangle(Brushes.White, null, new Rect(width * playhead.Value - 1, 0, 2, height));
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (OnSeek == null) return;
        CaptureMouse();
        OnSeek(e.GetPosition(this).X / ActualWidth);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (IsMouseCaptured) OnSeek(e.GetPosition(this).X / ActualWidth);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        ReleaseMouseCapture();
    }
}

sealed class Row
{
    public Grid Root;
    public Button Play, Copy;
    public Border Separator;
    public WaveformView Wave;
    public double Duration;
}

sealed partial class MainWindow : Window
{
    readonly string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "Audio Scratchpad");

    readonly ComboBox sourcePicker = new ComboBox { Width = 206.5, Height = 24 };
    readonly TextBlock topTimer = new TextBlock { Foreground = Theme.Recording, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
    readonly Button recordButton = new Button { MinWidth = 98, Height = 28, Margin = new Thickness(8, 0, 0, 0) };
    readonly TextBlock messageText = new TextBlock { Foreground = Theme.Secondary, Margin = new Thickness(16, 0, 16, 12), TextWrapping = TextWrapping.Wrap };
    readonly TextBlock emptyText = new TextBlock { Text = "No recordings yet", Foreground = Theme.Secondary, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly StackPanel list = new StackPanel { Margin = new Thickness(16, 0, 11, 6) };
    readonly ScrollViewer scroller = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.0 / 30) };
    readonly MediaPlayer player = new MediaPlayer();

    readonly Dictionary<string, Row> rows = new Dictionary<string, Row>();
    readonly Dictionary<string, float[]> waveforms = new Dictionary<string, float[]>();
    string listedFiles;
    Dictionary<int, AudioSource> knownSources = new Dictionary<int, AudioSource>();

    // The waveform of the recording in progress.
    LoudnessHistory liveLoudness = new LoudnessHistory();
    Button maximizeButton;
    Grid liveRow;
    Border liveSeparator;
    WaveformView liveWave;
    TextBlock liveTimer;

    Recorder recorder;
    string currentPath;
    DateTime? startedAt;
    string playingPath;

    bool IsCapturing { get { return recorder != null; } }

    public MainWindow()
    {
        // A folder Windows won't let us use shouldn't close the app without a word.
        Application.Current.DispatcherUnhandledException += (s, e) => { ShowMessage(e.Exception.Message); e.Handled = true; };
        Title = "Audio Scratchpad";
        Width = 480;
        Height = 370;
        MinWidth = 480;
        MinHeight = 340;
        Background = Theme.Background;
        FontFamily = new System.Windows.Media.FontFamily("Segoe UI");
        FontSize = 13.5;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.Grayscale);
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 32,
            ResizeBorderThickness = new Thickness(5),
            CornerRadius = new CornerRadius(0),
            GlassFrameThickness = new Thickness(0, 0, 0, 1),
            UseAeroCaptionButtons = false,
        });
        SourceInitialized += (s, e) =>
        {
            RoundWindow();
            HwndSource.FromHwnd(new WindowInteropHelper(this).Handle).AddHook(SnapLayoutsHook);
        };

        recordButton.Style = (Style)FindResource("Pill");
        var controls = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 16, 0, 16) };
        controls.Children.Add(new TextBlock { Text = "Source", Foreground = Theme.Label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8.5, 0) });
        controls.Children.Add(sourcePicker);
        controls.Children.Add(topTimer);
        controls.Children.Add(recordButton);
        AutomationProperties.SetName(sourcePicker, "Source");

        BuildLiveRow();
        var content = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        content.Children.Add(liveRow);
        content.Children.Add(list);
        scroller.Content = content;

        var body = new Grid();
        body.Children.Add(scroller);
        body.Children.Add(emptyText);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        var divider = new Border { Height = 1, Background = Theme.Line };
        var titleBar = BuildTitleBar();
        Grid.SetRow(controls, 1);
        Grid.SetRow(messageText, 2);
        Grid.SetRow(divider, 3);
        Grid.SetRow(body, 4);
        root.Children.Add(titleBar);
        root.Children.Add(controls);
        root.Children.Add(messageText);
        root.Children.Add(divider);
        root.Children.Add(body);
        Content = root;
        // A maximized window hangs past the screen edge by its resize border.
        StateChanged += (s, e) =>
        {
            root.Margin = WindowState == WindowState.Maximized ? SystemParameters.WindowResizeBorderThickness : new Thickness(0);
            UpdateMaximizeButton();
        };

        recordButton.Click += (s, e) => { if (IsCapturing) StopRecording(null); else StartRecording(); };
        sourcePicker.DropDownOpened += (s, e) => RefreshSources();
        sourcePicker.SelectionChanged += (s, e) => UpdateControls();
        player.MediaEnded += (s, e) => StopPlayback();
        player.MediaFailed += (s, e) => { StopPlayback(); ShowMessage(e.ErrorException.Message); };
        timer.Tick += (s, e) => Tick();
        Activated += (s, e) => RefreshRecordings();
        // Stopping finishes the file, so quitting mid-recording still saves it.
        Closing += (s, e) => { if (IsCapturing) StopRecording(null); };

        RefreshSources();
        // Waits for the window to load, because loading waveforms needs the window's thread to be running to finish on it.
        Loaded += (s, e) => RefreshRecordings();
        ShowMessage(null);
        UpdateControls();
    }

    static Shape Glyph(string data, bool filled)
    {
        return new Shape
        {
            Data = Geometry.Parse(data), Stroke = Theme.Accent, StrokeThickness = 1.1, Fill = filled ? Theme.Accent : null,
            StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
            IsHitTestVisible = false,
        };
    }

    void RefreshSources()
    {
        var selected = SelectedSource;
        int ownId;
        using (var own = Process.GetCurrentProcess()) ownId = own.Id;
        var processes = Process.GetProcesses();
        var sources = processes
            .Where(p => p.Id != ownId && p.MainWindowHandle != IntPtr.Zero
                        // The first hosts the windows of Store apps but plays none of their sound; the second is the touch keyboard.
                        && p.ProcessName != "ApplicationFrameHost" && p.ProcessName != "TextInputHost")
            .Select(p => { AudioSource known; return knownSources.TryGetValue(p.Id, out known) ? known : ToSource(p); })
            .OrderBy(s => s.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
        foreach (var process in processes) process.Dispose();
        knownSources = sources.ToDictionary(s => s.ProcessId);

        var items = new List<object> { new ComboBoxItem { Content = "Choose an app…" } };
        foreach (var source in sources)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(new Image { Source = source.Icon, Width = 14, Height = 14, Margin = new Thickness(0, 0, 3.5, 0) });
            row.Children.Add(new TextBlock { Text = source.Name, MaxWidth = 150, TextTrimming = TextTrimming.CharacterEllipsis });
            items.Add(new ComboBoxItem { Content = row, Tag = source });
        }
        sourcePicker.ItemsSource = items;
        sourcePicker.SelectedItem = selected == null ? items[0]
            : items.OfType<ComboBoxItem>().FirstOrDefault(i => i.Tag != null && ((AudioSource)i.Tag).ProcessId == selected.ProcessId) ?? items[0];
    }

    static AudioSource ToSource(Process process)
    {
        var source = new AudioSource { ProcessId = process.Id, Name = process.ProcessName };
        // Apps running as administrator don't let us read these, so they keep the plain process name.
        try
        {
            var module = process.MainModule;
            if (!string.IsNullOrWhiteSpace(module.FileVersionInfo.FileDescription))
                source.Name = module.FileVersionInfo.FileDescription;
            using (var icon = System.Drawing.Icon.ExtractAssociatedIcon(module.FileName))
                source.Icon = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
        }
        catch (Exception) { }
        return source;
    }

    AudioSource SelectedSource
    {
        get
        {
            var item = sourcePicker.SelectedItem as ComboBoxItem;
            return item == null ? null : item.Tag as AudioSource;
        }
    }

    void RefreshRecordings()
    {
        Directory.CreateDirectory(folder);
        var files = new DirectoryInfo(folder).GetFiles("*.wav")
            .Where(f => f.FullName != currentPath)
            .OrderByDescending(f => f.CreationTimeUtc)
            .Select(f => f.FullName)
            .ToList();

        // Rebuilding only on a real change, so returning to the window can't disturb a click on a row.
        string signature = string.Join("|", files);
        if (signature == listedFiles) return;
        listedFiles = signature;

        rows.Clear();
        list.Children.Clear();
        foreach (string path in files)
        {
            var row = BuildRow(path);
            rows[path] = row;
            list.Children.Add(row.Root);
            LoadWaveform(path, row);
        }
        if (files.Count > 0) rows[files.Last()].Separator.Visibility = Visibility.Collapsed;
        UpdateControls();
    }

    // ponytail: scans every file not yet seen as soon as it's listed, so a folder of thousands would need lazy loading.
    async void LoadWaveform(string path, Row row)
    {
        float[] peaks;
        if (!waveforms.TryGetValue(path, out peaks))
        {
            try { peaks = await Task.Run(() => Waveform.Peaks(path)); }
            catch (Exception) { peaks = new float[0]; }
            waveforms[path] = peaks;
        }
        row.Wave.Peaks = peaks;
    }

    static Grid NewRowGrid()
    {
        var grid = new Grid { Height = 36 };
        foreach (double width in new double[] { 25, -1, 40, 24, 24, 24 })
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width < 0 ? new GridLength(1, GridUnitType.Star) : new GridLength(width) });
        return grid;
    }

    static Button IconButton(string icon, bool filled, string label, int column, Grid grid)
    {
        var button = new Button { Content = Glyph(icon, filled), Width = 24, Height = 24, ToolTip = label };
        AutomationProperties.SetName(button, label);
        Grid.SetColumn(button, column);
        grid.Children.Add(button);
        return button;
    }

    static TextBlock TimeText(Grid grid)
    {
        var text = new TextBlock
        {
            Foreground = Theme.Secondary, VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 4, 0),
        };
        Grid.SetColumn(text, 2);
        grid.Children.Add(text);
        return text;
    }

    // The thin line between rows, which only runs under the time and buttons.
    static Border RowSeparator(Grid grid)
    {
        var line = new Border { Height = 1, Background = Theme.Line, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(8, 0, 4, 0) };
        Grid.SetColumn(line, 2);
        Grid.SetColumnSpan(line, 4);
        grid.Children.Add(line);
        return line;
    }

    static WaveformView NewWave(Grid grid)
    {
        var wave = new WaveformView { Margin = new Thickness(0, 4, 0, 4) };
        Grid.SetColumn(wave, 1);
        grid.Children.Add(wave);
        return wave;
    }

    static UIElement RecordDot()
    {
        var dot = new Grid { Width = 12.75, Height = 12.75, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(2.6, 0, 0, 0) };
        dot.Children.Add(new Ellipse { Fill = Theme.Recording });
        dot.Children.Add(new Ellipse { Fill = Theme.Background, Width = 5, Height = 5 });
        AutomationProperties.SetName(dot, "Recording");
        return dot;
    }

    void BuildLiveRow()
    {
        liveRow = NewRowGrid();
        liveRow.Margin = new Thickness(16, 0, 11, 0);
        liveRow.Children.Add(RecordDot());
        liveWave = NewWave(liveRow);
        liveTimer = TimeText(liveRow);
        liveSeparator = RowSeparator(liveRow);
    }

    Row BuildRow(string path)
    {
        string name = Path.GetFileNameWithoutExtension(path);
        var grid = NewRowGrid();
        var row = new Row { Root = grid };

        // A file that can't be read still gets listed, so it can be found and deleted.
        try { row.Duration = Waveform.Duration(path); }
        catch (Exception) { }

        row.Play = IconButton(path == playingPath ? Theme.Stop : Theme.Play, true, "Play", 0, grid);
        row.Play.Width = 18;
        row.Play.HorizontalAlignment = HorizontalAlignment.Left;
        row.Play.Click += (s, e) => TogglePlayback(path);

        row.Wave = NewWave(grid);
        row.Wave.ToolTip = name;
        row.Wave.OnSeek = fraction => Seek(path, fraction);
        AutomationProperties.SetName(row.Wave, name);

        TimeText(grid).Text = FormatTime(row.Duration);
        row.Separator = RowSeparator(grid);

        row.Copy = IconButton(Theme.Copy, false, "Click to copy, or drag into another app", 3, grid);
        row.Copy.Click += (s, e) => CopyToClipboard(path);
        Point? pressed = null;
        row.Copy.PreviewMouseLeftButtonDown += (s, e) => pressed = e.GetPosition(row.Copy);
        row.Copy.PreviewMouseMove += (s, e) =>
        {
            if (!pressed.HasValue || e.LeftButton != MouseButtonState.Pressed) return;
            var moved = e.GetPosition(row.Copy) - pressed.Value;
            // A hand that shifts slightly during a click shouldn't turn it into a drag.
            if (Math.Abs(moved.X) < SystemParameters.MinimumHorizontalDragDistance &&
                Math.Abs(moved.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            pressed = null;
            row.Copy.ReleaseMouseCapture();
            DragDrop.DoDragDrop(row.Copy, new DataObject(DataFormats.FileDrop, new[] { path }), DragDropEffects.Copy);
        };

        IconButton(Theme.Folder, false, "Show in File Explorer", 4, grid).Click +=
            (s, e) => Process.Start("explorer.exe", "/select,\"" + path + "\"");
        IconButton(Theme.Trash, false, "Move to Recycle Bin", 5, grid).Click += (s, e) => MoveToTrash(path);
        return row;
    }

    static string FormatTime(double seconds)
    {
        var time = TimeSpan.FromSeconds(seconds);
        return (int)time.TotalMinutes + ":" + time.Seconds.ToString("00");
    }

    void StartRecording()
    {
        var source = SelectedSource;
        if (source == null || IsCapturing) return;
        ShowMessage(null);
        StopPlayback();
        try { Process.GetProcessById(source.ProcessId).Dispose(); }
        catch (ArgumentException)
        {
            ShowMessage(source.Name + " isn't available to record. Is it still open?");
            return;
        }

        Directory.CreateDirectory(folder);
        string path = NewFilePath(source.Name);
        var started = new Recorder();
        started.OnUnexpectedStop = error => Dispatcher.BeginInvoke(new Action(() =>
        {
            if (recorder == started) StopRecording(error.Message);
        }));
        started.OnLoudness = loudness => Dispatcher.BeginInvoke(new Action(() =>
        {
            if (recorder != started) return;
            liveLoudness.Append(loudness);
            liveWave.Peaks = Waveform.Fit(liveLoudness.Values);
        }));
        started.OnAudioStarted = () => Dispatcher.BeginInvoke(new Action(() =>
        {
            if (recorder != started) return;
            startedAt = DateTime.UtcNow;
            topTimer.Text = "0:00";
            liveTimer.Text = "0:00";
            UpdateControls();
        }));
        liveLoudness = new LoudnessHistory();
        liveWave.Peaks = new float[0];
        currentPath = path;
        recorder = started;
        UpdateControls();
        started.Start(source.ProcessId, path);
    }

    void StopRecording(string reason)
    {
        var stopping = recorder;
        if (stopping == null) return;
        recorder = null;
        startedAt = null;
        bool saved = stopping.Stop();
        currentPath = null;
        if (reason != null) ShowMessage("Recording stopped: " + reason);
        else if (!saved) ShowMessage("No sound came from that app, so nothing was saved.");
        RefreshSources();
        RefreshRecordings();
        UpdateControls();
    }

    void TogglePlayback(string path)
    {
        if (playingPath == path) StopPlayback();
        else Play(path);
    }

    void Play(string path)
    {
        StopPlayback();
        player.Open(new Uri(path));
        player.Play();
        playingPath = path;
        rows[path].Play.Content = Glyph(Theme.Stop, true);
        AutomationProperties.SetName(rows[path].Play, "Stop playing");
        UpdateControls();
    }

    void Seek(string path, double fraction)
    {
        if (playingPath != path) Play(path);
        // Stay just short of the end, so dragging there doesn't finish playback mid-drag.
        player.Position = TimeSpan.FromSeconds(rows[path].Duration * Math.Min(Math.Max(fraction, 0), 0.999));
    }

    void StopPlayback()
    {
        if (playingPath == null) return;
        player.Stop();
        player.Close();
        Row row;
        if (rows.TryGetValue(playingPath, out row))
        {
            row.Play.Content = Glyph(Theme.Play, true);
            AutomationProperties.SetName(row.Play, "Play");
            row.Wave.Playhead = null;
        }
        playingPath = null;
        UpdateControls();
    }

    // Copies the audio file itself, so it can be pasted into File Explorer or a chat app.
    async void CopyToClipboard(string path)
    {
        try
        {
            var files = new StringCollection();
            files.Add(path);
            Clipboard.SetFileDropList(files);
        }
        catch (Exception error)
        {
            ShowMessage(error.Message);
            return;
        }
        var button = rows[path].Copy;
        button.Content = Glyph(Theme.Copied, false);
        await Task.Delay(1500);
        button.Content = Glyph(Theme.Copy, false);
    }

    void MoveToTrash(string path)
    {
        if (playingPath == path) StopPlayback();
        try
        {
            FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
            waveforms.Remove(path);
        }
        catch (Exception error)
        {
            ShowMessage(error.Message);
        }
        RefreshRecordings();
    }

    string NewFilePath(string appName)
    {
        // A fixed culture keeps file names the same whatever the PC's region settings are.
        string stamp = DateTime.Now.ToString("yyyy-MM-dd HH.mm.ss", CultureInfo.InvariantCulture);
        string safeName = new string(appName.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '-' : c).ToArray());
        string name = safeName + " " + stamp;
        string path = Path.Combine(folder, name + ".wav");
        for (int copy = 2; File.Exists(path); copy++)
            path = Path.Combine(folder, name + " " + copy + ".wav");
        return path;
    }

    void ShowMessage(string message)
    {
        messageText.Text = message;
        messageText.Visibility = message == null ? Visibility.Collapsed : Visibility.Visible;
    }

    void Tick()
    {
        if (startedAt.HasValue)
        {
            string elapsed = FormatTime((DateTime.UtcNow - startedAt.Value).TotalSeconds);
            topTimer.Text = elapsed;
            liveTimer.Text = elapsed;
        }
        Row row;
        if (playingPath != null && rows.TryGetValue(playingPath, out row) && row.Duration > 0)
            row.Wave.Playhead = Math.Min(1, player.Position.TotalSeconds / row.Duration);
    }

    void UpdateControls()
    {
        bool recording = startedAt.HasValue;
        string label = !IsCapturing ? "Record" : recording ? "Stop" : "waiting for audio...";
        recordButton.Content = RecordLabel(label);
        AutomationProperties.SetName(recordButton, label);
        recordButton.IsEnabled = IsCapturing || SelectedSource != null;
        sourcePicker.IsEnabled = !IsCapturing;
        topTimer.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;
        liveSeparator.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        liveRow.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;
        emptyText.Visibility = rows.Count == 0 && !recording ? Visibility.Visible : Visibility.Collapsed;
        liveWave.ToolTip = currentPath == null ? null : Path.GetFileNameWithoutExtension(currentPath);
        timer.IsEnabled = recording || playingPath != null;
    }

    UIElement RecordLabel(string label)
    {
        FrameworkElement icon;
        if (IsCapturing)
        {
            icon = Glyph(Theme.Stop, true);
        }
        else
        {
            var ring = new Grid { Width = 12.75, Height = 12.75 };
            ring.Children.Add(new Ellipse { Stroke = Theme.Accent, StrokeThickness = 1.1 });
            ring.Children.Add(new Ellipse { Fill = Theme.Accent, Width = 5, Height = 5 });
            icon = ring;
        }
        icon.VerticalAlignment = VerticalAlignment.Center;
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(icon);
        panel.Children.Add(new TextBlock { Text = label, Margin = new Thickness(9.75, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        return panel;
    }

    [STAThread]
    static void Main()
    {
        var app = new Application();
        app.Resources = (ResourceDictionary)XamlReader.Parse(Theme.Styles);
        app.Run(new MainWindow());
    }
}
