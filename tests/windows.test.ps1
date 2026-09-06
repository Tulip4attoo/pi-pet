$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert $threw $Message
}

Get-ChildItem -LiteralPath $root -Filter '*.ps1' | ForEach-Object {
    [void][scriptblock]::Create([IO.File]::ReadAllText($_.FullName))
}

# Load only pure manager helpers; do not open a window or take the global mutex.
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'pet-bubble.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Test-OwnerPidActive', 'Get-PetAnimationSpec', 'Read-JsonFile', 'Ensure-OverlayTopmost')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
# Simulate an HWND that still has WS_EX_TOPMOST but has been covered by another
# topmost window. The watchdog must reassert z-order without moving or activating.
Add-Type @'
using System;
public static class PiPetBubbleWin32 {
    public const int GWL_EXSTYLE = -20, WS_EX_TOPMOST = 8;
    public const uint SWP_NOSIZE = 1, SWP_NOMOVE = 2, SWP_NOACTIVATE = 16, SWP_NOOWNERZORDER = 512;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static int Calls;
    public static uint Flags;
    public static IntPtr Target;
    public static int GetWindowLong(IntPtr hwnd, int index) { return WS_EX_TOPMOST; }
    public static bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags) {
        Calls++; Flags = flags; Target = after; return true;
    }
}
'@
function Get-OverlayWindowHandle { return [IntPtr]::new(123) }
$script:petViewRoot = $null
Ensure-OverlayTopmost
Ensure-OverlayTopmost
Assert ([PiPetBubbleWin32]::Calls -eq 2) 'repair z-order even when HWND already has topmost style'
Assert ([PiPetBubbleWin32]::Target -eq [PiPetBubbleWin32]::HWND_TOPMOST) 'raise into topmost band'
Assert ([PiPetBubbleWin32]::Flags -eq (1 -bor 2 -bor 16 -bor 512)) 'preserve focus, position, size and owner z-order'
$script:petViewRoot = [pscustomobject]@{ ContextMenu = [pscustomobject]@{ IsOpen = $true } }
Ensure-OverlayTopmost
Assert ([PiPetBubbleWin32]::Calls -eq 2) 'do not cover pet context menu'
$script:petViewRoot.ContextMenu.IsOpen = $false
Ensure-OverlayTopmost
Assert ([PiPetBubbleWin32]::Calls -eq 3) 'resume z-order repair after menu closes'
$script:petViewRoot = $null

$script:wslRoot = $null
Assert (Test-OwnerPidActive ([pscustomobject]@{ pid = "$PID"; platform = 'win32' })) 'live Windows owner'
Assert (-not (Test-OwnerPidActive ([pscustomobject]@{ pid = '2147483647'; platform = 'win32' }))) 'dead Windows owner'
Assert (-not (Test-OwnerPidActive ([pscustomobject]@{ pid = 'invalid'; platform = 'win32' }))) 'invalid Windows PID'
Assert (Test-OwnerPidActive ([pscustomobject]@{ pid = '2147483647' })) 'legacy WSL PID is not checked as Windows'
Assert ((Get-PetAnimationSpec 'running').Row -eq 7) 'sprite contract unchanged'

. (Join-Path $root 'pet-install.ps1')
Initialize-PetImageTools
Assert ((Get-PetTarget 'luffy').Slug -eq 'luffy') 'Petdex bare slug'
Assert ((Get-PetTarget 'https://codex-pets.net/#/pets/dario').Codex) 'Codex hash route'
Assert ((Get-PetTarget 'https://codex-pets.net/api/pets/dario/download').Slug -eq 'dario') 'Codex download route'
Assert ((Get-PetTarget 'https://petdex.crafter.run/pets/luffy').Slug -eq 'luffy') 'Petdex URL'
foreach ($slug in @('..', '.', '../escape', 'CON', 'LPT1.txt', 'trailing.')) {
    Assert-Throws { Assert-PetSlug $slug } "reject slug $slug"
}
Assert-Throws { Get-PetTarget 'https://example.com/pets/luffy' } 'reject unsupported source'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('pi-pet test ' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
try {
    $pack = Join-Path $temp 'pack'
    [IO.Directory]::CreateDirectory((Join-Path $pack 'nested')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'pets/default/spritesheet.clean.png') -Destination (Join-Path $pack 'nested/sprite.png')
    [IO.File]::WriteAllText((Join-Path $pack 'pet.json'), '{"id":"test-pet","displayName":"Test","spritesheetPath":"nested/sprite.png"}')
    $zip = Join-Path $temp 'pet.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($pack, $zip)
    $bytes = [IO.File]::ReadAllBytes($zip)
    $pets = Join-Path $temp 'user pets'
    $dest = Install-PetPack 'requested-slug' $bytes $pets
    Assert ((Split-Path -Leaf $dest) -eq 'test-pet') 'manifest ID becomes installed slug'
    Assert (([IO.File]::ReadAllText((Join-Path $pets 'active'))).Trim() -eq 'test-pet') 'installed pet activated'
    $manifest = Read-JsonFile (Join-Path $dest 'pet.json')
    Assert ($manifest.spritesheetPath -eq 'spritesheet.clean.png') 'clean PNG used by renderer'
    Assert (Test-Path -LiteralPath (Join-Path $dest 'spritesheet.source.png')) 'source sprite retained'
    Assert (-not (Test-Path -LiteralPath (Join-Path $dest 'nested'))) 'archive paths not extracted'
    [void](Install-PetPack 'requested-slug' $bytes $pets)
    Assert-Throws { Install-PetPack 'test-pet' ([byte[]]@(1, 2, 3)) $pets } 'corrupt zip fails'
    Assert (Test-Path -LiteralPath (Join-Path $dest 'pet.json')) 'failed reinstall preserves old pet'
    Assert (@(Get-ChildItem -LiteralPath $pets -Directory -Filter '.install-*').Count -eq 0) 'staging directories removed'

    # Verify the chroma cleanup is alpha-aware and the fixed atlas is enforced.
    $pixels = New-Object byte[] (1536 * 1872 * 4)
    $pixels[0] = 200; $pixels[2] = 200; $pixels[3] = 120
    $pixels[4] = 200; $pixels[6] = 200; $pixels[7] = 255
    $image = [Windows.Media.Imaging.BitmapSource]::Create(1536, 1872, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $pixels, (1536 * 4))
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
    $source = Join-Path $temp 'chroma.png'
    $output = Join-Path $temp 'clean.png'
    $file = [IO.File]::Create($source)
    try { $encoder.Save($file) } finally { $file.Dispose() }
    Convert-PetSpritesheet $source $output
    $file = [IO.File]::OpenRead($output)
    try {
        $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create($file, [Windows.Media.Imaging.BitmapCreateOptions]::None, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $decoder.Frames[0].CopyPixels($pixels, (1536 * 4), 0)
        Assert ($pixels[3] -eq 0) 'transparent chroma removed'
        Assert ($pixels[7] -eq 255) 'opaque purple detail preserved'
    } finally { $file.Dispose() }
    Write-Output 'Windows offline tests passed.'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
