// The look of the app, with colours and sizes measured from the Mac version's screenshot (image.png).
using System.Windows.Media;

static class Theme
{
    const string AccentColor = "#CCE2FC";
    const string LabelColor = "#DEDEDE";
    const string LineColor = "#3D3C3B";
    const string CaptionPressedColor = "#4A4948";

    public static readonly SolidColorBrush Accent = Brush(AccentColor);
    public static readonly SolidColorBrush Background = Brush("#282726");
    public static readonly SolidColorBrush TitleBar = Brush("#302E2E");
    public static readonly SolidColorBrush Line = Brush(LineColor);
    public static readonly SolidColorBrush TitleText = Brush("#ADABAB");
    public static readonly SolidColorBrush Label = Brush(LabelColor);
    public static readonly SolidColorBrush Secondary = Brush("#9E9E9D");
    public static readonly SolidColorBrush Recording = Brush("#FF453A");
    public static readonly SolidColorBrush CaptionPressed = Brush(CaptionPressedColor);

    static SolidColorBrush Brush(string color)
    {
        var brush = (SolidColorBrush)new BrushConverter().ConvertFromString(color);
        brush.Freeze();
        return brush;
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
          <Rectangle Margin='-1' Stroke='" + AccentColor + @"' StrokeThickness='1' RadiusX='4' RadiusY='4' />
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType='Button'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource Focus}' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='Button'>
          <Border x:Name='Box' Background='Transparent'>
            <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' />
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='Box' Property='Opacity' Value='0.75' /></Trigger>
            <Trigger Property='IsPressed' Value='True'><Setter TargetName='Box' Property='Opacity' Value='0.5' /></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key='Pill' TargetType='Button'>
    <Setter Property='FocusVisualStyle' Value='{StaticResource Focus}' />
    <Setter Property='Foreground' Value='" + AccentColor + @"' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='Button'>
          <Border x:Name='Box' Background='#303031' CornerRadius='14' Padding='17,0'>
            <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' />
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='Box' Property='Background' Value='#3A3A3B' /></Trigger>
            <Trigger Property='IsPressed' Value='True'><Setter TargetName='Box' Property='Background' Value='#444445' /></Trigger>
            <Trigger Property='IsEnabled' Value='False'><Setter TargetName='Box' Property='Opacity' Value='0.5' /></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key='Caption' TargetType='Button'>
    <Setter Property='Focusable' Value='False' />
    <Setter Property='Width' Value='46' />
    <Setter Property='Height' Value='32' />
    <Setter Property='Background' Value='Transparent' />
    <Setter Property='Foreground' Value='" + LabelColor + @"' />
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
      <Trigger Property='IsMouseOver' Value='True'><Setter Property='Background' Value='" + LineColor + @"' /></Trigger>
      <Trigger Property='IsPressed' Value='True'><Setter Property='Background' Value='" + CaptionPressedColor + @"' /></Trigger>
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
    <Setter Property='Foreground' Value='" + AccentColor + @"' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='ComboBox'>
          <Grid x:Name='Root'>
            <ToggleButton Focusable='False' ClickMode='Press'
                          IsChecked='{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}'>
              <ToggleButton.Template>
                <ControlTemplate TargetType='ToggleButton'>
                  <Border x:Name='Box' Background='#303031' CornerRadius='5'>
                    <Path HorizontalAlignment='Right' VerticalAlignment='Center' Margin='0,0,10,0' Stroke='" + AccentColor + @"' StrokeThickness='1.2'
                          StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'
                          Data='M0,3.8 L3.6,0 L7.2,3.8 M0,6.7 L3.6,10.5 L7.2,6.7' />
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='Box' Property='Background' Value='#3A3A3B' /></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </ToggleButton.Template>
            </ToggleButton>
            <ContentPresenter IsHitTestVisible='False' Margin='13,0,24,0' VerticalAlignment='Center' HorizontalAlignment='Left'
                              Content='{TemplateBinding SelectionBoxItem}' ContentTemplate='{TemplateBinding SelectionBoxItemTemplate}' />
            <Popup x:Name='PART_Popup' AllowsTransparency='True' Placement='Bottom' VerticalOffset='3' Focusable='False'
                   IsOpen='{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}'>
              <Border Background='#302F2F' BorderBrush='" + LineColor + @"' BorderThickness='1' CornerRadius='6' Padding='0,4'
                      MinWidth='{Binding ActualWidth, ElementName=Root}' MaxHeight='{TemplateBinding MaxDropDownHeight}'>
                <ScrollViewer VerticalScrollBarVisibility='Auto'><ItemsPresenter /></ScrollViewer>
              </Border>
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
    <Setter Property='Foreground' Value='" + AccentColor + @"' />
    <Setter Property='FocusVisualStyle' Value='{x:Null}' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='ComboBoxItem'>
          <Border x:Name='Box' Background='Transparent' CornerRadius='4' Margin='4,0' Padding='9,3'>
            <ContentPresenter />
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property='IsHighlighted' Value='True'><Setter TargetName='Box' Property='Background' Value='#45464A' /></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType='ScrollBar'>
    <Setter Property='Width' Value='8' />
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='ScrollBar'>
          <Track x:Name='PART_Track' IsDirectionReversed='True'>
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType='Thumb'>
                    <Border Background='#66DEDEDE' CornerRadius='3' Margin='1,2' />
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType='ToolTip'>
    <Setter Property='Background' Value='#302F2F' />
    <Setter Property='Foreground' Value='" + LabelColor + @"' />
    <Setter Property='BorderBrush' Value='" + LineColor + @"' />
  </Style>
</ResourceDictionary>";
}
