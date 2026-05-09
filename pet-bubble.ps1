param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [string]$StatePath,

    [double]$DefaultX = 120,
    [double]$DefaultY = 120,

    [string]$ManagerVersion = "0.3.0"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PiPetBubbleWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

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

function Get-CursorPosition {
    try {
        $point = New-Object PiPetBubbleWin32+POINT
        if ([PiPetBubbleWin32]::GetCursorPos([ref]$point)) {
            # GetCursorPos returns physical screen pixels, while WPF Window.Left/Top
            # are device-independent pixels (DIPs). Convert to WPF units so drag
            # distance stays in sync with the cursor on scaled displays (125%-200%).
            $screenPoint = New-Object Windows.Point ([double]$point.X), ([double]$point.Y)
            try {
                if ($null -ne $window) {
                    $source = [Windows.PresentationSource]::FromVisual($window)
                    if ($null -ne $source -and $null -ne $source.CompositionTarget) {
                        return $source.CompositionTarget.TransformFromDevice.Transform($screenPoint)
                    }
                }
            }
            catch {}
            return $screenPoint
        }
    }
    catch {}
    return $null
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

function Test-SourceWithinPetView($Source) {
    if ($null -eq $script:petViewRoot) { return $false }

    $current = $Source
    while ($null -ne $current) {
        if ([object]::ReferenceEquals($current, $script:petViewRoot)) { return $true }
        try { $current = [Windows.Media.VisualTreeHelper]::GetParent($current) } catch { return $false }
    }
    return $false
}

function Activate-DefaultBubbleTarget {
    if ($items.Count -eq 0) { return }

    $target = $null
    foreach ($item in $items.Values) {
        if ($null -eq $target -or $item.LastWriteUtc -gt $target.LastWriteUtc) {
            $target = $item
        }
    }

    if ($null -ne $target) { Activate-BubbleTarget ([string]$target.Id) }
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

function Get-DefaultWindowPosition([double]$Width, [double]$Height) {
    try {
        $screenLeft = [Windows.SystemParameters]::VirtualScreenLeft
        $screenTop = [Windows.SystemParameters]::VirtualScreenTop
        $screenWidth = [Windows.SystemParameters]::VirtualScreenWidth
        $screenHeight = [Windows.SystemParameters]::VirtualScreenHeight
        $screenRight = $screenLeft + $screenWidth
        $screenBottom = $screenTop + $screenHeight

        $safeWidth = [Math]::Max(260.0, $Width)
        $safeHeight = [Math]::Max(120.0, $Height)
        $marginX = [Math]::Max(56.0, [Math]::Min(180.0, [Math]::Round($screenWidth * 0.045, 0)))
        $marginY = [Math]::Max(64.0, [Math]::Min(180.0, [Math]::Round($screenHeight * 0.075, 0)))

        return @{
            x = [Math]::Max($screenLeft, $screenRight - $safeWidth - $marginX)
            y = [Math]::Max($screenTop, $screenBottom - $safeHeight - $marginY)
        }
    }
    catch {
        return @{ x = $DefaultX; y = $DefaultY }
    }
}

function Move-WindowToDefaultPosition {
    try {
        $width = if ($window.ActualWidth -gt 0) { $window.ActualWidth } elseif ($window.Width -gt 0) { $window.Width } else { 600 }
        $height = if ($window.ActualHeight -gt 0) { $window.ActualHeight } elseif ($window.Height -gt 0) { $window.Height } else { 260 }
        $position = Get-DefaultWindowPosition $width $height
        $window.Left = [double]$position.x
        $window.Top = [double]$position.y
        Set-WindowInsideVirtualScreen
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
        "thinking"  { return @{ Text = "Working...";  Border = "#99FBBF24"; Accent = "#FFFBBF24" } }
        "answering" { return @{ Text = "Working...";  Border = "#9934D399"; Accent = "#FF34D399" } }
        "finished"  { return @{ Text = "Finished";   Border = "#9960A5FA"; Accent = "#FF60A5FA" } }
        default     { return @{ Text = $Status;       Border = "#99A78BFA"; Accent = "#FFA78BFA" } }
    }
}

function Get-DefaultPetDirectory {
    try {
        $petsRoot = Join-Path $PSScriptRoot "pets"
        if (-not (Test-Path -LiteralPath $petsRoot)) { return $null }

        $envPet = [string]$env:PI_PET_ACTIVE_PET
        if (-not [string]::IsNullOrWhiteSpace($envPet) -and $envPet -match '^[A-Za-z0-9._-]+$') {
            $candidate = Join-Path $petsRoot $envPet
            if (Test-Path -LiteralPath (Join-Path $candidate "pet.json")) { return $candidate }
        }

        $activePath = Join-Path $petsRoot "active"
        if (Test-Path -LiteralPath $activePath) {
            $active = (Get-Content -LiteralPath $activePath -Raw -ErrorAction SilentlyContinue).Trim()
            if ($active -match '^[A-Za-z0-9._-]+$') {
                $candidate = Join-Path $petsRoot $active
                if (Test-Path -LiteralPath (Join-Path $candidate "pet.json")) { return $candidate }
            }
        }

        foreach ($fallback in @("default", "einstein", "luffy")) {
            $candidate = Join-Path $petsRoot $fallback
            if (Test-Path -LiteralPath (Join-Path $candidate "pet.json")) { return $candidate }
        }

        $first = Get-ChildItem -LiteralPath $petsRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "pet.json") } |
            Sort-Object Name |
            Select-Object -First 1
        if ($null -ne $first) { return $first.FullName }
    }
    catch {}
    return $null
}

