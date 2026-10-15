# Real ownership/transaction/uninstall functions on private profiles. PowerShell
# runtime execution does not claim native Windows/SketchUp validation.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../scripts/install.ps1'
$engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$base = [IO.Path]::GetTempPath(); if (Test-Path '/private/tmp' -PathType Container) { $base = '/private/tmp' }
$root = Join-Path $base ('cura-distribution-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$LogPath = Join-Path $root 'test.log'
$script:Assertions = 0; $script:Messages = @(); $script:PluginTransactions = @(); $script:ChannelReceiptsRetired = $false
function Write-CuraLog { param($LogPath,$Message,[switch]$IsError) $script:Messages += $Message }
function Get-Process { param($Name,$ErrorAction) }
function Assert($Condition,$Label) { if (-not $Condition) { throw "FAIL: $Label`n$($script:Messages -join "`n")" }; $script:Assertions++ }
function Reject([scriptblock]$Action,$Label) { $rejected=$false; try { & $Action } catch { $rejected=$true }; Assert $rejected $Label }
function Write-Marker($Plugins,$Channel) {
    [IO.File]::WriteAllText((Join-Path $Plugins 'cura_ferramentas/distribution.json'),('{"schema":1,"product":"cura-ferramentas","channel":"'+$Channel+'"}'))
}
function New-Profile($Mode,$Years) {
    $case = Join-Path $root $Mode
    $appdata = Join-Path $case 'Profile With Spaces'
    $localappdata = Join-Path $case 'Local AppData'
    $versions = @(); $receipts = @()
    foreach ($year in $Years) {
        $plugins = Join-Path $appdata "SketchUp/SketchUp $year/SketchUp/Plugins"
        New-Item -ItemType Directory -Path (Join-Path $plugins 'cura_ferramentas'),(Join-Path $plugins 'TT_Lib2'),(Join-Path $plugins 'cura_other_product') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $plugins 'cura_ferramentas/core.rbe'),"old code $year")
        [IO.File]::WriteAllText((Join-Path $plugins 'cura_ferramentas.rb'),"old loader $year")
        [IO.File]::WriteAllText((Join-Path $plugins 'TT_Lib2/paid.rb'),'third party')
        [IO.File]::WriteAllText((Join-Path $plugins 'cura_other_product/state.bin'),'other product')
        $channel = 'biblioteca'
        if ($Mode -like 'warehouse*' -or $Mode -eq 'uninstall-warehouse' -or ($Mode -in @('mixed','uninstall-mixed') -and $year -eq 2025)) { $channel = 'warehouse' }
        if ($Mode -notin @('legacy','unowned')) { Write-Marker $plugins $channel }
        if ($Mode -in @('invalid','uninstall-invalid')) { [IO.File]::WriteAllText((Join-Path $plugins 'cura_ferramentas/distribution.json'),'{corrupt') }
        $versions += [PSCustomObject]@{Year=$year;PluginsPath=$plugins}
        if ($Mode -notin @('unowned','warehouse-unowned','fresh')) { $receipts += [PSCustomObject]@{year=$year;plugins_path=$plugins;plugins=@([PSCustomObject]@{id='cura-ferramentas';name='cura | ferramentas';version='1.0.1';roots=@('cura_ferramentas','cura_ferramentas.rb')})} }
    }
    if ($Mode -eq 'fresh') { Remove-Item -LiteralPath (Join-Path $plugins 'cura_ferramentas'),(Join-Path $plugins 'cura_ferramentas.rb') -Recurse -Force }
    $identity = Join-Path $localappdata 'CURA/Ferramentas/access-state.json'
    New-Item -ItemType Directory -Path (Split-Path $identity -Parent),(Join-Path $localappdata 'CURA-Biblioteca') -Force | Out-Null
    [IO.File]::WriteAllText($identity,'{"uuid":"outside-Plugins"}')
    [IO.File]::WriteAllText((Join-Path $localappdata 'qa-scheduled-task'),'fixture scheduler')
    $snapshot = [PSCustomObject]@{biblioteca_version='old';installed_at='old';sketchup_versions=$receipts;fonts=@();photoshop=@();sketchup_templates=@()}
    $snapshotPath = Join-Path $localappdata 'CURA-Biblioteca/installed.json'
    $snapshot | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $snapshotPath -Encoding UTF8
    return [PSCustomObject]@{Case=$case;AppData=$appdata;LocalAppData=$localappdata;Versions=$versions;Snapshot=$snapshot;SnapshotPath=$snapshotPath;Identity=$identity}
}
try {
    $stage = Join-Path $root 'stage'
    New-Item -ItemType Directory -Path (Join-Path $stage 'cura_ferramentas') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $stage 'cura_ferramentas/core.rbe'),'new protected code')
    [IO.File]::WriteAllText((Join-Path $stage 'cura_ferramentas.rb'),'new loader')
    Write-Marker $stage 'biblioteca'
    $plugin = [PSCustomObject]@{id='cura-ferramentas';name='cura | ferramentas';version='1.1.0';roots=@('cura_ferramentas','cura_ferramentas.rb')}
    $manifest = [PSCustomObject]@{biblioteca_version='new';plugins=@($plugin);fonts=$null;photoshop=$null;sketchup_template=$null}
    foreach ($mode in @('warehouse','warehouse-stale','warehouse-unowned','fresh','biblioteca','legacy','unowned','invalid','mixed')) {
        $fixture = New-Profile $mode $(if ($mode -eq 'mixed') { @(2025,2026) } else { @(2026) })
        Remove-CuraWarehouseReceipts -OldSnapshot $fixture.Snapshot -LogPath $LogPath
        $actualReceipts = @(); $script:PluginTransactions = @()
        foreach ($ver in $fixture.Versions) {
            $before = Get-CuraPluginTreeSignature $ver.PluginsPath
            $channel = Get-CuraFerramentasChannel $ver.PluginsPath
            $legacy = Test-CuraLegacyFerramentasReceipt $fixture.Snapshot $ver.PluginsPath
            $ok = Install-CuraPluginTransaction -Stage $stage -PluginsPath $ver.PluginsPath -Roots $plugin.roots -OldRoots @() -LogPath $LogPath -LegacyRecognized $legacy
            if ($channel -eq 'warehouse' -or $mode -in @('unowned','invalid')) {
                Assert (-not $ok) "$mode protected install refused"
                Assert ((Get-CuraPluginTreeSignature $ver.PluginsPath) -eq $before) "$mode every plugin byte preserved"
            } else {
                Assert $ok "$mode Library/legacy install succeeds"
                Assert ([IO.File]::ReadAllText((Join-Path $ver.PluginsPath 'cura_ferramentas/core.rbe')) -eq 'new protected code') "$mode updated code"
                $actualReceipts += [PSCustomObject]@{year=$ver.Year;plugins_path=$ver.PluginsPath;plugins=@($plugin)}
            }
            Assert ([IO.File]::ReadAllText((Join-Path $ver.PluginsPath 'TT_Lib2/paid.rb')) -eq 'third party') "$mode third party untouched"
            Assert ([IO.File]::ReadAllText((Join-Path $ver.PluginsPath 'cura_other_product/state.bin')) -eq 'other product') "$mode other product untouched"
        }
        Assert ([IO.File]::ReadAllText($fixture.Identity) -eq '{"uuid":"outside-Plugins"}') "$mode identity outside Plugins preserved"
        if ($mode -like 'warehouse*') {
            Assert (@($fixture.Snapshot.sketchup_versions | ForEach-Object { $_.plugins }).Count -eq 0) "$mode stale Library receipt retired"
            $fixture.Snapshot.biblioteca_version = 'new'
            Save-CuraSnapshot -Snapshot $fixture.Snapshot -SnapshotPath $fixture.SnapshotPath
            $freshSnapshot = Get-CuraOldSnapshot $fixture.SnapshotPath
            Remove-CuraWarehouseReceipts -OldSnapshot $freshSnapshot -LogPath $LogPath
            Assert (Test-CuraUpToDate -Manifest $manifest -OldSnapshot $freshSnapshot -DetectedVersions $fixture.Versions) "$mode no-op after receipt migration"
        } elseif ($mode -notin @('unowned','invalid')) {
            $current = [PSCustomObject]@{biblioteca_version='new';sketchup_versions=$actualReceipts;fonts=@();photoshop=@();sketchup_templates=@()}
            Save-CuraSnapshot -Snapshot $current -SnapshotPath $fixture.SnapshotPath
            Complete-CuraPluginTransactions
            Remove-CuraWarehouseReceipts -OldSnapshot $current -LogPath $LogPath
            Assert (Test-CuraUpToDate -Manifest $manifest -OldSnapshot $current -DetectedVersions $fixture.Versions) "$mode current state no-op"
        }
    }
    # Parser is strict and independent of ConvertFrom-Json's duplicate behavior.
    $parsePath = Join-Path $root 'parser';New-Item -ItemType Directory -Path (Join-Path $parsePath 'cura_ferramentas') -Force | Out-Null
    $marker = Join-Path $parsePath 'cura_ferramentas/distribution.json'
    foreach ($text in @(('{' + [char]12 + '"schema":1,"product":"cura-ferramentas","channel":"biblioteca"}'),'null','{corrupt','{"schema":true,"product":"cura-ferramentas","channel":"biblioteca"}','{"schema":1.0,"product":"cura-ferramentas","channel":"biblioteca"}','{"schema":1,"product":"cura-ferramentas","channel":"warehouse","channel":"biblioteca"}','{"schema":2,"product":"cura-ferramentas","channel":"biblioteca"}','{"schema":1,"product":"other","channel":"biblioteca"}','{"schema":1,"product":"cura-ferramentas","channel":"biblio teca"}','{"schema":1,"product":"cura-ferramentas","channel":"other"}','{"schema":1,"product":"cura-ferramentas","channel":"biblioteca","extra":1}','{"schema":1,"schema":1,"channel":"biblioteca"}')) {
        [IO.File]::WriteAllText($marker,$text)
        Assert ((Get-CuraFerramentasChannel $parsePath) -eq 'invalid') "invalid metadata refused: $text"
    }
    [IO.File]::WriteAllText($marker,'{"channel":"warehouse", "product":"cura-ferramentas", "schema":1}')
    Assert ((Get-CuraFerramentasChannel $parsePath) -eq 'warehouse') 'reordered valid marker accepted'
    # Refuse an incoming Warehouse payload even over a valid Library root.
    $incoming = New-Profile 'incoming' @(2026)
    Write-Marker $stage 'warehouse'
    Reject { Install-CuraPluginTransaction -Stage $stage -PluginsPath $incoming.Versions[0].PluginsPath -Roots $plugin.roots -OldRoots @() -LogPath $LogPath } 'incoming Warehouse payload refused'
    Assert ([IO.File]::ReadAllText((Join-Path $incoming.Versions[0].PluginsPath 'cura_ferramentas/core.rbe')) -eq 'old code 2026') 'incoming wrong channel leaves installed Library unchanged'
    Write-Marker $stage 'biblioteca'
    # Recheck ownership after staging, before touching loaded roots.
    $race = New-Profile 'race' @(2026)
    $script:RacePlugins = $race.Versions[0].PluginsPath
    $script:RaceStage = Join-Path $stage 'cura_ferramentas'
    function Copy-Item {
        param($LiteralPath,$Destination,[switch]$Recurse,[switch]$Force,$ErrorAction)
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse -Force:$Force -ErrorAction Stop
        if ($LiteralPath -eq $script:RaceStage) { Write-Marker $script:RacePlugins 'warehouse' }
    }
    Assert (-not (Install-CuraPluginTransaction -Stage $stage -PluginsPath $script:RacePlugins -Roots $plugin.roots -OldRoots @() -LogPath $LogPath)) 'channel switch during staging refused'
    Remove-Item Function:Copy-Item
    Assert ([IO.File]::ReadAllText((Join-Path $script:RacePlugins 'cura_ferramentas/core.rbe')) -eq 'old code 2026') 'staging race preserves Warehouse code'
    Assert ([IO.File]::ReadAllText((Join-Path $script:RacePlugins 'cura_ferramentas.rb')) -eq 'old loader 2026') 'staging race preserves Warehouse loader'
    Remove-CuraExact -ParentDir $script:RacePlugins -Name 'cura_FERRAMENTAS.RB' -LogPath $LogPath
    Assert ([IO.File]::ReadAllText((Join-Path $script:RacePlugins 'cura_ferramentas.rb')) -eq 'old loader 2026') 'case alias cannot remove Warehouse loader'
    # Rollback and recovery also respect a later Warehouse conversion.
    $pending = New-Profile 'pending' @(2026);$script:PluginTransactions=@()
    Assert (Install-CuraPluginTransaction -Stage $stage -PluginsPath $pending.Versions[0].PluginsPath -Roots $plugin.roots -OldRoots @() -LogPath $LogPath) 'pending Library transaction installed'
    Write-Marker $pending.Versions[0].PluginsPath 'warehouse'
    $txn = $script:PluginTransactions[0]
    Reject { Undo-CuraPluginTransactions -LogPath $LogPath } 'rollback refuses new Warehouse owner'
    Restore-CuraPendingPluginTransactions -PluginsPath $pending.Versions[0].PluginsPath -LogPath $LogPath
    Assert (Test-Path -LiteralPath $txn.Path) 'protected transaction backup retained'
    Assert ([IO.File]::ReadAllText((Join-Path $pending.Versions[0].PluginsPath 'cura_ferramentas/core.rbe')) -eq 'new protected code') 'Warehouse payload intact after rollback/recovery refusal'
    $txn.Roots += 'cura_other_product.rb'
    $txn | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $txn.Path 'transaction.json') -Encoding UTF8
    Reject { Restore-CuraPendingPluginTransactions -PluginsPath $pending.Versions[0].PluginsPath -LogPath $LogPath } 'mixed protected journal reports pending recovery instead of no-op'
    $script:PluginTransactions=@()

    # Full uninstall in child processes: only environment destinations and
    # scheduler/UI are replaced; actual whitelist, marker and file removal run.
    $harness = Join-Path $root 'uninstall-child.ps1'
    @'
param($Source,$Profile,$LocalProfile,$Receipt,$Log)
$ErrorActionPreference='Stop'
$env:APPDATA=$Profile;$env:LOCALAPPDATA=$LocalProfile
$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($f in $a.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
function Write-CuraLog{param($LogPath,$Message,[switch]$IsError)Add-Content -LiteralPath $LogPath -Value $Message}
$script:TaskFixture=Join-Path $LocalProfile 'qa-scheduled-task'
function Unregister-ScheduledTask{param($TaskName,[bool]$Confirm,$ErrorAction)Remove-Item -LiteralPath $script:TaskFixture -Force}
$script:PhotoshopDir=Join-Path $LocalProfile 'unused-photoshop'
$script:PhotoshopBaseDir=Join-Path $LocalProfile 'unused-photoshop-base'
$script:UpdaterTaskName='qa'
Invoke-CuraUninstall -SnapshotPath $Receipt -LogPath $Log -Force
'@ | Set-Content -LiteralPath $harness -Encoding UTF8
    foreach ($mode in @('uninstall-warehouse','uninstall-biblioteca','uninstall-invalid','uninstall-mixed')) {
        $fixture = New-Profile $mode $(if ($mode -eq 'uninstall-mixed') { @(2025,2026) } else { @(2026) })
        $uninstallSource = $source
        if ($mode -eq 'uninstall-warehouse') {
            $cache = Join-Path $fixture.LocalAppData 'CURA-Biblioteca'
            [IO.File]::WriteAllText((Join-Path $cache 'install.ps1'),'old cached script')
            Update-CuraInstallerCache -SourcePath $source -AppDataDir $cache -LogPath $LogPath
            $uninstallSource = Join-Path $cache 'install.ps1'
            Assert ((Get-FileHash -LiteralPath $uninstallSource).Hash -eq (Get-FileHash -LiteralPath $source).Hash) 'normal cache refresh carries current channel-safe uninstaller'
        }
        & $engine -NoProfile -File $harness -Source $uninstallSource -Profile $fixture.AppData -LocalProfile $fixture.LocalAppData -Receipt $fixture.SnapshotPath -Log (Join-Path $fixture.Case 'uninstall.log') > (Join-Path $fixture.Case 'uninstall-output.log') 2>&1
        $rc=$LASTEXITCODE
        Assert ($rc -eq $(if ($mode -eq 'uninstall-invalid') {2} else {0})) "$mode exit status"
        foreach ($ver in $fixture.Versions) {
            $protected = $mode -in @('uninstall-warehouse','uninstall-invalid') -or ($mode -eq 'uninstall-mixed' -and $ver.Year -eq 2025)
            if ($protected) { Assert ([IO.File]::ReadAllText((Join-Path $ver.PluginsPath 'cura_ferramentas/core.rbe')) -eq "old code $($ver.Year)") "$mode protected payload unchanged" }
            else { Assert (-not (Test-Path -LiteralPath (Join-Path $ver.PluginsPath 'cura_ferramentas'))) "$mode Library module removed"; Assert (-not (Test-Path -LiteralPath (Join-Path $ver.PluginsPath 'cura_ferramentas.rb'))) "$mode Library loader removed" }
            Assert ([IO.File]::ReadAllText((Join-Path $ver.PluginsPath 'TT_Lib2/paid.rb')) -eq 'third party') "$mode third party preserved"
            Assert ([IO.File]::ReadAllText((Join-Path $ver.PluginsPath 'cura_other_product/state.bin')) -eq 'other product') "$mode other product preserved"
        }
        Assert ([IO.File]::ReadAllText($fixture.Identity) -eq '{"uuid":"outside-Plugins"}') "$mode identity preserved"
        Assert ((Test-Path -LiteralPath (Join-Path $fixture.LocalAppData 'qa-scheduled-task')) -eq ($mode -eq 'uninstall-invalid')) "$mode scheduler cleanup matches completed uninstall"
        Assert ((Test-Path -LiteralPath $fixture.SnapshotPath) -eq ($mode -eq 'uninstall-invalid')) "$mode stale receipt handled"
    }
    Write-Host "PASS: $script:Assertions channel ownership assertions (PowerShell, isolated filesystem; no native Windows/SketchUp)."
} finally { if (Test-Path -LiteralPath $root) { [IO.Directory]::Delete($root,$true) } }
