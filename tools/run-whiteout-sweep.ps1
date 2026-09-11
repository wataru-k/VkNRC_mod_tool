[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Scenes,
    [uint32[]]$Seeds = @(2, 3, 4),
    [ValidateRange(1, 1000000)]
    [uint64]$Frames = 3600,
    [ValidateRange(0.000001, 1000000000.0)]
    [double]$Threshold = 100.0,
    [switch]$RTXGIReferenceLighting,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $repoRoot 'build-vs\Release\VkNRC.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Release executable not found: $exe"
}

$scenePaths = @($Scenes | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
if (-not $OutputDirectory) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDirectory = Join-Path $repoRoot "build-vs\whiteout-sweeps\$stamp"
}
$outputPath = (New-Item -ItemType Directory -Force -Path $OutputDirectory).FullName
$results = @()
$stopReason = $null
$counterPattern = 'Whiteout counters: evaluated=(\d+), nonfinite=(\d+), over-threshold=(\d+), max-luminance=([^\r\n]+)'
$renderErrorPattern = '(?im)(Vulkan[^\r\n]*(?:error|fail)|texture[^\r\n]*(?:error|fail)|(?:error|fail)[^\r\n]*(?:Vulkan|texture))'

function Write-Summary {
    $summary = [pscustomobject]@{
        executable = $exe
        generatedAt = (Get-Date).ToString('o')
        requestedScenes = $scenePaths
        requestedSeeds = $Seeds
        frames = $Frames
        threshold = $Threshold
        guard = $false
        rtxgiReferenceLighting = [bool]$RTXGIReferenceLighting
        completed = ($null -eq $stopReason -and $results.Count -eq ($scenePaths.Count * $Seeds.Count))
        stopReason = $stopReason
        results = $results
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputPath 'summary.json') -Encoding UTF8
    return $summary
}

:sceneLoop foreach ($scenePath in $scenePaths) {
    $sceneName = Split-Path -Leaf (Split-Path -Parent $scenePath)
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

    foreach ($seed in $Seeds) {
        $runPath = (New-Item -ItemType Directory -Force -Path (Join-Path $outputPath "$sceneName-seed$seed")).FullName
        $stdout = Join-Path $runPath 'stdout.log'
        $stderr = Join-Path $runPath 'stderr.log'
        $arguments = @(
            ('"' + $scenePath + '"'),
            '--whiteout-diagnostic',
            '--whiteout-threshold', ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Threshold)),
            '--seed', $seed,
            '--frames', $Frames
        ) + $cameraArguments
        if ($RTXGIReferenceLighting) { $arguments += '--rtxgi-reference-lighting' }
        $startedAt = Get-Date
        $process = Start-Process -FilePath $exe -ArgumentList $arguments `
            -WorkingDirectory $repoRoot -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr -WindowStyle Hidden -Wait -PassThru
        $finishedAt = Get-Date
        $stdoutText = if (Test-Path -LiteralPath $stdout) { Get-Content -Raw -LiteralPath $stdout } else { '' }
        $stderrText = if (Test-Path -LiteralPath $stderr) { Get-Content -Raw -LiteralPath $stderr } else { '' }
        $counterMatch = [regex]::Match($stdoutText, $counterPattern)
        $renderErrorMatch = [regex]::Match("$stdoutText`n$stderrText", $renderErrorPattern)

        $runStopReason = $null
        if ($process.ExitCode -ne 0) {
            $runStopReason = "exit code $($process.ExitCode)"
        } elseif ($renderErrorMatch.Success) {
            $runStopReason = "render error: $($renderErrorMatch.Value.Trim())"
        } elseif (-not $counterMatch.Success) {
            $runStopReason = 'whiteout counter line missing'
        }

        $evaluated = if ($counterMatch.Success) { [uint64]$counterMatch.Groups[1].Value } else { $null }
        $nonfinite = if ($counterMatch.Success) { [uint64]$counterMatch.Groups[2].Value } else { $null }
        $overThreshold = if ($counterMatch.Success) { [uint64]$counterMatch.Groups[3].Value } else { $null }
        $maxLuminance = if ($counterMatch.Success) {
            [double]::Parse($counterMatch.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture)
        } else { $null }
        if (-not $runStopReason -and $nonfinite -gt 0) {
            $runStopReason = "nonfinite=$nonfinite"
        } elseif (-not $runStopReason -and $overThreshold -gt 0) {
            $runStopReason = "over-threshold=$overThreshold"
        }

        $results += [pscustomobject]@{
            scene = $scenePath
            sceneManifest = if (Test-Path -LiteralPath $manifestPath) { $manifestPath } else { $null }
            seed = $seed
            frames = $Frames
            threshold = $Threshold
            guard = $false
            startedAt = $startedAt.ToString('o')
            finishedAt = $finishedAt.ToString('o')
            durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
            evaluated = $evaluated
            nonfinite = $nonfinite
            overThreshold = $overThreshold
            maxLuminance = $maxLuminance
            exitCode = $process.ExitCode
            stopReason = $runStopReason
            stdout = $stdout
            stderr = $stderr
        }
        if ($runStopReason) {
            $stopReason = "$sceneName seed ${seed}: $runStopReason"
        }
        $null = Write-Summary
        if ($stopReason) { break sceneLoop }
    }
}

$summary = Write-Summary
$summary | ConvertTo-Json -Depth 6
if ($stopReason) { exit 2 }