function Load-PetSpritesheet {
    $petDir = Get-DefaultPetDirectory
    if (-not $petDir) { return $null }

    try {
        $manifestPath = Join-Path $petDir "pet.json"
        $manifest = Read-JsonFile $manifestPath
        $spriteName = if ($manifest -and $manifest.spritesheetPath) { [string]$manifest.spritesheetPath } else { "spritesheet.webp" }
        $spritePath = Join-Path $petDir $spriteName
        if (-not (Test-Path -LiteralPath $spritePath)) { return $null }

        $resolved = (Resolve-Path -LiteralPath $spritePath).ProviderPath
        $bitmap = New-Object Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreColorProfile
        $bitmap.UriSource = [Uri]::new($resolved, [UriKind]::Absolute)
        $bitmap.EndInit()
        $bitmap.Freeze()

        if ($bitmap.PixelWidth -lt 1536 -or $bitmap.PixelHeight -lt 1872) { return $null }
        return $bitmap
    }
    catch {
        return $null
    }
}

function Get-PetAnimationSpec([string]$State) {
    $normalized = if ([string]::IsNullOrWhiteSpace($State)) { "idle" } else { $State.ToLowerInvariant() }
    switch ($normalized) {
        "running-right" { return @{ State = "running-right"; Row = 1; Frames = 8; Durations = @(90, 90, 90, 90, 90, 90, 90, 90); Loop = $true } }
        "running-left"  { return @{ State = "running-left";  Row = 2; Frames = 8; Durations = @(90, 90, 90, 90, 90, 90, 90, 90); Loop = $true } }
        "waving"        { return @{ State = "waving";        Row = 3; Frames = 4; Durations = @(130, 130, 160, 240); Loop = $false } }
        "jumping"       { return @{ State = "jumping";       Row = 4; Frames = 5; Durations = @(105, 105, 125, 145, 220); Loop = $false } }
        "failed"        { return @{ State = "failed";        Row = 5; Frames = 8; Durations = @(170, 170, 170, 170, 170, 170, 170, 220); Loop = $true } }
        "waiting"       { return @{ State = "waiting";       Row = 6; Frames = 6; Durations = @(280, 130, 130, 180, 180, 330); Loop = $true } }
        "running"       { return @{ State = "running";       Row = 7; Frames = 6; Durations = @(100, 100, 100, 100, 100, 115); Loop = $true } }
        "review"        { return @{ State = "review";        Row = 8; Frames = 6; Durations = @(190, 190, 220, 220, 260, 300); Loop = $true } }
        default          { return @{ State = "idle";          Row = 0; Frames = 6; Durations = @(280, 110, 110, 140, 140, 320); Loop = $true } }
    }
}

function Normalize-PetState([string]$State) {
    return (Get-PetAnimationSpec $State).State
}

function Start-PetAnimation([string]$State, [switch]$Transient, [string]$ReturnState) {
    if ($null -eq $script:petImage -or $null -eq $script:petSpritesheet) { return }

    try {
        $spec = Get-PetAnimationSpec $State
        $normalized = [string]$spec.State
        $return = if ([string]::IsNullOrWhiteSpace($ReturnState)) { $script:petBaseState } else { Normalize-PetState $ReturnState }
        if ([string]::IsNullOrWhiteSpace($return)) { $return = "idle" }

        if ($script:petCurrentState -eq $normalized -and $script:petTransient -eq [bool]$Transient) { return }

        $script:petCurrentState = $normalized
        $script:petTransient = [bool]$Transient
        $script:petReturnState = $return
        $script:petFrameIndex = 0
        $script:nextPetFrameUtc = [DateTime]::MinValue
        Update-PetFrame -Force
    }
    catch {}
}

