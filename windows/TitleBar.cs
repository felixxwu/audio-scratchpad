// The window's own title bar, drawn to match the app's look while keeping what Windows gives a normal one.
using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Shell;

sealed partial class MainWindow
{
    UIElement BuildTitleBar()
    {
        var title = new Border
        {
            Background = Theme.Text, Padding = new Thickness(8, 4, 8, 4),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0),
            Child = new TextBlock { Text = Title.ToUpperInvariant(), Foreground = Theme.Background, FontSize = 15, FontWeight = FontWeights.Black },
        };
        maximizeButton = CaptionButton("\uE922", "Maximize", "Caption", ToggleMaximized);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(CaptionButton("\uE921", "Minimize", "Caption", () => WindowState = WindowState.Minimized));
        buttons.Children.Add(maximizeButton);
        buttons.Children.Add(CaptionButton("\uE8BB", "Close", "CloseCaption", Close));

        var bar = new Grid { Height = 44, Background = Theme.Background };
        bar.Children.Add(title);
        bar.Children.Add(buttons);

        // Windows dims the title bar of a window that isn't active.
        Activated += (s, e) => { title.Opacity = 1; buttons.Opacity = 1; };
        Deactivated += (s, e) => { title.Opacity = 0.55; buttons.Opacity = 0.55; };
        return bar;
    }

    Button CaptionButton(string glyph, string label, string style, Action action)
    {
        var button = new Button { Style = (Style)FindResource(style), Content = glyph, ToolTip = label };
        WindowChrome.SetIsHitTestVisibleInChrome(button, true);
        AutomationProperties.SetName(button, label);
        button.Click += (s, e) => action();
        return button;
    }

    void ToggleMaximized()
    {
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    }

    void UpdateMaximizeButton()
    {
        bool maximized = WindowState == WindowState.Maximized;
        string label = maximized ? "Restore" : "Maximize";
        maximizeButton.Content = maximized ? "\uE923" : "\uE922";
        maximizeButton.ToolTip = label;
        AutomationProperties.SetName(maximizeButton, label);
    }

    // Windows only offers Snap Layouts on what it believes is a real maximize button. Claiming that area
    // means the mouse goes to Windows instead of the button, so hover and click are handled here.
    IntPtr SnapLayoutsHook(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        const int hitTest = 0x84, mouseMove = 0xA0, buttonDown = 0xA1, buttonUp = 0xA2, mouseLeave = 0x2A2, overMaximize = 9;
        bool onMaximize = wParam.ToInt64() == overMaximize;
        switch (message)
        {
            case hitTest:
                if (!OverMaximizeButton(lParam)) break;
                handled = true;
                return new IntPtr(overMaximize);
            case mouseMove:
                if (onMaximize) maximizeButton.Background = Theme.Control;
                else maximizeButton.ClearValue(BackgroundProperty);
                break;
            case mouseLeave:
                maximizeButton.ClearValue(BackgroundProperty);
                break;
            case buttonDown:
                if (!onMaximize) break;
                maximizeButton.Background = Theme.CaptionPressed;
                handled = true;
                break;
            case buttonUp:
                if (!onMaximize) break;
                maximizeButton.ClearValue(BackgroundProperty);
                ToggleMaximized();
                handled = true;
                break;
        }
        return IntPtr.Zero;
    }

    bool OverMaximizeButton(IntPtr screenPoint)
    {
        if (!maximizeButton.IsLoaded) return false;
        long value = screenPoint.ToInt64();
        var point = maximizeButton.PointFromScreen(new Point((short)(value & 0xFFFF), (short)((value >> 16) & 0xFFFF)));
        return new Rect(0, 0, maximizeButton.ActualWidth, maximizeButton.ActualHeight).Contains(point);
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    // Windows 11 draws the rounded corners and thin outline; older versions ignore the request and stay square.
    void RoundWindow()
    {
        var window = new WindowInteropHelper(this).Handle;
        int round = 2, outline = 0x00E3EEF3;
        const int cornerPreference = 33, borderColor = 34;
        DwmSetWindowAttribute(window, cornerPreference, ref round, sizeof(int));
        DwmSetWindowAttribute(window, borderColor, ref outline, sizeof(int));
    }
}
