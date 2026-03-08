param(
    [ValidateSet('none', 'patch', 'minor', 'major')]
    [string]$Bump = 'patch',

    [string]$Version,

    [string]$OutputDir = 'dist'
)

$ErrorActionPreference = 'Stop'

function Parse-VersionParts {
    param([string]$Value)

    if ($Value -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
        throw "Version '$Value' must be in semver format: major.minor.patch"
    }

    return [int[]]@([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
}

function Get-CurrentVersion {
    param([string]$TocPath)

    $tocLines = Get-Content -Path $TocPath
    foreach ($line in $tocLines) {
        if ($line -match '^\s*##\s*Version\s*:\s*(\S+)\s*$') {
            return $Matches[1]
        }
    }

    return '1.0.0'
}

function Set-TocVersion {
    param(
        [string]$TocPath,
        [string]$NewVersion
    )

    $tocLines = Get-Content -Path $TocPath
    $updated = $false

    for ($i = 0; $i -lt $tocLines.Count; $i++) {
        if ($tocLines[$i] -match '^\s*##\s*Version\s*:') {
            $tocLines[$i] = "## Version: $NewVersion"
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        $insertAt = [Math]::Min(4, $tocLines.Count)
        $before = @()
        $after = @()

        if ($insertAt -gt 0) {
            $before = $tocLines[0..($insertAt - 1)]
        }
        if ($insertAt -lt $tocLines.Count) {
            $after = $tocLines[$insertAt..($tocLines.Count - 1)]
        }

        $tocLines = @($before + "## Version: $NewVersion" + $after)
    }

    Set-Content -Path $TocPath -Value $tocLines
}

function Bump-Version {
    param(
        [string]$Current,
        [string]$BumpType
    )

    $parts = Parse-VersionParts -Value $Current
    $major = $parts[0]
    $minor = $parts[1]
    $patch = $parts[2]

    switch ($BumpType) {
        'patch' { $patch++ }
        'minor' { $minor++; $patch = 0 }
        'major' { $major++; $minor = 0; $patch = 0 }
        'none'  { }
        default { throw "Unsupported bump type: $BumpType" }
    }

    return "$major.$minor.$patch"
}

$projectRoot = (Get-Location).Path
$addonName = Split-Path -Path $projectRoot -Leaf
$tocPath = Join-Path $projectRoot "$addonName.toc"
$luaPath = Join-Path $projectRoot "$addonName.lua"

if (-not (Test-Path -Path $tocPath -PathType Leaf)) {
    throw "Missing TOC file: $tocPath"
}
if (-not (Test-Path -Path $luaPath -PathType Leaf)) {
    throw "Missing Lua file: $luaPath"
}

$currentVersion = Get-CurrentVersion -TocPath $tocPath
if (-not $currentVersion) {
    $currentVersion = '1.0.0'
}

$targetVersion = $Version
if ([string]::IsNullOrWhiteSpace($targetVersion)) {
    $targetVersion = Bump-Version -Current $currentVersion -BumpType $Bump
} else {
    [void](Parse-VersionParts -Value $targetVersion)
}

if ($targetVersion -ne $currentVersion) {
    Set-TocVersion -TocPath $tocPath -NewVersion $targetVersion
}

$outputPath = Join-Path $projectRoot $OutputDir
if (-not (Test-Path -Path $outputPath)) {
    New-Item -Path $outputPath -ItemType Directory | Out-Null
}

$tempRoot = Join-Path $env:TEMP ("$addonName-pack-" + [guid]::NewGuid().ToString('N'))
$tempAddonFolder = Join-Path $tempRoot $addonName
New-Item -Path $tempAddonFolder -ItemType Directory -Force | Out-Null

Copy-Item -Path $tocPath -Destination (Join-Path $tempAddonFolder "$addonName.toc") -Force
Copy-Item -Path $luaPath -Destination (Join-Path $tempAddonFolder "$addonName.lua") -Force

$zipName = "$addonName-v$targetVersion.zip"
$zipPath = Join-Path $outputPath $zipName
if (Test-Path -Path $zipPath) {
    Remove-Item -Path $zipPath -Force
}

Compress-Archive -Path $tempAddonFolder -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item -Path $tempRoot -Recurse -Force

Write-Host "Created: $zipPath"
Write-Host "Version: $currentVersion -> $targetVersion"