function Set-PetBaseState([string]$State, [switch]$Interrupt) {
    $normalized = Normalize-PetState $State
    if ([string]::IsNullOrWhiteSpace($normalized)) { $normalized = "idle" }
    $script:petBaseState = $normalized

    if ($Interrupt -or -not $script:petTransient) {
        Start-PetAnimation $normalized
    }
}

function Start-PetTransient([string]$State, [string]$ReturnState) {
    $return = if ([string]::IsNullOrWhiteSpace($ReturnState)) { $script:petBaseState } else { $ReturnState }
    if ([string]::IsNullOrWhiteSpace($return)) { $return = "idle" }
    Start-PetAnimation $State -Transient -ReturnState $return
}

function Update-PetFrame([switch]$Force) {
    if ($null -eq $script:petImage -or $null -eq $script:petSpritesheet) { return }

    $now = [DateTime]::UtcNow
    if (-not $Force -and $now -lt $script:nextPetFrameUtc) { return }

    try {
        $spec = Get-PetAnimationSpec $script:petCurrentState
        $frameCount = [int]$spec.Frames
        if ($frameCount -le 0) { return }

        if ($script:petFrameIndex -ge $frameCount) {
            if ($script:petTransient -or -not [bool]$spec.Loop) {
                $return = if ([string]::IsNullOrWhiteSpace($script:petReturnState)) { $script:petBaseState } else { $script:petReturnState }
                if ([string]::IsNullOrWhiteSpace($return)) { $return = "idle" }
                Start-PetAnimation $return
                return
            }
            $script:petFrameIndex = 0
        }

        $frame = [int]$script:petFrameIndex
        $row = [int]$spec.Row
        $rect = New-Object Windows.Int32Rect ($frame * 192), ($row * 208), 192, 208
        $crop = New-Object Windows.Media.Imaging.CroppedBitmap -ArgumentList $script:petSpritesheet, $rect
        $crop.Freeze()
        $script:petImage.Source = $crop

        $durations = @($spec.Durations)
        $delay = if ($durations.Count -gt $frame) { [int]$durations[$frame] } else { 140 }
        $script:petFrameIndex = $frame + 1
        $script:nextPetFrameUtc = $now.AddMilliseconds($delay)
    }
    catch {}
}

function Get-CommandPetBaseState($Command) {
    if ($null -eq $Command) { return "idle" }
    $status = if ($Command.status) { ([string]$Command.status).ToLowerInvariant() } else { "finished" }
    switch ($status) {
        "thinking"  { return "running" }
        "answering" { return "running" }
        "running"   { return "running" }
        "working"   { return "running" }
        "busy"      { return "running" }
        "waiting"   { return "idle" }
        "idle"      { return "idle" }
        "ready"     { return "idle" }
        "finished"  { return "idle" }
        "done"      { return "idle" }
        "review"    { return "review" }
        "failed"    { return "failed" }
        "error"     { return "failed" }
        default      { return "idle" }
    }
}

function Get-BasePetStateFromItems {
    $latest = $null
    foreach ($item in $items.Values) {
        if ($null -eq $item.Command) { continue }
        if ($null -eq $latest -or $item.LastWriteUtc -gt $latest.LastWriteUtc) { $latest = $item }
    }

    foreach ($item in $items.Values) {
        if ((Get-CommandPetBaseState $item.Command) -eq "running") { return "running" }
    }

    if ($null -ne $latest) { return Get-CommandPetBaseState $latest.Command }
    return "idle"
}

function Update-PetAnimationFromCommand($Command, [bool]$IsNewItem) {
    if ($null -eq $script:petImage -or $null -eq $script:petSpritesheet) { return }

    $action = if ($Command -and $Command.action) { ([string]$Command.action).ToLowerInvariant() } else { "set" }
    $status = if ($Command -and $Command.status) { ([string]$Command.status).ToLowerInvariant() } else { "finished" }
    $base = Get-BasePetStateFromItems

    if ($base -eq "running" -or $base -eq "failed") {
        Set-PetBaseState $base -Interrupt
        return
    }

    Set-PetBaseState $base

    if ($action -eq "start" -or $IsNewItem) {
        Start-PetTransient "waving" $base
        return
    }

    if ($status -eq "finished" -or $status -eq "done") {
        Start-PetTransient "jumping" $base
        return
    }

    if ($status -eq "waving" -or $status -eq "hello") {
        Start-PetTransient "waving" $base
        return
    }

    if ($status -eq "jumping") {
        Start-PetTransient "jumping" $base
    }
}

