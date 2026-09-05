param(
    [Parameter(Position = 0)]
    [string]$Target,
    [string]$PetsPath = $env:PI_PET_PETS_DIR
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Assert-PetSlug([string]$Slug) {
    if ([string]::IsNullOrWhiteSpace($Slug) -or $Slug -notmatch '^[A-Za-z0-9._-]+$' -or
        $Slug.EndsWith('.') -or $Slug -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        throw "Invalid pet slug: $Slug"
    }
    return $Slug
}

function Get-PetTarget([string]$Value) {
    $uri = $null
    if ([Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')) {
        $hostName = $uri.DnsSafeHost -replace '^www\.', ''
        if ($hostName -notin @('petdex.crafter.run', 'codex-pets.net')) {
            throw 'Use a Petdex slug or a petdex.crafter.run / codex-pets.net URL.'
        }
        $route = if ($uri.Fragment) { $uri.Fragment.TrimStart('#') } else { $uri.AbsolutePath }
        $parts = @((($route -split '\?')[0]).Trim('/') -split '/' | ForEach-Object { [Uri]::UnescapeDataString($_) })
        $index = [Array]::IndexOf($parts, 'pets')
        $slug = if ($index -ge 0 -and $index + 1 -lt $parts.Count) { $parts[$index + 1] } else { $parts[-1] }
        return @{ Slug = (Assert-PetSlug $slug); Codex = ($hostName -eq 'codex-pets.net'); Page = $Value }
    }
    return @{ Slug = (Assert-PetSlug $Value); Codex = $false; Page = "https://petdex.crafter.run/pets/$Value" }
}

function Get-PetBytes([string]$Url, [string]$Accept = '*/*') {
    $uri = [Uri]$Url
    if ($uri.Scheme -notin @('http', 'https')) { throw 'Pet downloads require HTTP(S).' }
    $request = [Net.HttpWebRequest]::Create($uri)
    $request.UserAgent = 'Mozilla/5.0 (pi-pet installer)'
    $request.Accept = $Accept
    $request.Referer = if ($uri.DnsSafeHost -eq 'codex-pets.net') { 'https://codex-pets.net/' } else { 'https://petdex.crafter.run/' }
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $response = $null
    $stream = $null
    $buffer = New-Object IO.MemoryStream
    try {
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $chunk = New-Object byte[] 65536
        while (($count = $stream.Read($chunk, 0, $chunk.Length)) -gt 0) {
            if ($buffer.Length + $count -gt 64MB) { throw 'Pet download exceeds 64 MB.' }
            $buffer.Write($chunk, 0, $count)
        }
        return ,$buffer.ToArray()
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $buffer.Dispose()
    }
}

function Get-PetJson([string]$Url) {
    return [Text.Encoding]::UTF8.GetString((Get-PetBytes $Url 'application/json')) | ConvertFrom-Json
}

function Resolve-PetZipUrl($Pet) {
    if ($Pet.Codex) {
        try {
            $data = Get-PetJson "https://codex-pets.net/api/pets/$($Pet.Slug)"
            if ($data.pet.downloadUrl) { return [Uri]::new([Uri]'https://codex-pets.net/', [string]$data.pet.downloadUrl).AbsoluteUri }
        } catch { Write-Warning "Could not read Codex Pets metadata: $_" }
        return "https://codex-pets.net/api/pets/$($Pet.Slug)/download"
    }

    try {
        $manifest = Get-PetJson 'https://petdex.crafter.run/api/manifest'
        $entry = $manifest.pets | Where-Object { $_.slug -eq $Pet.Slug } | Select-Object -First 1
        if ($entry.zipUrl) { return [Uri]::new([Uri]'https://petdex.crafter.run/', [string]$entry.zipUrl).AbsoluteUri }
    } catch { Write-Warning "Could not read Petdex manifest: $_" }

    $page = [Net.WebUtility]::HtmlDecode([Text.Encoding]::UTF8.GetString((Get-PetBytes $Pet.Page))).Replace('\/', '/').Replace('\"', '"')
    if ($page -match '"zipUrl"\s*:\s*"(https://[^"\s]+?\.zip(?:\?[^"\s]*)?)"') { return $Matches[1] }
    $pattern = 'https://[^"\s<>)]*/(?:pets|curated)/' + [regex]::Escape($Pet.Slug) + '(?:-[^/"\s<>)]*)?/[^"\s<>)]*\.zip(?:\?[^"\s<>)]*)?'
    if ($page -match $pattern) { return $Matches[0] }
    throw "Could not find a pet pack for $($Pet.Slug). Try /pet search first."
}

function Initialize-PetImageTools {
    if ('PiPetImageCleaner' -as [type]) { return }
    Add-Type -AssemblyName PresentationCore, WindowsBase
    Add-Type -ReferencedAssemblies @('PresentationCore', 'WindowsBase', 'System.Xaml') -TypeDefinition @'
using System;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
public static class PiPetImageCleaner {
    public static void Convert(string source, string output) {
        using (var input = File.OpenRead(source)) {
            var decoder = BitmapDecoder.Create(input, BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.OnLoad);
            var image = new FormatConvertedBitmap(decoder.Frames[0], PixelFormats.Bgra32, null, 0);
            if (image.PixelWidth != 1536 || image.PixelHeight != 1872)
                throw new InvalidDataException("Pet spritesheet must be 1536 x 1872 pixels.");
            int stride = image.PixelWidth * 4;
            var pixels = new byte[stride * image.PixelHeight];
            image.CopyPixels(pixels, stride, 0);
            for (int i = 0; i < pixels.Length; i += 4) {
                int b = pixels[i], g = pixels[i+1], r = pixels[i+2], a = pixels[i+3];
                bool magenta = r > 85 && b > 70 && g < 90 && r+b-2*g > 115 && Math.Abs(r-b) < 125;
                bool pink = r > 180 && b > 140 && g < 110;
                if (a <= 96 || ((magenta || pink) && a < 245)) {
                    pixels[i] = pixels[i+1] = pixels[i+2] = pixels[i+3] = 0;
                }
            }
            var clean = BitmapSource.Create(image.PixelWidth, image.PixelHeight, 96, 96, PixelFormats.Bgra32, null, pixels, stride);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(clean));
            using (var file = File.Create(output)) { encoder.Save(file); }
        }
    }
}
'@
}

function Convert-PetSpritesheet([string]$Source, [string]$Output) {
    Initialize-PetImageTools
    try {
        [PiPetImageCleaner]::Convert($Source, $Output)
        return
    } catch { $decodeError = $_ }

    # WPF uses installed Windows image codecs. FFmpeg is an optional fallback on
    # machines without a WebP codec; neither Bash nor Python is required.
    $ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($null -eq $ffmpeg) {
        throw "Cannot decode pet spritesheet. Install the Windows WebP image codec or FFmpeg, then retry. $decodeError"
    }
    $decoded = "$Output.decoded.png"
    try {
        & $ffmpeg.Source -v error -y -i $Source -frames:v 1 $decoded
        if ($LASTEXITCODE -ne 0) { throw 'FFmpeg could not decode the spritesheet.' }
        [PiPetImageCleaner]::Convert($decoded, $Output)
    } finally { Remove-Item -LiteralPath $decoded -Force -ErrorAction SilentlyContinue }
}

function Install-PetPack([string]$Slug, [byte[]]$ZipBytes, [string]$Root) {
    $Slug = Assert-PetSlug $Slug
    $Root = [IO.Path]::GetFullPath($Root)
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $temp = Join-Path $Root ('.install-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    try {
        $zipPath = Join-Path $temp 'pack.zip'
        [IO.File]::WriteAllBytes($zipPath, $ZipBytes)
        $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
        $stage = Join-Path $temp 'pet'
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        try {
            $entry = $zip.GetEntry('pet.json')
            if ($null -eq $entry -or $entry.Length -gt 1MB) { throw 'Pet pack is missing a valid pet.json.' }
            $reader = New-Object IO.StreamReader($entry.Open())
            try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            if ($null -eq $manifest -or $manifest -isnot [pscustomobject]) { throw 'Invalid pet.json.' }
            if ($manifest.id) { $Slug = Assert-PetSlug ([string]$manifest.id) }
            $spriteName = if ($manifest.spritesheetPath) { [string]$manifest.spritesheetPath } else { 'spritesheet.webp' }
            $sprite = $zip.GetEntry($spriteName)
            if ($null -eq $sprite) { $sprite = $zip.Entries | Where-Object { $_.FullName -match '\.(webp|png)$' } | Select-Object -First 1 }
            if ($null -eq $sprite -or $sprite.Length -gt 40MB) { throw 'Pet pack is missing a valid spritesheet.' }
            $extension = [IO.Path]::GetExtension($sprite.FullName).ToLowerInvariant()
            if ($extension -notin @('.webp', '.png')) { throw 'Pet spritesheet must be WebP or PNG.' }
            # Extract only the two contract files, never archive-controlled paths.
            $sourceName = "spritesheet.source$extension"
            $source = Join-Path $stage $sourceName
            [IO.Compression.ZipFileExtensions]::ExtractToFile($sprite, $source)
            Convert-PetSpritesheet $source (Join-Path $stage 'spritesheet.clean.png')
            $manifest | Add-Member -NotePropertyName sourceSpritesheetPath -NotePropertyValue $sourceName -Force
            $manifest | Add-Member -NotePropertyName spritesheetPath -NotePropertyValue 'spritesheet.clean.png' -Force
            [IO.File]::WriteAllText((Join-Path $stage 'pet.json'), ($manifest | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        } finally { $zip.Dispose() }

        $dest = Join-Path $Root $Slug
        $backup = Join-Path $temp 'previous'
        $hadPrevious = Test-Path -LiteralPath $dest
        if ($hadPrevious) { [IO.Directory]::Move($dest, $backup) }
        try { [IO.Directory]::Move($stage, $dest) }
        catch {
            if ($hadPrevious) { [IO.Directory]::Move($backup, $dest) }
            throw
        }
        [IO.File]::WriteAllText((Join-Path $Root 'active'), "$Slug`n", [Text.UTF8Encoding]::new($false))
        return $dest
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

# Dot-sourcing exposes helpers for offline tests without making network requests.
if ($MyInvocation.InvocationName -eq '.') { return }
if ([string]::IsNullOrWhiteSpace($Target)) {
    Write-Output 'Usage: .\pet-install.ps1 <petdex-slug-or-petdex/codex-pets-url> [-PetsPath <directory>]'
    exit 0
}
try {
    if ([string]::IsNullOrWhiteSpace($PetsPath)) {
        $dataRoot = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData\Local' }
        $PetsPath = Join-Path $dataRoot 'pi-pet\pets'
    }
    $pet = Get-PetTarget $Target.Trim()
    $zipUrl = Resolve-PetZipUrl $pet
    Write-Output "pi-pet: downloading $zipUrl"
    $dest = Install-PetPack $pet.Slug (Get-PetBytes $zipUrl 'application/zip') $PetsPath
    Write-Output "pi-pet: installed and activated $(Split-Path -Leaf $dest) in $dest"
} catch {
    [Console]::Error.WriteLine("pi-pet: $_")
    exit 1
}
