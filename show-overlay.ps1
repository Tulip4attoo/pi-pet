param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath,

    [double]$X = 100,
    [double]$Y = 100,
    [double]$Width = 0,
    [double]$Height = 0,
    [double]$Opacity = 1.0,
    [double]$Duration = 0,

    # Pixel-art/alpha fixes
    [switch]$Nearest,
    [int]$AlphaThreshold = 0,
    [string]$TransparentColor = "",
    [int]$ColorTolerance = 0,

    [switch]$ClickThrough,
    [switch]$NoTopmost
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class OverlayWin32 {
    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_NOACTIVATE = 0x08000000;
}
"@

function Parse-RgbColor([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $value = $Text.Trim()
    if ($value.StartsWith("#")) { $value = $value.Substring(1) }

    if ($value -match '^[0-9a-fA-F]{6}$') {
        return @(
            [Convert]::ToInt32($value.Substring(0, 2), 16),
            [Convert]::ToInt32($value.Substring(2, 2), 16),
            [Convert]::ToInt32($value.Substring(4, 2), 16)
        )
    }

    $parts = $value -split ','
    if ($parts.Count -eq 3) {
        return @([int]$parts[0], [int]$parts[1], [int]$parts[2])
    }

    throw "Invalid -TransparentColor '$Text'. Use #RRGGBB or R,G,B."
}

function New-CleanBitmapSource($Source, [int]$AlphaThreshold, [int[]]$TransparentRgb, [int]$ColorTolerance) {
    if ($AlphaThreshold -le 0 -and $null -eq $TransparentRgb) { return $Source }

    $converted = New-Object Windows.Media.Imaging.FormatConvertedBitmap
    $converted.BeginInit()
    $converted.Source = $Source
    $converted.DestinationFormat = [Windows.Media.PixelFormats]::Bgra32
    $converted.EndInit()

    $w = $converted.PixelWidth
    $h = $converted.PixelHeight
    $stride = $w * 4
    $pixels = New-Object byte[] ($stride * $h)
    $converted.CopyPixels($pixels, $stride, 0)

    $tol = [Math]::Max(0, $ColorTolerance)
    for ($i = 0; $i -lt $pixels.Length; $i += 4) {
        $b = [int]$pixels[$i]
        $g = [int]$pixels[$i + 1]
        $r = [int]$pixels[$i + 2]
        $a = [int]$pixels[$i + 3]

        $makeTransparent = $false
        if ($AlphaThreshold -gt 0 -and $a -le $AlphaThreshold) {
            $makeTransparent = $true
        }
        elseif ($null -ne $TransparentRgb) {
            if ([Math]::Abs($r - $TransparentRgb[0]) -le $tol -and
                [Math]::Abs($g - $TransparentRgb[1]) -le $tol -and
                [Math]::Abs($b - $TransparentRgb[2]) -le $tol) {
                $makeTransparent = $true
            }
        }

        if ($makeTransparent) {
            $pixels[$i] = 0
            $pixels[$i + 1] = 0
            $pixels[$i + 2] = 0
            $pixels[$i + 3] = 0
        }
    }

    $clean = New-Object Windows.Media.Imaging.WriteableBitmap $w, $h, $converted.DpiX, $converted.DpiY, ([Windows.Media.PixelFormats]::Bgra32), $null
    $rect = New-Object Windows.Int32Rect 0, 0, $w, $h
    $clean.WritePixels($rect, $pixels, $stride, 0)
    $clean.Freeze()
    return $clean
}

$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).ProviderPath

$bitmap = New-Object Windows.Media.Imaging.BitmapImage
$bitmap.BeginInit()
$bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$bitmap.UriSource = [Uri]::new($resolvedImage, [UriKind]::Absolute)
$bitmap.EndInit()
$bitmap.Freeze()

$transparentRgb = Parse-RgbColor $TransparentColor
$bitmapSource = New-CleanBitmapSource $bitmap $AlphaThreshold $transparentRgb $ColorTolerance

$image = New-Object Windows.Controls.Image
$image.Source = $bitmapSource
$image.Stretch = [Windows.Media.Stretch]::Uniform
$image.IsHitTestVisible = -not $ClickThrough
$image.SnapsToDevicePixels = $true
if ($Nearest) {
    $image.SetValue([Windows.Media.RenderOptions]::BitmapScalingModeProperty, [Windows.Media.BitmapScalingMode]::NearestNeighbor)
    $image.SetValue([Windows.Media.RenderOptions]::EdgeModeProperty, [Windows.Media.EdgeMode]::Aliased)
}

$window = New-Object Windows.Window
$window.WindowStyle = [Windows.WindowStyle]::None
$window.ResizeMode = [Windows.ResizeMode]::NoResize
$window.AllowsTransparency = $true
$window.Background = [Windows.Media.Brushes]::Transparent
$window.ShowInTaskbar = $false
$window.Topmost = -not $NoTopmost
$window.Left = $X
$window.Top = $Y
$window.Width = $(if ($Width -gt 0) { $Width } else { $bitmapSource.Width })
$window.Height = $(if ($Height -gt 0) { $Height } else { $bitmapSource.Height })
$window.Opacity = [Math]::Max(0.0, [Math]::Min(1.0, $Opacity))
$window.Content = $image
$window.UseLayoutRounding = $true

$window.Add_KeyDown({
    if ($_.Key -eq [Windows.Input.Key]::Escape) {
        $this.Close()
    }
})

if ($ClickThrough) {
    $window.Add_SourceInitialized({
        $helper = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $this
        $handle = $helper.Handle
        $style = [OverlayWin32]::GetWindowLong($handle, [OverlayWin32]::GWL_EXSTYLE)
        $style = $style -bor [OverlayWin32]::WS_EX_TRANSPARENT -bor [OverlayWin32]::WS_EX_TOOLWINDOW -bor [OverlayWin32]::WS_EX_LAYERED -bor [OverlayWin32]::WS_EX_NOACTIVATE
        [void][OverlayWin32]::SetWindowLong($handle, [OverlayWin32]::GWL_EXSTYLE, $style)
    })
}

if ($Duration -gt 0) {
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds($Duration)
    $timer.Add_Tick({
        $timer.Stop()
        $window.Close()
    })
    $timer.Start()
}

$app = New-Object Windows.Application
[void]$app.Run($window)