function Get-UsageRingColor([double]$RemainingPercent, [string]$Role) {
    if ($RemainingPercent -le 12) { return [Windows.Media.BrushConverter]::new().ConvertFromString("#FFF87171") }
    if ($RemainingPercent -le 30) { return [Windows.Media.BrushConverter]::new().ConvertFromString("#FFFBBF24") }
    if ($Role -eq "secondary") { return [Windows.Media.BrushConverter]::new().ConvertFromString("#FF60A5FA") }
    return [Windows.Media.BrushConverter]::new().ConvertFromString("#FF34D399")
}

function Get-UsageRingPoint([double]$CenterX, [double]$CenterY, [double]$Radius, [double]$Percent) {
    $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
    # Match the Codex pet reference: the arc starts at the pet's feet (6 o'clock)
    # and grows counterclockwise, so the endpoint moves up the right side first.
    $angle = (90.0 - ($clamped / 100.0 * 360.0)) * [Math]::PI / 180.0
    return New-Object Windows.Point ($CenterX + [Math]::Cos($angle) * $Radius), ($CenterY + [Math]::Sin($angle) * $Radius)
}

function New-UsageArcGeometry([double]$CenterX, [double]$CenterY, [double]$Radius, [double]$Percent) {
    $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
    if ($clamped -le 0.01) { return [Windows.Media.Geometry]::Empty }

    $start = New-Object Windows.Point $CenterX, ($CenterY + $Radius)
    $geometry = New-Object Windows.Media.PathGeometry
    $figure = New-Object Windows.Media.PathFigure
    $figure.StartPoint = $start
    $figure.IsClosed = $false
    $figure.IsFilled = $false

    if ($clamped -ge 99.9) {
        $mid = New-Object Windows.Point $CenterX, ($CenterY - $Radius)
        $segment1 = New-Object Windows.Media.ArcSegment
        $segment1.Point = $mid
        $segment1.Size = New-Object Windows.Size $Radius, $Radius
        $segment1.SweepDirection = [Windows.Media.SweepDirection]::Counterclockwise
        $segment1.IsLargeArc = $false
        $segment2 = New-Object Windows.Media.ArcSegment
        $segment2.Point = $start
        $segment2.Size = New-Object Windows.Size $Radius, $Radius
        $segment2.SweepDirection = [Windows.Media.SweepDirection]::Counterclockwise
        $segment2.IsLargeArc = $false
        $figure.Segments.Add($segment1) | Out-Null
        $figure.Segments.Add($segment2) | Out-Null
    }
    else {
        $point = Get-UsageRingPoint $CenterX $CenterY $Radius $clamped
        $segment = New-Object Windows.Media.ArcSegment
        $segment.Point = $point
        $segment.Size = New-Object Windows.Size $Radius, $Radius
        $segment.SweepDirection = [Windows.Media.SweepDirection]::Counterclockwise
        $segment.IsLargeArc = $clamped -gt 50.0
        $figure.Segments.Add($segment) | Out-Null
    }

    $geometry.Figures.Add($figure) | Out-Null
    return $geometry
}

function New-UsageLabel {
    $border = New-Object Windows.Controls.Border
    $border.Width = 54
    $border.Height = 28
    $border.CornerRadius = New-Object Windows.CornerRadius 10
    $border.BorderThickness = New-Object Windows.Thickness 1
    $border.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#D90B1220")
    $border.Visibility = [Windows.Visibility]::Collapsed
    $border.IsHitTestVisible = $false

    $text = New-Object Windows.Controls.TextBlock
    $text.FontFamily = New-Object Windows.Media.FontFamily "Segoe UI"
    $text.FontSize = 15
    $text.FontWeight = [Windows.FontWeights]::Bold
    $text.Foreground = [Windows.Media.Brushes]::White
    $text.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $text.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $text.TextAlignment = [Windows.TextAlignment]::Center
    $border.Child = $text
    return $border
}

function Format-UsagePercent([double]$Percent) {
    return ("{0}%" -f [Math]::Round([Math]::Max(0.0, [Math]::Min(100.0, $Percent))))
}

