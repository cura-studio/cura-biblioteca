# Isolated function tests: never dot-source the installer (its main flow is live).
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../scripts/install.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
# Only these side effects are mocked; real file operations/hash/receipts are exercised.
function Write-CuraLog { param($LogPath, $Message, [switch]$IsError) $script:Messages += $Message }
function Get-Process { param($Name, $ErrorAction) if ($script:SketchUpOpen) { return [PSCustomObject]@{ Name = 'SketchUp' } } }
function Assert($Condition, $Label) {
    if (-not $Condition) { throw "FAIL: $Label`n$($script:Messages -join [Environment]::NewLine)" }
    $script:Assertions++
}
$script:Assertions = 0
$script:Messages = @()
$script:SketchUpOpen = $false
$tempBase = [IO.Path]::GetTempPath()
if (Test-Path '/private/tmp' -PathType Container) { $tempBase = '/private/tmp' }
$fixture = Join-Path $tempBase ('cura-template-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $assets = Join-Path $fixture 'assets'
    $profileRoot = Join-Path $fixture 'SketchUp'
    $stage = Join-Path $fixture 'stage'
    New-Item -ItemType Directory -Path $assets, $stage | Out-Null
    [IO.File]::WriteAllText((Join-Path $assets 'CURA.skp'), 'fixture template bytes')
    $hash = (Get-FileHash (Join-Path $assets 'CURA.skp') -Algorithm SHA256).Hash
    $manifest = [PSCustomObject]@{ biblioteca_version = 'test'; plugins = @(); sketchup_template = [PSCustomObject]@{ file = 'CURA.skp'; sha256 = $hash; min_sketchup = 2018 } }
    $versions = @(2017, 2018, 2024, 2026, 2030 | ForEach-Object {
        [PSCustomObject]@{ Year = $_; VersionDir = (Join-Path $profileRoot "SketchUp $_"); PluginsPath = (Join-Path $profileRoot "SketchUp $_/SketchUp/Plugins") }
    })
    $argsInstall = @{ Manifest = $manifest; OldSnapshot = $null; DetectedVersions = $versions; BaseUrl = $assets; TempDir = $stage; LogPath = (Join-Path $fixture 'test.log'); Quiet = $true }
    $result = Install-CuraTemplates @argsInstall
    Assert $result.success 'installation succeeds'
    Assert (@($result.receipts).Count -eq 4) '2018/2024/2026/2030 installed'
    Assert (-not (Test-Path (Get-CuraTemplatePath $versions[0]))) '2017 skipped'
    foreach ($ver in $versions[1..4]) {
        Assert ((Get-FileHash (Get-CuraTemplatePath $ver) -Algorithm SHA256).Hash -eq $hash) "identical bytes $($ver.Year)"
    }
    $snap = [PSCustomObject]@{ biblioteca_version = 'test'; sketchup_templates = $result.receipts; sketchup_versions = @(); fonts = @() }
    $argsInstall.OldSnapshot = $snap
    Assert (Test-CuraUpToDate -Manifest $manifest -OldSnapshot $snap -DetectedVersions @() -TemplateVersions $versions) 'template min independent plugin min'
    $path = Get-CuraTemplatePath $versions[1]
    $mtime = (Get-Item $path).LastWriteTimeUtc
    $again = Install-CuraTemplates @argsInstall
    Assert $again.success 'repeat succeeds'
    Assert ((Get-Item $path).LastWriteTimeUtc -eq $mtime) 'repeat does not rewrite'
    Assert (@(Get-ChildItem $profileRoot -Recurse -Filter '*.cura-backup-*').Count -eq 0) 'repeat creates no backups'
    Remove-Item -LiteralPath $path
    Assert (-not (Test-CuraTemplatesCurrent $manifest $snap $versions)) 'missing template invalidates no-op'
    Assert ((Install-CuraTemplates @argsInstall).success) 'missing template repaired'
    $future = [PSCustomObject]@{ Year = 2031; VersionDir = (Join-Path $profileRoot 'SketchUp 2031') }
    Assert (-not (Test-CuraTemplatesCurrent $manifest $snap @($versions + $future))) 'new SketchUp invalidates no-op'
    [IO.File]::WriteAllText($path, 'student custom template')
    Assert (Test-CuraTemplatesCurrent $manifest $snap $versions) 'personal edits do not force daily reinstall'
    $repairOther = Install-CuraTemplates @argsInstall
    Assert ([IO.File]::ReadAllText($path) -eq 'student custom template') 'repair of other components preserves personal edits'
    # A first install over an unrelated same-name file must back it up.
    $argsInstall.OldSnapshot = $null
    $custom = Install-CuraTemplates @argsInstall
    Assert $custom.success 'custom template install succeeds'
    $backups = @(Get-ChildItem (Split-Path $path) -Filter '*.cura-backup-*')
    Assert ($backups.Count -eq 1) 'custom template backed up'
    Assert ([IO.File]::ReadAllText($backups[0].FullName) -eq 'student custom template') 'backup retains original'
    [IO.File]::WriteAllText($path, 'second custom template')
    $custom = Install-CuraTemplates @argsInstall
    Assert (@(Get-ChildItem (Split-Path $path) -Filter '*.cura-backup-*').Count -eq 2) 'unique backups never overwritten'
    $manifest.sketchup_template.sha256 = ('0' * 64)
    $argsInstall.OldSnapshot = $snap
    $failed = Install-CuraTemplates @argsInstall
    Assert (-not $failed.success) 'wrong download hash rejected'
    Assert (@($failed.receipts).Count -eq 4) 'failed install retains previous receipts'
    Assert ((Get-FileHash $path -Algorithm SHA256).Hash -eq $hash) 'bad payload cannot overwrite template'
    $manifest.sketchup_template.sha256 = $hash
    $script:SketchUpOpen = $true
    $deferred = Install-CuraTemplates @argsInstall
    Assert (-not $deferred.success) 'SketchUp opened during download defers without exiting installer'
    Assert (@($deferred.receipts).Count -eq 4) 'deferral retains receipts for snapshot'
    $script:SketchUpOpen = $false
    foreach ($badName in @('../CURA.skp', 'CURA.skp:stream', 'CURA.skp ')) {
        $manifest.sketchup_template.file = $badName
        Assert (-not (Get-CuraTemplateSpec $manifest).valid) "reject unsafe name $badName"
    }
    $manifest.sketchup_template.file = 'CURA.skp'
    $manifest.sketchup_template.min_sketchup = 'anything'
    Assert (-not (Get-CuraTemplateSpec $manifest).valid) 'reject invalid minimum'
    $manifest.sketchup_template.min_sketchup = 2018
    [IO.File]::WriteAllText($path, 'keep edited by student')
    $outside = Join-Path $fixture 'outside.skp'
    [IO.File]::WriteAllText($outside, 'fixture template bytes')
    $tampered = [PSCustomObject]@{ year = 2024; file = $outside; sha256 = $hash; owned = $true }
    Assert (Remove-CuraTemplates -Receipts @($snap.sketchup_templates + $tampered) -SketchUpRoot $profileRoot -LogPath $argsInstall.LogPath) 'safe uninstall succeeds'
    Assert (Test-Path $path) 'uninstall preserves edited template'
    Assert (-not (Test-Path (Get-CuraTemplatePath $versions[2]))) 'uninstall removes own unchanged template'
    Assert (Test-Path $outside) 'uninstall ignores out-of-tree receipt'
    Assert (Test-Path $backups[0].FullName) 'uninstall preserves backups'
    # An identical pre-existing file was not created by us and is not ours to delete.
    $identicalPath = Get-CuraTemplatePath $versions[2]
    Copy-Item -LiteralPath (Join-Path $assets 'CURA.skp') -Destination $identicalPath
    $argsInstall.OldSnapshot = $null
    $adopted = Install-CuraTemplates @argsInstall
    Assert (@($adopted.receipts | Where-Object { $_.file -eq $identicalPath -and $_.owned -eq $false }).Count -eq 1) 'identical pre-existing file remains unowned'
    Assert (Remove-CuraTemplates -Receipts $adopted.receipts -SketchUpRoot $profileRoot -LogPath $argsInstall.LogPath) 'unowned uninstall succeeds'
    Assert (Test-Path $identicalPath) 'uninstall preserves unowned identical template'
    $linkTarget = Join-Path $fixture 'link-target'
    $linkedVersion = Join-Path $profileRoot 'SketchUp 2035'
    New-Item -ItemType Directory -Path $linkTarget | Out-Null
    $linkType = 'SymbolicLink'
    if ($env:OS -eq 'Windows_NT') { $linkType = 'Junction' }
    New-Item -ItemType $linkType -Path $linkedVersion -Value $linkTarget | Out-Null
    $linked = [PSCustomObject]@{ Year = 2035; VersionDir = $linkedVersion }
    $argsInstall.DetectedVersions = @($future, $linked)
    $argsInstall.OldSnapshot = $snap
    $partial = Install-CuraTemplates @argsInstall
    Assert (-not $partial.success) 'junction or symlink ancestor rejected'
    Assert (Test-Path (Get-CuraTemplatePath $future)) 'new future version installed despite separate target failure'
    Assert (@($partial.receipts).Count -eq 5) 'partial failure retains old and successful new receipts'
    Assert (-not (Test-Path (Join-Path $linkTarget 'SketchUp/Templates/CURA.skp'))) 'linked destination untouched'
    function Remove-Item { param($LiteralPath, [switch]$Force, $ErrorAction) throw 'simulated file lock' }
    try {
        Assert (-not (Remove-CuraTemplates -Receipts $partial.receipts -SketchUpRoot $profileRoot -LogPath $argsInstall.LogPath)) 'locked template reports failure so caller retains snapshot'
    } finally { Microsoft.PowerShell.Management\Remove-Item Function:Remove-Item -ErrorAction SilentlyContinue }
    # Remove link alone, never recurse through the link target during fixture cleanup.
    (Get-Item -LiteralPath $linkedVersion).Delete()
    $legacy = [PSCustomObject]@{ biblioteca_version = 'test' }
    Assert (Test-CuraTemplatesCurrent $legacy $null $versions) 'manifest without template unchanged'
    Assert ((Install-CuraTemplates -Manifest $legacy -OldSnapshot $snap).receipts.Count -eq 4) 'manifest omission preserves receipts'
    Write-Host "PASS: $script:Assertions Windows template assertions (isolated filesystem; no native SketchUp)."
} finally {
    # Deletes only this script's GUID-named temporary fixture.
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
