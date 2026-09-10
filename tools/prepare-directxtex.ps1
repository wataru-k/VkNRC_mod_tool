[CmdletBinding()]
param(
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Destination) {
    $Destination = Join-Path $repoRoot 'build-vs\tools\directxtex-may2026'
}
$expectedSha256 = 'DCFDEC10244E02CF5037FBA089C55FB7E1326B1C8181742D77D15FA5CB5EEF06'
$exe = Join-Path $Destination 'texconv.exe'
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    gh release download may2026 --repo microsoft/DirectXTex `
        --pattern texconv.exe --dir $Destination --clobber
    if ($LASTEXITCODE -ne 0) { throw 'Failed to download Microsoft DirectXTex texconv.exe' }
}

$actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
if ($actualSha256 -ne $expectedSha256) {
    throw "texconv.exe SHA-256 mismatch: expected $expectedSha256, got $actualSha256"
}

[pscustomobject]@{
    path = $exe
    release = 'may2026'
    sha256 = $actualSha256
}