function Set-UsageLabel($Label, [double]$CenterX, [double]$CenterY, [double]$Radius, [double]$Percent, $Brush, [double]$CanvasSize) {
    if ($null -eq $Label) { return }
    $Label.Child.Text = Format-UsagePercent $Percent
    $Label.BorderBrush = $Brush
    $point = Get-UsageRingPoint $CenterX $CenterY $Radius $Percent
    $left = [Math]::Max(0, [Math]::Min($CanvasSize - $Label.Width, $point.X - ($Label.Width / 2)))
    $top = [Math]::Max(0, [Math]::Min($CanvasSize - $Label.Height, $point.Y - ($Label.Height / 2)))
    [Windows.Controls.Canvas]::SetLeft($Label, $left)
    [Windows.Controls.Canvas]::SetTop($Label, $top)
}

function Set-UsageRingVisibility([Windows.Visibility]$Visibility) {
    foreach ($element in @($script:outerUsageTrack, $script:innerUsageTrack, $script:outerUsagePath, $script:innerUsagePath, $script:outerUsageLabel, $script:innerUsageLabel)) {
        if ($null -ne $element) { $element.Visibility = $Visibility }
    }
}

function Find-UsageLimit($Usage, [string[]]$Labels, [int]$FallbackIndex) {
    if ($null -eq $Usage -or -not ($Usage.PSObject.Properties.Name -contains "limits")) { return $null }
    $limits = @($Usage.limits)
    foreach ($label in $Labels) {
        $match = $limits | Where-Object { $_.label -and ([string]$_.label).ToLowerInvariant() -eq $label.ToLowerInvariant() } | Select-Object -First 1
        if ($null -ne $match) { return $match }
    }
    if ($limits.Count -gt $FallbackIndex) { return $limits[$FallbackIndex] }
    return $null
}

function Update-UsageRings($Usage) {
    if ($null -eq $script:outerUsagePath -or $null -eq $script:innerUsagePath) { return }

    $primary = Find-UsageLimit $Usage @("5h", "primary") 0
    $secondary = Find-UsageLimit $Usage @("7d", "weekly", "secondary") 1
    if ($null -eq $primary -and $null -eq $secondary) {
        Set-UsageRingVisibility ([Windows.Visibility]::Collapsed)
        return
    }

    Set-UsageRingVisibility ([Windows.Visibility]::Visible)
    $center = if ($script:petRingCenter) { [double]$script:petRingCenter } else { 95.0 }
    $outerRadius = if ($script:petOuterRingRadius) { [double]$script:petOuterRingRadius } else { 82.0 }
    $innerRadius = if ($script:petInnerRingRadius) { [double]$script:petInnerRingRadius } else { 69.0 }
    $canvasSize = if ($script:petRingSize) { [double]$script:petRingSize } else { 190.0 }
    $labelsMode = ([string]$env:PI_PET_USAGE_LABELS).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($labelsMode)) { $labelsMode = "off" }

    if ($null -ne $primary) {
        $percent = [double]$primary.remainingPercent
        $brush = Get-UsageRingColor $percent "primary"
        $script:outerUsagePath.Data = New-UsageArcGeometry $center $center $outerRadius $percent
        $script:outerUsagePath.Stroke = $brush
        if ($labelsMode -eq "off") { $script:outerUsageLabel.Visibility = [Windows.Visibility]::Collapsed }
        else {
            $script:outerUsageLabel.Visibility = [Windows.Visibility]::Visible
            Set-UsageLabel $script:outerUsageLabel $center $center $outerRadius $percent $brush $canvasSize
        }
    }
    else {
        $script:outerUsagePath.Visibility = [Windows.Visibility]::Collapsed
        $script:outerUsageLabel.Visibility = [Windows.Visibility]::Collapsed
    }

    if ($null -ne $secondary) {
        $percent = [double]$secondary.remainingPercent
        $brush = Get-UsageRingColor $percent "secondary"
        $script:innerUsagePath.Data = New-UsageArcGeometry $center $center $innerRadius $percent
        $script:innerUsagePath.Stroke = $brush
        if ($labelsMode -eq "off") { $script:innerUsageLabel.Visibility = [Windows.Visibility]::Collapsed }
        else {
            $script:innerUsageLabel.Visibility = [Windows.Visibility]::Visible
            Set-UsageLabel $script:innerUsageLabel $center $center $innerRadius $percent $brush $canvasSize
        }
    }
    else {
        $script:innerUsagePath.Visibility = [Windows.Visibility]::Collapsed
        $script:innerUsageLabel.Visibility = [Windows.Visibility]::Collapsed
    }
}

function New-UsageEllipse([double]$Radius, [double]$Center, [double]$Thickness, [string]$Color) {
    $ellipse = New-Object Windows.Shapes.Ellipse
    $ellipse.Width = $Radius * 2
    $ellipse.Height = $Radius * 2
    $ellipse.StrokeThickness = $Thickness
    $ellipse.Stroke = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    $ellipse.Visibility = [Windows.Visibility]::Collapsed
    $ellipse.IsHitTestVisible = $false
    [Windows.Controls.Canvas]::SetLeft($ellipse, $Center - $Radius)
    [Windows.Controls.Canvas]::SetTop($ellipse, $Center - $Radius)
    return $ellipse
}

