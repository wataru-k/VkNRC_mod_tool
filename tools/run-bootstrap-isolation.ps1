[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Scene,
    [ValidateRange(1, 1000000)]
    [uint64]$Frames = 60,
    [ValidateRange(0.000001, 1000000000.0)]
    [double]$Threshold = 100.0,
    [uint32]$Seed = 1,
    [switch]$RTXGIReferenceLighting,
    [switch]$FrameMetrics,
    [switch]$DryRun,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $repoRoot 'build-vs\Release\VkNRC.exe'
$scenePath = (Resolve-Path -LiteralPath $Scene).Path
if (-not $DryRun -and -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Release executable not found: $exe"
}
if (-not $OutputDirectory) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDirectory = Join-Path $repoRoot "build-vs\bootstrap-isolation\$stamp"
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

$conditions = @(
    [pscustomobject]@{ id = 'A'; bootstrap = $true;  training = $true;  contribution = $true  },
    [pscustomobject]@{ id = 'B'; bootstrap = $false; training = $true;  contribution = $true  },
    [pscustomobject]@{ id = 'C'; bootstrap = $false; training = $false; contribution = $true  },
    [pscustomobject]@{ id = 'D'; bootstrap = $true;  training = $true;  contribution = $false }
)

function Get-RunArguments {
    param($Condition)
    $arguments = @(
        ('"' + $scenePath + '"'),
        '--whiteout-threshold', ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Threshold)),
        '--seed', $Seed,
        '--frames', $Frames
    )
    if (-not $Condition.bootstrap) { $arguments += '--nrc-bootstrap-off' }
    if (-not $Condition.training) { $arguments += '--nrc-training-off' }
    if (-not $Condition.contribution) { $arguments += '--nrc-contribution-off' }
    if ($RTXGIReferenceLighting) { $arguments += '--rtxgi-reference-lighting' }
    if ($FrameMetrics) { $arguments += '--frame-metrics' }
    $arguments += $cameraArguments
    return $arguments
}

$results = foreach ($condition in $conditions) {
    $arguments = Get-RunArguments $condition
    if ($DryRun) {
        [pscustomobject]@{
            condition = $condition.id
            bootstrap = $condition.bootstrap
            training = $condition.training
            contribution = $condition.contribution
            command = "$exe $($arguments -join ' ')"
        }
        continue
    }

    $stdout = Join-Path $outputPath "$($condition.id).stdout.log"
    $stderr = Join-Path $outputPath "$($condition.id).stderr.log"
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Condition $($condition.id) failed with exit code $($process.ExitCode); see $stderr"
    }

    $text = Get-Content -Raw -LiteralPath $stdout
	if ((Get-Item -LiteralPath $stderr).Length -ne 0) {
		throw "Condition $($condition.id) wrote stderr; see $stderr"
	}
    $counterPattern = 'Whiteout counters: evaluated=(\d+), nonfinite=(\d+), over-threshold=(\d+), max-luminance=([^\r\n]+)'
    $counterMatch = [regex]::Match($text, $counterPattern)
    if (-not $counterMatch.Success) { throw "No NRC diagnostic counter line found in $stdout" }
    $displayMatch = [regex]::Match($text, 'Display WhiteOut: valid=(true|false), detected=(true|false), first-frame=(\d+), max-consecutive=(\d+), measured-frames=(\d+)')
	if ($FrameMetrics) {
		if (-not $displayMatch.Success) { throw "Condition $($condition.id) has no Display WhiteOut summary" }
		if ($displayMatch.Groups[1].Value -ne 'true') { throw "Condition $($condition.id) produced invalid display metrics" }
		if ([uint64]$displayMatch.Groups[5].Value -ne $Frames) {
			throw "Condition $($condition.id) measured $($displayMatch.Groups[5].Value) frames; expected $Frames"
		}
		$frameMatches = [regex]::Matches($text, 'Frame WhiteOut: frame=(\d+), valid=(true|false), pixels=(\d+)')
		if ($frameMatches.Count -ne $Frames) {
			throw "Condition $($condition.id) has $($frameMatches.Count) frame metrics; expected $Frames"
		}
		foreach ($frameMatch in $frameMatches) {
			if ($frameMatch.Groups[2].Value -ne 'true' -or [uint64]$frameMatch.Groups[3].Value -ne 921600) {
				throw "Condition $($condition.id) frame $($frameMatch.Groups[1].Value) failed validity/pixel-count"
			}
		}
	}
    [pscustomobject]@{
        condition = $condition.id
        bootstrap = $condition.bootstrap
        training = $condition.training
        contribution = $condition.contribution
        seed = $Seed
        frames = $Frames
        evaluated = [uint64]$counterMatch.Groups[1].Value
        nonfinite = [uint64]$counterMatch.Groups[2].Value
        overThreshold = [uint64]$counterMatch.Groups[3].Value
        maxLuminance = [double]::Parse($counterMatch.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture)
        displayMetricsValid = if ($displayMatch.Success) { $displayMatch.Groups[1].Value -eq 'true' } else { $null }
        displayWhiteout = if ($displayMatch.Success) { $displayMatch.Groups[2].Value -eq 'true' } else { $null }
        firstDisplayWhiteoutFrame = if ($displayMatch.Success) { [uint64]$displayMatch.Groups[3].Value } else { $null }
        maxConsecutiveFrames = if ($displayMatch.Success) { [uint32]$displayMatch.Groups[4].Value } else { $null }
        measuredFrames = if ($displayMatch.Success) { [uint32]$displayMatch.Groups[5].Value } else { $null }
        exitCode = $process.ExitCode
        stdout = $stdout
        stderr = $stderr
    }
}

$summary = [pscustomobject]@{
    classification = if ($FrameMetrics -and -not $DryRun) { 'TRAINING_DEPENDENT_NRC_CONTRIBUTION_DISPLAY_WHITEOUT' } else { 'RAPID_TRAINING_DEPENDENT_NRC_DIVERGENCE_CANDIDATE' }
    scope = if ($DryRun) { 'dry-run' } elseif ($FrameMetrics) { 'formal fixed-tone-map pre-overlay DISPLAY_WHITEOUT measurement' } else { 'NRC divergence preflight; not a DISPLAY_WHITEOUT verdict' }
    scene = $scenePath
    executable = $exe
    sceneManifest = if (Test-Path -LiteralPath $manifestPath) { $manifestPath } else { $null }
    rtxgiReferenceLighting = [bool]$RTXGIReferenceLighting
    generatedAt = (Get-Date).ToString('o')
    results = @($results)
}
$summaryPath = Join-Path $outputPath 'summary.json'
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$summary | ConvertTo-Json -Depth 6
