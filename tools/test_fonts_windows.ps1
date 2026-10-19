# Isolated function test: never dot-source the installer (its main flow is live).
# Reproduces the "arquivo em uso" reinstall failure: on Windows a loaded font is
# open by the session; here a FileShare.Read handle gives the same IOException
# (.NET emulates share locks on macOS/Linux too).
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../scripts/install.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-CuraFontFile' }, $true)
. ([scriptblock]::Create($fn.Extent.Text))
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL: $Label" }; $script:Assertions++ }
function Hash($Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
$script:Assertions = 0
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('cura-fonts-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $src = Join-Path $fixture 'Inter[opsz,wght].ttf'
    $other = Join-Path $fixture 'other.ttf'
    $dest = Join-Path $fixture 'dest.ttf'
    [IO.File]::WriteAllText($src, 'font bytes v1')
    [IO.File]::WriteAllText($other, 'font bytes v2')

    Assert (Copy-CuraFontFile -Source $src -Destination $dest) 'missing destination is copied'
    Assert ((Hash $dest) -eq (Hash $src)) 'copied bytes match'

    $lock = [IO.File]::Open($dest, 'Open', 'Read', 'Read')
    try {
        $oldFailed = $false
        try { Copy-Item -LiteralPath $src -Destination $dest -Force } catch { $oldFailed = $true }
        Assert $oldFailed 'old Copy-Item over a locked identical font fails (bug reproduced)'
        Assert (-not (Copy-CuraFontFile -Source $src -Destination $dest)) 'locked identical font is skipped without error'
        $newFailed = $false
        try { Copy-CuraFontFile -Source $other -Destination $dest | Out-Null } catch { $newFailed = $true }
        Assert $newFailed 'locked different font still raises (retry path kept)'
    } finally { $lock.Dispose() }

    Assert (Copy-CuraFontFile -Source $other -Destination $dest) 'unlocked different font is replaced'
    Assert ((Hash $dest) -eq (Hash $other)) 'replaced bytes match'
    Write-Host "OK: $script:Assertions assertions"
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