function New-UsagePath([double]$Thickness) {
    $path = New-Object Windows.Shapes.Path
    $path.StrokeThickness = $Thickness
    # Use flat caps for usage arcs so very low percentages do not look inflated.
    $path.StrokeStartLineCap = [Windows.Media.PenLineCap]::Flat
    $path.StrokeEndLineCap = [Windows.Media.PenLineCap]::Flat
    $path.StrokeLineJoin = [Windows.Media.PenLineJoin]::Round
    $path.Visibility = [Windows.Visibility]::Collapsed
    $path.IsHitTestVisible = $false
    return $path
}

function New-PetView {
    $script:petSpritesheet = Load-PetSpritesheet
    if ($null -eq $script:petSpritesheet) { return $null }

    $script:petCellWidth = 192.0
    $script:petCellHeight = 208.0
    $scale = 0.5
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$env:PI_PET_SCALE)) {
            $scale = [double]$env:PI_PET_SCALE
        }
    } catch { $scale = 0.5 }
    $scale = [Math]::Max(0.35, [Math]::Min(2.0, $scale))

    $script:petRenderWidth = [Math]::Round($script:petCellWidth * $scale, 0)
    $script:petRenderHeight = [Math]::Round($script:petCellHeight * $scale, 0)
    # Keep the rings comfortably outside the pet silhouette. A smaller ring looks
    # clipped/covered for tall Codex cells, especially standing pets like Einstein.
    $ringPadding = [Math]::Max(70.0, [Math]::Round([Math]::Max($script:petRenderWidth, $script:petRenderHeight) * 0.50, 0))
    $ringMargin = [Math]::Max(14.0, [Math]::Round($ringPadding * 0.22, 0))
    $ringGap = [Math]::Max(10.0, [Math]::Round($ringPadding * 0.14, 0))
    $script:petRingSize = [Math]::Round([Math]::Max($script:petRenderWidth, $script:petRenderHeight) + $ringPadding, 0)
    $script:petRingCenter = $script:petRingSize / 2.0
    $script:petOuterRingRadius = $script:petRingCenter - $ringMargin
    $script:petInnerRingRadius = $script:petOuterRingRadius - $ringGap

    $root = New-Object Windows.Controls.Grid
    $root.Width = $script:petRingSize
    $root.Height = $script:petRingSize
    $root.Margin = New-Object Windows.Thickness 0, 0, 10, 0
    $root.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $root.Background = [Windows.Media.Brushes]::Transparent
    $root.IsHitTestVisible = $true
    $script:petViewRoot = $root

    $ringCanvas = New-Object Windows.Controls.Canvas
    $ringCanvas.Width = $script:petRingSize
    $ringCanvas.Height = $script:petRingSize

    $script:outerUsageTrack = New-UsageEllipse $script:petOuterRingRadius $script:petRingCenter 7 "#3AFFFFFF"
    $script:innerUsageTrack = New-UsageEllipse $script:petInnerRingRadius $script:petRingCenter 5 "#28FFFFFF"
    $script:outerUsagePath = New-UsagePath 7
    $script:innerUsagePath = New-UsagePath 5

    $ringCanvas.Children.Add($script:outerUsageTrack) | Out-Null
    $ringCanvas.Children.Add($script:innerUsageTrack) | Out-Null
    $ringCanvas.Children.Add($script:outerUsagePath) | Out-Null
    $ringCanvas.Children.Add($script:innerUsagePath) | Out-Null
    $root.Children.Add($ringCanvas) | Out-Null

    $image = New-Object Windows.Controls.Image
    $image.Width = $script:petRenderWidth
    $image.Height = $script:petRenderHeight
    $image.Stretch = [Windows.Media.Stretch]::Uniform
    $image.SnapsToDevicePixels = $true
    $image.IsHitTestVisible = $false
    $image.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $image.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $image.SetValue([Windows.Media.RenderOptions]::BitmapScalingModeProperty, [Windows.Media.BitmapScalingMode]::NearestNeighbor)
    $image.SetValue([Windows.Media.RenderOptions]::EdgeModeProperty, [Windows.Media.EdgeMode]::Aliased)
    $root.Children.Add($image) | Out-Null

    $labelCanvas = New-Object Windows.Controls.Canvas
    $labelCanvas.Width = $script:petRingSize
    $labelCanvas.Height = $script:petRingSize
    $script:outerUsageLabel = New-UsageLabel
    $script:innerUsageLabel = New-UsageLabel
    $labelCanvas.Children.Add($script:outerUsageLabel) | Out-Null
    $labelCanvas.Children.Add($script:innerUsageLabel) | Out-Null
    $root.Children.Add($labelCanvas) | Out-Null

    $script:petImage = $image
    $script:petBaseState = "idle"
    $script:petCurrentState = ""
    $script:petReturnState = "idle"
    $script:petTransient = $false
    $script:petFrameIndex = 0
    $script:nextPetFrameUtc = [DateTime]::MinValue
    Start-PetAnimation "idle"
    return $root
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
    $normalizedAction = $action.ToLowerInvariant()
    if ($normalizedAction -eq "stop") {
        Remove-BubbleItem $Id -RemoveDirectory
        return
    }
    if ($normalizedAction -eq "move") {
        if ($items.ContainsKey($Id)) { $items[$Id].LastWriteUtc = $LastWriteUtc }
        Set-WindowInsideVirtualScreen
        return
    }

    $isNewItem = -not $items.ContainsKey($Id)
    if ($isNewItem) {
        $items[$Id] = New-BubbleItem $Id
        Sort-BubbleItems
    }

    $item = $items[$Id]
    Set-BubbleFocusTarget $item $Command
    $item.LastSeq = if ($Command.seq) { [string]$Command.seq } else { $null }
    $item.LastWriteUtc = $LastWriteUtc
    Set-BubbleItem $item $Command
    Update-PetAnimationFromCommand $Command $isNewItem
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
    elseif ($hadItem) {
        Set-PetBaseState (Get-BasePetStateFromItems) -Interrupt
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

function Scan-Usage {
    Ensure-Directory $RootPath
    $dirs = Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue
    $latest = $null
    $latestScore = -1.0
    $latestKey = ""

    foreach ($dir in $dirs) {
        $usagePath = Join-Path $dir.FullName "usage.json"
        if (-not (Test-Path -LiteralPath $usagePath)) { continue }

        $file = Get-Item -LiteralPath $usagePath -ErrorAction SilentlyContinue
        if ($null -eq $file) { continue }

        $usage = Read-JsonFile $usagePath
        if ($null -eq $usage) { continue }

        $score = [double]$file.LastWriteTimeUtc.Ticks
        if ($usage.PSObject.Properties.Name -contains "fetchedAt") {
            try { $score = [double]$usage.fetchedAt } catch {}
        }

        if ($score -gt $latestScore) {
            $latest = $usage
            $latestScore = $score
            $latestKey = "$($dir.Name):$score"
        }
    }

    if ($latestKey -ne $script:lastUsageKey) {
        $script:lastUsageKey = $latestKey
        Update-UsageRings $latest
    }
}

Ensure-Directory $RootPath
Ensure-ParentDirectory $StatePath
$script:wslRoot = Get-WslRootFromUnc $RootPath

$state = Read-JsonFile $StatePath
$hasSavedPosition = $state -and ($state.PSObject.Properties.Name -contains "x") -and ($state.PSObject.Properties.Name -contains "y")
if ($hasSavedPosition) {
    $x = [double]$state.x
    $y = [double]$state.y
}
else {
    $initialPosition = Get-DefaultWindowPosition 600 260
    $x = [double]$initialPosition.x
    $y = [double]$initialPosition.y
}

$items = @{}
$script:windowHandle = [IntPtr]::Zero
$script:petViewRoot = $null
$script:usingDefaultPosition = -not $hasSavedPosition
$script:isDragging = $false
$script:dragMoved = $false
$script:dragBubbleId = $null
$script:dragPetClick = $false
$script:dragStartCursor = $null
$script:dragStartLeft = 0.0
$script:dragStartTop = 0.0
$script:dragLastDirection = ""

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
$window.MaxWidth = 720
$window.UseLayoutRounding = $true

$rootGrid = New-Object Windows.Controls.Grid
$rootGrid.Margin = New-Object Windows.Thickness 0

$petColumn = New-Object Windows.Controls.ColumnDefinition
$petColumn.Width = [Windows.GridLength]::Auto
$bubbleColumn = New-Object Windows.Controls.ColumnDefinition
$bubbleColumn.Width = [Windows.GridLength]::Auto
$rootGrid.ColumnDefinitions.Add($petColumn) | Out-Null
$rootGrid.ColumnDefinitions.Add($bubbleColumn) | Out-Null

$petView = New-PetView
if ($null -ne $petView) {
    [Windows.Controls.Grid]::SetColumn($petView, 0)
    $rootGrid.Children.Add($petView) | Out-Null
}

$stack = New-Object Windows.Controls.StackPanel
$stack.Orientation = [Windows.Controls.Orientation]::Vertical
$stack.Margin = New-Object Windows.Thickness 0
[Windows.Controls.Grid]::SetColumn($stack, 1)
$rootGrid.Children.Add($stack) | Out-Null

$window.Content = $rootGrid

$window.Add_SourceInitialized({
    try { $script:windowHandle = (New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $window).Handle } catch {}
    Set-OverlayNoActivate
    Set-WindowInsideVirtualScreen
})

$window.Add_ContentRendered({
    if ($script:usingDefaultPosition) {
        Move-WindowToDefaultPosition
        $script:usingDefaultPosition = $false
    }
    else {
        Set-WindowInsideVirtualScreen
    }
    Save-State
})

$window.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed) {
        $cursor = Get-CursorPosition
        if ($null -eq $cursor) { return }

        $script:isDragging = $true
        $script:dragMoved = $false
        $script:dragBubbleId = Get-BubbleIdFromSource $_.OriginalSource
        $script:dragPetClick = Test-SourceWithinPetView $_.OriginalSource
        $script:dragStartCursor = $cursor
        $script:dragStartLeft = [double]$window.Left
        $script:dragStartTop = [double]$window.Top
        $script:dragLastDirection = ""
        try { [void]$window.CaptureMouse() } catch {}
    }
})

