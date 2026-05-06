param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [string]$StatePath,

    [double]$DefaultX = 120,
    [double]$DefaultY = 120,

    [string]$ManagerVersion = "3"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

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
    $item.LastSeq = if ($Command.seq) { [string]$Command.seq } else { $null }
    $item.LastWriteUtc = $LastWriteUtc
    Set-BubbleItem $item $Command
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

$window = New-Object Windows.Window
$window.WindowStyle = [Windows.WindowStyle]::None
$window.ResizeMode = [Windows.ResizeMode]::NoResize
$window.AllowsTransparency = $true
$window.Background = [Windows.Media.Brushes]::Transparent
$window.ShowInTaskbar = $false
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

$window.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed) {
        try { $window.DragMove() } catch {}
        Save-State
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
