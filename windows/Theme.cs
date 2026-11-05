// The look of the app: warm off-black, cream and highlighter yellow, set in Archivo Expanded, matching the web version in dark mode.
using System;
using System.IO;
using System.Windows.Media;

static class Theme
{
    const string TextColor = "#F3EEE3";
    const string BackgroundColor = "#14120F";
    const string ControlColor = "#2A261F";
    const string HighlightColor = "#FFDF1F";
    const string OnHighlightColor = "#1A1814";
    const string MutedColor = "#A39C8E";

    public static readonly SolidColorBrush Text = Brush(TextColor);
    public static readonly SolidColorBrush Background = Brush(BackgroundColor);
    public static readonly SolidColorBrush Highlight = Brush(HighlightColor);
    public static readonly SolidColorBrush Control = Brush(ControlColor);
    public static readonly SolidColorBrush CaptionPressed = Brush("#38332A");
    public static readonly SolidColorBrush OnHighlight = Brush(OnHighlightColor);
    public static readonly SolidColorBrush Recording = Brush("#FF5A3C");

    static SolidColorBrush Brush(string color)
    {
        var brush = (SolidColorBrush)new BrushConverter().ConvertFromString(color);
        brush.Freeze();
        return brush;
    }

    // WPF can only load a font from a file, so the ones built into the exe are copied to the user's app data.
    public static FontFamily LoadFont()
    {
        try
        {
            string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Audio Scratchpad", "Fonts");
            Directory.CreateDirectory(folder);
            foreach (string name in new[] { "ArchivoExpanded-Regular.ttf", "ArchivoExpanded-Black.ttf", "OFL.txt" })
            {
                string path = Path.Combine(folder, name);
                using (var source = typeof(Theme).Assembly.GetManifestResourceStream(name))
                {
                    if (File.Exists(path) && new FileInfo(path).Length == source.Length) continue;
                    using (var file = File.Create(path)) source.CopyTo(file);
                }
            }
            return new FontFamily(new Uri(folder + Path.DirectorySeparatorChar), "./#Archivo Expanded");
        }
        catch (Exception)
        {
            return new FontFamily("Segoe UI");
        }
    }

    // Icons drawn to match the Mac app's symbols, in window units.
    public const string Play = "M0.6,0.6 L9.6,5.6 L0.6,10.6 Z";
    public const string Stop = "M0.6,0.6 H9.4 V9.4 H0.6 Z";
    public const string Copy =
        "M1.9,3.5 H5.5 L9.5,7.5 V14.1 Q9.5,15.5 8.1,15.5 H1.9 Q0.5,15.5 0.5,14.1 V4.9 Q0.5,3.5 1.9,3.5 Z " +
        "M5.5,3.5 V6.5 Q5.5,7.5 6.5,7.5 H9.5 " +
        "M3.2,3.2 V1.9 Q3.2,0.5 4.6,0.5 H8.5 L12.5,4.5 V11.6 Q12.5,13 11.1,13 H9.7 " +
        "M8.5,0.5 V3.5 Q8.5,4.5 9.5,4.5 H12.5";
    public const string Copied = "M0.6,6.4 L4.6,10.4 L12.4,1";
    public const string Microphone =
        "M7,1 Q9,1 9,3 V7 Q9,9 7,9 Q5,9 5,7 V3 Q5,1 7,1 Z " +
        "M3,6.5 V7 Q3,11 7,11 Q11,11 11,7 V6.5 " +
        "M7,11 V13 M5,13 H9";
    public const string Folder =
        "M2,0.5 H4 Q4.8,0.5 5.3,1 L6,1.8 H12.5 Q14,1.8 14,3.3 V10 Q14,11.5 12.5,11.5 H2 Q0.5,11.5 0.5,10 V2 Q0.5,0.5 2,0.5 Z " +
        "M1.7,3.7 H12.8";
    public const string Trash =
        "M0.2,2.9 H12 " +
        "M3.5,2.9 V1.5 Q3.5,0.4 4.6,0.4 H7.5 Q8.6,0.4 8.6,1.5 V2.9 " +
        "M1.4,2.9 L2.1,12.6 Q2.2,13.8 3.4,13.8 H8.7 Q9.9,13.8 10,12.6 L10.7,2.9 " +
        "M3.9,4.7 L4.1,12 M6.05,4.7 V12 M8.2,4.7 L8,12";
    public const string Styles = @"
<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
                    xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>