$window.Add_MouseMove({
    if (-not $script:isDragging) { return }
    if ($_.LeftButton -ne [Windows.Input.MouseButtonState]::Pressed) { return }

    $cursor = Get-CursorPosition
    if ($null -eq $cursor -or $null -eq $script:dragStartCursor) { return }

    $dx = [double]$cursor.X - [double]$script:dragStartCursor.X
    $dy = [double]$cursor.Y - [double]$script:dragStartCursor.Y
    if ([Math]::Abs($dx) -le 3 -and [Math]::Abs($dy) -le 3) { return }

    $script:dragMoved = $true
    $window.Left = [double]$script:dragStartLeft + $dx
    $window.Top = [double]$script:dragStartTop + $dy

    if ([Math]::Abs($dx) -gt 3) {
        $direction = if ($dx -gt 0) { "running-right" } else { "running-left" }
        if ($script:dragLastDirection -ne $direction) {
            $script:dragLastDirection = $direction
            Start-PetAnimation $direction
        }
    }
})

$window.Add_MouseLeftButtonUp({
    if (-not $script:isDragging) { return }

    $moved = [bool]$script:dragMoved
    $bubbleId = $script:dragBubbleId
    $isPetClick = [bool]$script:dragPetClick

    $script:isDragging = $false
    $script:dragMoved = $false
    $script:dragBubbleId = $null
    $script:dragPetClick = $false
    $script:dragStartCursor = $null
    $script:dragLastDirection = ""
    try { $window.ReleaseMouseCapture() } catch {}

    if ($moved) {
        Save-State
        Set-PetBaseState (Get-BasePetStateFromItems) -Interrupt
        return
    }

    if ($bubbleId) {
        Activate-BubbleTarget ([string]$bubbleId)
    }
    elseif ($isPetClick) {
        Start-PetTransient "waving" $script:petBaseState
        Activate-DefaultBubbleTarget
    }
})

$window.Add_LocationChanged({ Save-State })

$window.Add_KeyDown({
    if ($_.Key -eq [Windows.Input.Key]::Escape) {
        $window.Close()
    }
})

Scan-Commands
Scan-Usage

$timer = New-Object Windows.Threading.DispatcherTimer
$script:lastWatchdogUtc = [DateTime]::MinValue
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    try {
        Scan-Commands
        Scan-Usage
        $now = [DateTime]::UtcNow
        if (($now - $script:lastWatchdogUtc).TotalSeconds -ge 1) {
            $script:lastWatchdogUtc = $now
            Run-Watchdog
        }
    } catch {}
})
$timer.Start()

$petTimer = New-Object Windows.Threading.DispatcherTimer
$petTimer.Interval = [TimeSpan]::FromMilliseconds(60)
$petTimer.Add_Tick({ try { Update-PetFrame } catch {} })
$petTimer.Start()

$window.Add_Closed({
    try { Save-State } catch {}
    try { $timer.Stop() } catch {}
    try { $petTimer.Stop() } catch {}
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
})

$app = New-Object Windows.Application
[void]$app.Run($window)
