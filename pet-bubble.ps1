param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [string]$StatePath,

    [double]$DefaultX = 120,
    [double]$DefaultY = 120,

    [string]$ManagerVersion = "7"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PiPetBubbleWin32 {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
}
"@

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\PiPetBubbleOverlayManager", [ref]$createdNew)
if (-not $createdNew) {
    # Existing manager process will pick up command files.
    exit 0
}

function Ensure-Directory([string]$Path) {
    if ($Path -and -not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-ParentDirectory([string]$Path) {
    $parent = Split-Path -Parent $Path
    if ($parent) { Ensure-Directory $parent }
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-WslRootFromUnc([string]$Path) {
    # Example: \\wsl.localhost\Ubuntu-24.04\home\... -> \\wsl.localhost\Ubuntu-24.04
    if ($Path -match '^(\\\\wsl(?:\.localhost)?\\[^\\]+)\\') { return $Matches[1] }
    return $null
}

function ConvertTo-WindowHandle([Int64]$Handle) {
    if ($Handle -le 0) { return [IntPtr]::Zero }
    return [IntPtr]::new($Handle)
}

function Test-WindowHandle([Int64]$Handle) {
    if ($Handle -le 0) { return $false }
    try { return [PiPetBubbleWin32]::IsWindow((ConvertTo-WindowHandle $Handle)) } catch { return $false }
}

function Get-WindowTitle([IntPtr]$Handle) {
    try {
        $builder = New-Object System.Text.StringBuilder 512
        [void][PiPetBubbleWin32]::GetWindowText($Handle, $builder, $builder.Capacity)
        return $builder.ToString()
    }
    catch {
        return ""
    }
}

function Get-OverlayWindowHandle {
    if ($script:windowHandle -and $script:windowHandle -ne [IntPtr]::Zero) { return $script:windowHandle }
    try {
        if ($null -ne $window) {
            $script:windowHandle = (New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $window).Handle
        }
    }
    catch {}
    return $script:windowHandle
}

function Set-OverlayNoActivate {
    try {
        $handle = Get-OverlayWindowHandle
        if ($handle -eq [IntPtr]::Zero) { return }

        $style = [PiPetBubbleWin32]::GetWindowLong($handle, [PiPetBubbleWin32]::GWL_EXSTYLE)
        $style = $style -bor [PiPetBubbleWin32]::WS_EX_TOOLWINDOW -bor [PiPetBubbleWin32]::WS_EX_NOACTIVATE
        [void][PiPetBubbleWin32]::SetWindowLong($handle, [PiPetBubbleWin32]::GWL_EXSTYLE, $style)
    }
    catch {}
}

function Get-CurrentForegroundTarget {
    try {
        $handle = [PiPetBubbleWin32]::GetForegroundWindow()
        if ($handle -eq [IntPtr]::Zero) { return $null }

        $overlayHandle = Get-OverlayWindowHandle
        if ($overlayHandle -ne [IntPtr]::Zero -and $handle -eq $overlayHandle) { return $null }

        [uint32]$windowProcessId = 0
        [void][PiPetBubbleWin32]::GetWindowThreadProcessId($handle, [ref]$windowProcessId)
        if ($windowProcessId -eq [uint32]$PID) { return $null }

        return @{
            Hwnd = $handle.ToInt64()
            ProcessId = [int]$windowProcessId
            Title = Get-WindowTitle $handle
        }
    }
    catch {
        return $null
    }
}

function Set-BubbleFocusTarget($Item, $Command) {
    if ($null -eq $Item) { return }

    if ($Command -and ($Command.PSObject.Properties.Name -contains "focusHwnd")) {
        try {
            $explicitHandle = [Int64]$Command.focusHwnd
            if (Test-WindowHandle $explicitHandle) {
                $Item.FocusHwnd = $explicitHandle
                if ($Command.PSObject.Properties.Name -contains "focusProcessId") { $Item.FocusProcessId = [int]$Command.focusProcessId }
                if ($Command.PSObject.Properties.Name -contains "focusTitle") { $Item.FocusTitle = [string]$Command.focusTitle }
                return
            }
        }
        catch {}
    }

    if ($null -ne $Item.FocusHwnd -and (Test-WindowHandle ([Int64]$Item.FocusHwnd))) { return }

    $target = Get-CurrentForegroundTarget
    if ($null -eq $target) { return }

    $Item.FocusHwnd = $target.Hwnd
    $Item.FocusProcessId = $target.ProcessId
    $Item.FocusTitle = $target.Title
}

function Activate-WindowHandle([Int64]$Handle) {
    if (-not (Test-WindowHandle $Handle)) { return $false }

    try {
        $hwnd = ConvertTo-WindowHandle $Handle
        # SW_RESTORE = 9, SW_SHOW = 5
        if ([PiPetBubbleWin32]::IsIconic($hwnd)) {
            [void][PiPetBubbleWin32]::ShowWindow($hwnd, 9)
        }
        else {
            [void][PiPetBubbleWin32]::ShowWindow($hwnd, 5)
        }
        [void][PiPetBubbleWin32]::BringWindowToTop($hwnd)
        return [PiPetBubbleWin32]::SetForegroundWindow($hwnd)
    }
    catch {
        return $false
    }
}

function Find-TerminalWindow($Item) {
    try {
        $terminalProcessNames = @("WindowsTerminal", "wt", "OpenConsole", "conhost", "mintty", "wezterm-gui", "alacritty", "kitty", "Tabby", "FluentTerminal")
        $dir = if ($Item.Command -and $Item.Command.dir) { [string]$Item.Command.dir } else { "" }
        $leaf = if ($dir) { Split-Path -Leaf $dir } else { "" }
        $focusTitle = if ($Item.FocusTitle) { [string]$Item.FocusTitle } else { "" }
        $focusProcessId = if ($Item.FocusProcessId) { [int]$Item.FocusProcessId } else { 0 }

        $scored = foreach ($process in (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle) })) {
            $name = [string]$process.ProcessName
            $title = [string]$process.MainWindowTitle
            $isTerminal = $terminalProcessNames -contains $name
            $score = 0

            if ($focusProcessId -gt 0 -and $process.Id -eq $focusProcessId) { $score += 1000 }
            if ($focusTitle -and $title -eq $focusTitle) { $score += 400 }
            elseif ($focusTitle -and $title.Contains($focusTitle)) { $score += 200 }
            if ($dir -and $title.Contains($dir)) { $score += 120 }
            if ($leaf -and $title.Contains($leaf)) { $score += 60 }

            if ($score -gt 0 -or $isTerminal) {
                [pscustomobject]@{
                    Handle = $process.MainWindowHandle.ToInt64()
                    Score = $score
                    IsTerminal = $isTerminal
                }
            }
        }

        $best = $scored | Where-Object { $_.Score -gt 0 } | Sort-Object Score -Descending | Select-Object -First 1
        if ($null -ne $best) { return [Int64]$best.Handle }

        $terminalOnly = @($scored | Where-Object { $_.IsTerminal })
        if ($terminalOnly.Count -eq 1) { return [Int64]$terminalOnly[0].Handle }
    }
    catch {}

    return $null
}

function Activate-BubbleTarget([string]$Id) {
    if (-not $items.ContainsKey($Id)) { return }

    $item = $items[$Id]
    if ($null -ne $item.FocusHwnd -and (Activate-WindowHandle ([Int64]$item.FocusHwnd))) { return }

    $fallbackHandle = Find-TerminalWindow $item
    if ($null -ne $fallbackHandle) { [void](Activate-WindowHandle ([Int64]$fallbackHandle)) }
}

function Get-BubbleIdFromSource($Source) {
    $current = $Source
    while ($null -ne $current) {
        if ($current -is [Windows.FrameworkElement] -and $current.Tag) { return [string]$current.Tag }
        try { $current = [Windows.Media.VisualTreeHelper]::GetParent($current) } catch { return $null }
    }
    return $null
}

function Test-WslPidActive($Command) {
    if ($null -eq $Command) { return $true }
    if (-not ($Command.PSObject.Properties.Name -contains "pid")) { return $true }

    $pidText = [string]$Command.pid
    if ([string]::IsNullOrWhiteSpace($pidText)) { return $true }
    if ($null -eq $script:wslRoot) { return $true }

    $statPath = "$script:wslRoot\proc\$pidText\stat"
    if (-not (Test-Path -LiteralPath $statPath)) { return $false }

    try {
        $stat = Get-Content -LiteralPath $statPath -Raw -ErrorAction Stop
        # /proc/<pid>/stat: pid (comm) state ... ; T = stopped by Ctrl+Z, Z = zombie/dead.
        if ($stat -match '^\d+ \(.+\) ([A-Z]) ') {
            $state = $Matches[1]
            if ($state -eq "T" -or $state -eq "Z" -or $state -eq "X") { return $false }
        }
    }
    catch {
        return $false
    }

    return $true
}

function Set-WindowInsideVirtualScreen {
    try {
        $screenLeft = [Windows.SystemParameters]::VirtualScreenLeft
        $screenTop = [Windows.SystemParameters]::VirtualScreenTop
        $screenRight = $screenLeft + [Windows.SystemParameters]::VirtualScreenWidth
        $screenBottom = $screenTop + [Windows.SystemParameters]::VirtualScreenHeight

        $width = if ($window.ActualWidth -gt 0) { $window.ActualWidth } elseif ($window.Width -gt 0) { $window.Width } else { 260 }
        $height = if ($window.ActualHeight -gt 0) { $window.ActualHeight } elseif ($window.Height -gt 0) { $window.Height } else { 80 }

        # Keep at least a useful part of the bubble visible if the saved position came from another monitor/resolution.
        $visibleMargin = 80
        $minLeft = $screenLeft
        $minTop = $screenTop
        $maxLeft = [Math]::Max($screenLeft, $screenRight - [Math]::Min($width, $visibleMargin))
        $maxTop = [Math]::Max($screenTop, $screenBottom - [Math]::Min($height, $visibleMargin))

        if ($window.Left -lt $minLeft) { $window.Left = $minLeft }
        elseif ($window.Left -gt $maxLeft) { $window.Left = $maxLeft }

        if ($window.Top -lt $minTop) { $window.Top = $minTop }
        elseif ($window.Top -gt $maxTop) { $window.Top = $maxTop }
    }
    catch {}
}

function Save-State {
    try {
        Ensure-ParentDirectory $StatePath
        @{
            x = [Math]::Round($window.Left, 0)
            y = [Math]::Round($window.Top, 0)
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }
    catch {}
}

function Get-StatusStyle([string]$Status) {
    switch ($Status.ToLowerInvariant()) {
        "thinking"  { return @{ Text = "Thinking...";  Border = "#99FBBF24"; Accent = "#FFFBBF24" } }
        "answering" { return @{ Text = "Answering..."; Border = "#9934D399"; Accent = "#FF34D399" } }
        "finished"  { return @{ Text = "Finished";   Border = "#9960A5FA"; Accent = "#FF60A5FA" } }
        default     { return @{ Text = $Status;       Border = "#99A78BFA"; Accent = "#FFA78BFA" } }
    }
}

function New-BubbleItem([string]$Id) {
    $outer = New-Object Windows.Controls.Grid
    $outer.Margin = New-Object Windows.Thickness 0, 0, 0, 7
    $outer.Tag = $Id

    $border = New-Object Windows.Controls.Border
    $border.CornerRadius = New-Object Windows.CornerRadius 14
    $border.Padding = New-Object Windows.Thickness 14, 10, 14, 11
    $border.BorderThickness = New-Object Windows.Thickness 1
    $border.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#E61B1B1F")
    $border.Effect = New-Object Windows.Media.Effects.DropShadowEffect
    $border.Effect.BlurRadius = 18
    $border.Effect.ShadowDepth = 3
    $border.Effect.Opacity = 0.35

    $content = New-Object Windows.Controls.StackPanel
    $content.Orientation = [Windows.Controls.Orientation]::Vertical

    $dirBlock = New-Object Windows.Controls.TextBlock
    $dirBlock.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#FF9CA3AF")
    $dirBlock.FontFamily = New-Object Windows.Media.FontFamily "Segoe UI"
    $dirBlock.FontSize = 12
    $dirBlock.FontWeight = [Windows.FontWeights]::SemiBold
    $dirBlock.TextWrapping = [Windows.TextWrapping]::NoWrap
    $dirBlock.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $dirBlock.MaxWidth = 480

    $statusBlock = New-Object Windows.Controls.TextBlock
    $statusBlock.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#FFFFFFFF")
    $statusBlock.FontFamily = New-Object Windows.Media.FontFamily "Segoe UI"
    $statusBlock.FontSize = 16
    $statusBlock.FontWeight = [Windows.FontWeights]::Medium
    $statusBlock.TextWrapping = [Windows.TextWrapping]::NoWrap
    $statusBlock.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $statusBlock.MaxWidth = 480
    $statusBlock.Margin = New-Object Windows.Thickness 0, 3, 0, 0

    $content.Children.Add($dirBlock) | Out-Null
    $content.Children.Add($statusBlock) | Out-Null
    $border.Child = $content

    $accentBar = New-Object Windows.Controls.Border
    $accentBar.Width = 4
    $accentBar.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $accentBar.VerticalAlignment = [Windows.VerticalAlignment]::Stretch
    $accentBar.CornerRadius = New-Object Windows.CornerRadius 14, 0, 0, 14
    $accentBar.IsHitTestVisible = $false

    $outer.Children.Add($border) | Out-Null
    $outer.Children.Add($accentBar) | Out-Null

    $menu = New-Object Windows.Controls.ContextMenu

    $showItem = New-Object Windows.Controls.MenuItem
    $showItem.Header = "Show window"
    $showItem.Tag = $Id
    $showItem.Add_Click({ Activate-BubbleTarget ([string]$this.Tag) })

    $closeItem = New-Object Windows.Controls.MenuItem
    $closeItem.Header = "Close pet"
    $closeItem.Tag = $Id
    $closeItem.Add_Click({ Remove-BubbleItem ([string]$this.Tag) -RemoveDirectory })

    $menu.Items.Add($showItem) | Out-Null
    $menu.Items.Add($closeItem) | Out-Null
    $outer.ContextMenu = $menu

    return @{
        Id = $Id
        Root = $outer
        Border = $border
        AccentBar = $accentBar
        DirBlock = $dirBlock
        StatusBlock = $statusBlock
        LastSeq = $null
        LastWriteUtc = [DateTime]::MinValue
        Command = $null
        FocusHwnd = $null
        FocusProcessId = $null
        FocusTitle = $null
    }
}

function Set-BubbleItem($Item, $Command) {
    $dir = if ($Command.dir) { [string]$Command.dir } else { "pi" }
    $status = if ($Command.status) { [string]$Command.status } else { "finished" }
    $style = Get-StatusStyle $status
    $text = if ($Command.text) { [string]$Command.text } else { $style.Text }

    $Item.DirBlock.Text = $dir
    $Item.StatusBlock.Text = $text
    $Item.Border.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString($style.Border)
    $Item.AccentBar.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($style.Accent)
    $Item.Command = $Command
}

function Sort-BubbleItems {
    $stack.Children.Clear()
    foreach ($item in ($items.Values | Sort-Object Id)) {
        $stack.Children.Add($item.Root) | Out-Null
    }
}

function Apply-Command([string]$Id, $Command, [DateTime]$LastWriteUtc) {
    if ($null -eq $Command) { return }

    if ($Command.PSObject.Properties.Name -contains "x") { $window.Left = [double]$Command.x }
    if ($Command.PSObject.Properties.Name -contains "y") { $window.Top = [double]$Command.y }

    $action = if ($Command.action) { [string]$Command.action } else { "set" }
    if ($action.ToLowerInvariant() -eq "stop") {
        Remove-BubbleItem $Id -RemoveDirectory
        return
    }

    if (-not $items.ContainsKey($Id)) {
        $items[$Id] = New-BubbleItem $Id
        Sort-BubbleItems
    }

    $item = $items[$Id]
    Set-BubbleFocusTarget $item $Command
    $item.LastSeq = if ($Command.seq) { [string]$Command.seq } else { $null }
    $item.LastWriteUtc = $LastWriteUtc
    Set-BubbleItem $item $Command
    Set-WindowInsideVirtualScreen
}

function Remove-BubbleItem([string]$Id, [switch]$RemoveDirectory) {
    $hadItem = $items.ContainsKey($Id)
    if ($hadItem) {
        $stack.Children.Remove($items[$Id].Root)
        $items.Remove($Id)
        Sort-BubbleItems
    }

    if ($RemoveDirectory) {
        $dirPath = Join-Path $RootPath $Id
        try { Remove-Item -LiteralPath $dirPath -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    if ($hadItem -and $items.Count -eq 0) {
        $window.Close()
    }
}

function Run-Watchdog {
    foreach ($id in @($items.Keys)) {
        $item = $items[$id]
        if (-not (Test-WslPidActive $item.Command)) {
            Remove-BubbleItem $id -RemoveDirectory
        }
    }
}

function Scan-Commands {
    Ensure-Directory $RootPath
    $dirs = Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $dirs) {
        $id = $dir.Name
        $commandPath = Join-Path $dir.FullName "command.json"
        if (-not (Test-Path -LiteralPath $commandPath)) { continue }

        $file = Get-Item -LiteralPath $commandPath -ErrorAction SilentlyContinue
        if ($null -eq $file) { continue }

        if ($items.ContainsKey($id) -and $file.LastWriteTimeUtc -le $items[$id].LastWriteUtc) { continue }

        $command = Read-JsonFile $commandPath
        if (-not (Test-WslPidActive $command)) {
            Remove-BubbleItem $id -RemoveDirectory
            continue
        }

        Apply-Command $id $command $file.LastWriteTimeUtc

        if ($command -and $command.action -and ([string]$command.action).ToLowerInvariant() -eq "stop") {
            try { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

Ensure-Directory $RootPath
Ensure-ParentDirectory $StatePath
$script:wslRoot = Get-WslRootFromUnc $RootPath

$state = Read-JsonFile $StatePath
$x = if ($state -and ($state.PSObject.Properties.Name -contains "x")) { [double]$state.x } else { $DefaultX }
$y = if ($state -and ($state.PSObject.Properties.Name -contains "y")) { [double]$state.y } else { $DefaultY }

$items = @{}
$script:windowHandle = [IntPtr]::Zero

$window = New-Object Windows.Window
$window.WindowStyle = [Windows.WindowStyle]::None
$window.ResizeMode = [Windows.ResizeMode]::NoResize
$window.AllowsTransparency = $true
$window.Background = [Windows.Media.Brushes]::Transparent
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.Focusable = $false
$window.Topmost = $true
$window.SizeToContent = [Windows.SizeToContent]::WidthAndHeight
$window.Left = $x
$window.Top = $y
$window.MinWidth = 260
$window.MaxWidth = 520
$window.UseLayoutRounding = $true

$stack = New-Object Windows.Controls.StackPanel
$stack.Orientation = [Windows.Controls.Orientation]::Vertical
$stack.Margin = New-Object Windows.Thickness 0
$window.Content = $stack

$window.Add_SourceInitialized({
    try { $script:windowHandle = (New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $window).Handle } catch {}
    Set-OverlayNoActivate
    Set-WindowInsideVirtualScreen
})

$window.Add_ContentRendered({
    Set-WindowInsideVirtualScreen
    Save-State
})

$window.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed) {
        $bubbleId = Get-BubbleIdFromSource $_.OriginalSource
        $startLeft = $window.Left
        $startTop = $window.Top

        try { $window.DragMove() } catch {}
        Save-State

        $moved = ([Math]::Abs($window.Left - $startLeft) -gt 3 -or [Math]::Abs($window.Top - $startTop) -gt 3)
        if ($bubbleId -and -not $moved) {
            Activate-BubbleTarget $bubbleId
        }
    }
})

$window.Add_LocationChanged({ Save-State })

$window.Add_KeyDown({
    if ($_.Key -eq [Windows.Input.Key]::Escape) {
        $window.Close()
    }
})

Scan-Commands

$timer = New-Object Windows.Threading.DispatcherTimer
$script:lastWatchdogUtc = [DateTime]::MinValue
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    try {
        Scan-Commands
        $now = [DateTime]::UtcNow
        if (($now - $script:lastWatchdogUtc).TotalSeconds -ge 1) {
            $script:lastWatchdogUtc = $now
            Run-Watchdog
        }
    } catch {}
})
$timer.Start()

$window.Add_Closed({
    try { Save-State } catch {}
    try { $timer.Stop() } catch {}
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
})

$app = New-Object Windows.Application
[void]$app.Run($window)