  <Style x:Key='Focus'>
    <Setter Property='Control.Template'>
      <Setter.Value>
        <ControlTemplate>
          <Rectangle Margin='-3' Stroke='" + TextColor + @"' StrokeThickness='2' />
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- Icon buttons, which turn highlighter yellow under the pointer. -->
  <Style TargetType='Button'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource Focus}' />
    <Setter Property='Foreground' Value='" + TextColor + @"' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='Button'>
          <Border x:Name='Box' Background='Transparent'>
            <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' />
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property='IsMouseOver' Value='True'>
              <Setter TargetName='Box' Property='Background' Value='" + HighlightColor + @"' />
              <Setter Property='Foreground' Value='" + OnHighlightColor + @"' />
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- A yellow key with a hard gold shadow that it presses down into. -->
  <Style x:Key='Record' TargetType='Button'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource Focus}' />
    <Setter Property='Foreground' Value='" + OnHighlightColor + @"' />
    <Setter Property='FontWeight' Value='Black' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='Button'>
          <Grid x:Name='Root' Margin='0,0,5,5'>
            <Border x:Name='Shadow' Background='#B39400' Margin='5,5,-5,-5' />
            <Grid x:Name='Key'>
              <Border Background='" + BackgroundColor + @"' Margin='-2' />
              <Border x:Name='Box' Background='" + HighlightColor + @"' BorderBrush='" + HighlightColor + @"' BorderThickness='2' Padding='18,0'>
                <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' />
              </Border>
            </Grid>
            <Rectangle x:Name='Dashes' Stroke='" + MutedColor + @"' StrokeThickness='2' StrokeDashArray='2 1.5' Visibility='Collapsed' />
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property='IsPressed' Value='True'><Setter TargetName='Key' Property='Margin' Value='5,5,-5,-5' /></Trigger>
            <Trigger Property='IsEnabled' Value='False'>
              <Setter TargetName='Shadow' Property='Visibility' Value='Hidden' />
              <Setter TargetName='Box' Property='Background' Value='Transparent' />
              <Setter TargetName='Box' Property='BorderBrush' Value='Transparent' />
              <Setter TargetName='Dashes' Property='Visibility' Value='Visible' />
              <Setter Property='Foreground' Value='" + MutedColor + @"' />
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key='Caption' TargetType='Button'>
    <Setter Property='Focusable' Value='False' />
    <Setter Property='Width' Value='46' />
    <Setter Property='Height' Value='44' />
    <Setter Property='VerticalAlignment' Value='Top' />
    <Setter Property='Background' Value='Transparent' />
    <Setter Property='Foreground' Value='" + TextColor + @"' />
    <Setter Property='FontFamily' Value='Segoe MDL2 Assets' />
    <Setter Property='FontSize' Value='10' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='Button'>
          <Border Background='{TemplateBinding Background}'>
            <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' />
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property='IsMouseOver' Value='True'><Setter Property='Background' Value='" + ControlColor + @"' /></Trigger>
      <Trigger Property='IsPressed' Value='True'><Setter Property='Background' Value='#38332A' /></Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key='CloseCaption' TargetType='Button' BasedOn='{StaticResource Caption}'>
    <Style.Triggers>
      <Trigger Property='IsMouseOver' Value='True'>
        <Setter Property='Background' Value='#C42B1C' />
        <Setter Property='Foreground' Value='White' />
      </Trigger>
      <Trigger Property='IsPressed' Value='True'>
        <Setter Property='Background' Value='#B02718' />
        <Setter Property='Foreground' Value='White' />
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style TargetType='ComboBox'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource Focus}' />
    <Setter Property='Foreground' Value='" + TextColor + @"' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='ComboBox'>
          <Grid x:Name='Root'>
            <ToggleButton Focusable='False' ClickMode='Press'
                          IsChecked='{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}'>
              <ToggleButton.Template>
                <ControlTemplate TargetType='ToggleButton'>
                  <Border Background='" + BackgroundColor + @"' BorderBrush='" + TextColor + @"' BorderThickness='1'>
                    <Path HorizontalAlignment='Right' VerticalAlignment='Center' Margin='0,0,12,0' Stroke='" + TextColor + @"' StrokeThickness='2'
                          Data='M0,0 L4,4 L8,0' />
                  </Border>
                </ControlTemplate>
              </ToggleButton.Template>
            </ToggleButton>
            <ContentPresenter IsHitTestVisible='False' Margin='12,0,36,0' VerticalAlignment='Center' HorizontalAlignment='Left'
                              Content='{TemplateBinding SelectionBoxItem}' ContentTemplate='{TemplateBinding SelectionBoxItemTemplate}' />
            <!-- The list overlaps the box's bottom edge, with room around it for its shadow. -->
            <Popup x:Name='PART_Popup' AllowsTransparency='True' Placement='Bottom' VerticalOffset='-1' Focusable='False'
                   IsOpen='{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}'>
              <Grid Margin='0,0,3,3' MinWidth='{Binding ActualWidth, ElementName=Root}' MaxHeight='{TemplateBinding MaxDropDownHeight}'>
                <Border Background='" + TextColor + @"' Margin='3,3,-3,-3' />
                <Border Background='" + BackgroundColor + @"' BorderBrush='" + TextColor + @"' BorderThickness='1'>
                  <ScrollViewer VerticalScrollBarVisibility='Auto'><ItemsPresenter /></ScrollViewer>
                </Border>
              </Grid>
            </Popup>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property='IsEnabled' Value='False'><Setter TargetName='Root' Property='Opacity' Value='0.5' /></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType='ComboBoxItem'>
    <Setter Property='Foreground' Value='" + TextColor + @"' />
    <Setter Property='FocusVisualStyle' Value='{x:Null}' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='ComboBoxItem'>
          <Border x:Name='Box' Background='Transparent' Padding='12,10'>
            <ContentPresenter />
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property='IsSelected' Value='True'><Setter TargetName='Box' Property='Background' Value='" + ControlColor + @"' /></Trigger>
            <Trigger Property='IsHighlighted' Value='True'>
              <Setter TargetName='Box' Property='Background' Value='" + HighlightColor + @"' />
              <Setter Property='Foreground' Value='" + OnHighlightColor + @"' />
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType='ScrollBar'>
    <Setter Property='Width' Value='6' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='ScrollBar'>
          <Track x:Name='PART_Track' IsDirectionReversed='True'>
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType='Thumb'>
                    <Border Background='" + TextColor + @"' Margin='1,2' />
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- Tooltips open in their own window, so they're given the app's font directly. -->
  <Style TargetType='ToolTip'>
    <Setter Property='OverridesDefaultStyle' Value='True' />
    <Setter Property='HasDropShadow' Value='False' />
    <Setter Property='FontFamily' Value='{DynamicResource AppFont}' />
    <Setter Property='FontSize' Value='12' />
    <Setter Property='Foreground' Value='" + TextColor + @"' />
    <Setter Property='MaxWidth' Value='250' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='ToolTip'>
          <Grid Margin='0,0,3,3'>
            <Border Background='" + TextColor + @"' Margin='3,3,-3,-3' />
            <Border Background='" + BackgroundColor + @"' BorderBrush='" + TextColor + @"' BorderThickness='2' Padding='8,6'>
              <ContentPresenter>
                <ContentPresenter.Resources>
                  <Style TargetType='TextBlock'><Setter Property='TextWrapping' Value='Wrap' /></Style>
                </ContentPresenter.Resources>
              </ContentPresenter>
            </Border>
          </Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>";
}
