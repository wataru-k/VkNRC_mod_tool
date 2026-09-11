[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Scene,
    [ValidateRange(1, 1000000)]
    [uint64]$Frames = 3600,
    [ValidateRange(0.000001, 1000000000.0)]
    [double]$Threshold = 100.0,
    [uint32]$Seed = 1,
    [switch]$RTXGIReferenceLighting,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $repoRoot 'build-vs\Release\VkNRC.exe'
$scenePath = (Resolve-Path -LiteralPath $Scene).Path
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Release executable not found: $exe"
}
if (-not $OutputDirectory) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDirectory = Join-Path $repoRoot "build-vs\whiteout-results\$stamp"
}
$outputPath = New-Item -ItemType Directory -Force -Path $OutputDirectory
$manifestPath = [IO.Path]::ChangeExtension($scenePath, '.vknrc.json')
$cameraArguments = @()
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.camera) {
        $position = $manifest.camera.normalizedPosition
        $cameraArguments = @(
            '--camera-position', $position[0], $position[1], $position[2],
            '--camera-fov', $manifest.camera.verticalFov
        )
    }
}

function Invoke-WhiteoutRun {
    param([bool]$Guard)

    $name = if ($Guard) { 'guard-on' } else { 'guard-off' }
    $stdout = Join-Path $outputPath "$name.stdout.log"
    $stderr = Join-Path $outputPath "$name.stderr.log"
    $arguments = @(
        ('"' + $scenePath + '"'),
        '--whiteout-diagnostic',
        '--whiteout-threshold', ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Threshold)),
        '--seed', $Seed,
        '--frames', $Frames
    )
    if ($Guard) { $arguments += '--whiteout-guard' }
    if ($RTXGIReferenceLighting) { $arguments += '--rtxgi-reference-lighting' }
    $arguments += $cameraArguments

    $process = Start-Process -FilePath $exe -ArgumentList $arguments `
        -WorkingDirectory $repoRoot -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "$name failed with exit code $($process.ExitCode); see $stderr"
    }

    $text = Get-Content -Raw -LiteralPath $stdout
    $counterPattern = 'Whiteout counters: evaluated=(\d+), nonfinite=(\d+), over-threshold=(\d+), max-luminance=([^\r\n]+)'
    $counterMatch = [regex]::Match($text, $counterPattern)
    if (-not $counterMatch.Success) { throw "No whiteout counter line found in $stdout" }
    [pscustomobject]@{
        guard = $Guard
        seed = $Seed
        frames = $Frames
        threshold = $Threshold
        evaluated = [uint64]$counterMatch.Groups[1].Value
        nonfinite = [uint64]$counterMatch.Groups[2].Value
        overThreshold = [uint64]$counterMatch.Groups[3].Value
        maxLuminance = [double]::Parse($counterMatch.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture)
        exitCode = $process.ExitCode
        stdout = $stdout
        stderr = $stderr
    }
}

$results = @(
    Invoke-WhiteoutRun -Guard $false
    Invoke-WhiteoutRun -Guard $true
)
$summary = [pscustomobject]@{
    scene = $scenePath
    executable = $exe
    sceneManifest = if (Test-Path -LiteralPath $manifestPath) { $manifestPath } else { $null }
    rtxgiReferenceLighting = [bool]$RTXGIReferenceLighting
    generatedAt = (Get-Date).ToString('o')
    results = $results
}
$summaryPath = Join-Path $outputPath 'summary.json'
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$summary | ConvertTo-Json -Depth 5

