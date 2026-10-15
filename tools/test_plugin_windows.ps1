# Run with PowerShell 5.1+; AST imports functions only, never the live installer.
# All paths are a temporary fixture. Native Windows locking/ACLs need Windows CI.
$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$source = Join-Path $PSScriptRoot '../scripts/install.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
function Write-CuraLog { param($LogPath, $Message, [switch]$IsError) $script:Messages += $Message }
function Get-Process { param($Name, $ErrorAction) if ($script:SketchUpOpen) { [PSCustomObject]@{ Name = 'SketchUp' } } }
function Assert($Condition, $Label) { if (-not $Condition) { throw "FAIL: $Label`n$($script:Messages -join "`n")" }; $script:Assertions++ }
function Reject([scriptblock]$Action, $Label) { $rejected = $false; try { & $Action } catch { $rejected = $true }; Assert $rejected $Label }
$script:Assertions = 0; $script:Messages = @(); $script:SketchUpOpen = $false; $script:PluginTransactions = @()
$base = [IO.Path]::GetTempPath()
if (Test-Path '/private/tmp' -PathType Container) { $base = '/private/tmp' }
$fixture = Join-Path $base ('cura-plugin-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-FixtureZip($Path, $Variant) {
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entries = @('cura_demo/core.rbe')
        if ($Variant -ne 'missing') { $entries += 'cura_demo.rb' }
        if ($Variant -eq 'thirdparty') { $entries += 'TT_Lib2/paid.rb' }
        if ($Variant -eq 'traversal') { $entries += 'cura_demo/../../identity.json' }
        if ($Variant -eq 'duplicate') { $entries += 'CURA_DEMO.RB' }
        if ($Variant -eq 'symlink') { $entries += 'cura_demo/link' }
        foreach ($name in $entries) {
            $entry = $zip.CreateEntry($name)
            if ($name -eq 'cura_demo/link') { $entry.ExternalAttributes = 0xA1FF0000 -as [int] }
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write("new $name") } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
}
try {
    $plugin = [PSCustomObject]@{ id = 'cura-demo'; name = 'CURA demo'; version = 'new'; roots = @('cura_demo', 'cura_demo.rb') }
    foreach ($variant in @('good', 'missing', 'thirdparty', 'traversal', 'duplicate', 'symlink')) {
        $zip = Join-Path $fixture "$variant.zip"
        New-FixtureZip $zip $variant
        $stage = Join-Path $fixture "stage-$variant"
        if ($variant -eq 'good') { Prepare-CuraPluginPayload -Plugin $plugin -Archive $zip -Stage $stage }
        else { Reject { Prepare-CuraPluginPayload -Plugin $plugin -Archive $zip -Stage $stage } "reject ZIP $variant" }
    }
    $bad = Join-Path $fixture 'broken.zip'; [IO.File]::WriteAllText($bad, 'hash-valid non-ZIP')
    Reject { Prepare-CuraPluginPayload -Plugin $plugin -Archive $bad -Stage (Join-Path $fixture 'broken-stage') } 'invalid ZIP preserves old install'
    $thirdRoot = [PSCustomObject]@{ roots = @('TT_Lib2') }
    Reject { Prepare-CuraPluginPayload -Plugin $thirdRoot -Archive (Join-Path $fixture 'good.zip') -Stage (Join-Path $fixture 'bad-root') } 'third-party root rejected'

    # Inject only one low-level operation. All other copy/move/hash operations
    # remain real, including the restoration that follows the injected error.
    function Copy-Item {
        [CmdletBinding()]param([string]$LiteralPath, [string]$Destination, [switch]$Recurse, [switch]$Force)
        if ($script:Fault -eq 'copy' -and -not $script:Injected -and $Destination -match 'incoming[/\\]cura_demo.rb$') { $script:Injected = $true; throw 'injected staging copy failure' }
        Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    }
    function Move-Item {
        [CmdletBinding()]param([string]$LiteralPath, [string]$Destination, [switch]$Force)
        if ($script:Fault -in @('write', 'rollback') -and -not $script:Injected -and $LiteralPath -match 'incoming[/\\]cura_demo.rb$') { $script:Injected = $true; throw 'injected root replacement failure' }
        if ($script:Fault -eq 'rollback' -and $LiteralPath -match '[/\\]saved[/\\]') { throw 'injected restore failure' }
        Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }
    foreach ($mode in @('copy', 'write', 'receipt', 'rollback', 'reopened', 'open', 'success', 'confirmed')) {
        $case = Join-Path $fixture $mode
        $plugins = Join-Path $case 'SketchUp 2026/SketchUp/Plugins'
        New-Item -ItemType Directory -Path (Join-Path $plugins 'cura_demo'), (Join-Path $plugins 'TT_Lib2') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $plugins 'cura_demo.rb'), 'old loader')
        [IO.File]::WriteAllText((Join-Path $plugins 'cura_demo/core.rbe'), 'old encoded')
        [IO.File]::WriteAllText((Join-Path $plugins 'cura_legacy.rb'), 'old renamed root')
        [IO.File]::WriteAllText((Join-Path $plugins 'TT_Lib2/paid.rb'), 'third-party plugin')
        [IO.File]::WriteAllText((Join-Path $case 'identity.json'), 'identity outside Plugins')
        $receipt = Join-Path $case 'installed.json'
        [IO.File]::WriteAllText($receipt, '{"biblioteca_version":"old"}')
        $oldDigest = Get-CuraPluginTreeSignature $plugins
        $script:Fault = $mode; $script:Injected = $false; $script:SketchUpOpen = ($mode -eq 'open'); $script:PluginTransactions = @()
        $argsInstall = @{ Stage = (Join-Path $fixture 'stage-good'); PluginsPath = $plugins; Roots = $plugin.roots; OldRoots = @('cura_legacy.rb'); LogPath = (Join-Path $case 'install.log') }
        if ($mode -eq 'rollback') {
            Reject { Install-CuraPluginTransaction @argsInstall } 'rollback failure surfaced'
            Assert ($script:PluginTransactions.Count -eq 1) 'incomplete rollback retains transaction'
            Assert (Test-Path -LiteralPath (Join-Path $script:PluginTransactions[0].Path 'reference/cura_demo.rb')) 'incomplete rollback keeps recoverable backup'
            Assert ([IO.File]::ReadAllText($receipt) -eq '{"biblioteca_version":"old"}') 'incomplete rollback preserves old receipt'
            $script:Fault = ''
            Undo-CuraPluginTransactions -LogPath $argsInstall.LogPath
            $ok = $false
        } else { $ok = Install-CuraPluginTransaction @argsInstall }
        if ($mode -in @('receipt', 'reopened', 'success', 'confirmed')) {
            Assert $ok "$mode root installation succeeds"
            Assert (-not (Test-Path (Join-Path $plugins 'cura_legacy.rb'))) "$mode old root removed transactionally"
            if ($mode -in @('receipt', 'reopened')) {
                if ($mode -eq 'reopened') { $script:SketchUpOpen = $true }
                try {
                    # A directory at the staging filename produces a real IO
                    # failure; the existing receipt must remain byte-identical.
                    New-Item -ItemType Directory -Path "$receipt.tmp" | Out-Null
                    $script:Injected = $true
                    Save-CuraSnapshot -Snapshot ([PSCustomObject]@{ biblioteca_version = 'new' }) -SnapshotPath $receipt
                } catch {
                    if ($mode -eq 'reopened') {
                        Reject { Undo-CuraPluginTransactions -LogPath $argsInstall.LogPath } 'reopened SketchUp defers rollback'
                        Assert ([IO.File]::ReadAllText((Join-Path $plugins 'cura_demo.rb')) -eq 'new cura_demo.rb') 'rollback leaves live roots unchanged'
                        Assert ($script:PluginTransactions.Count -eq 1) 'reopened SketchUp keeps journal and backup'
                        $script:SketchUpOpen = $false
                        $script:PluginTransactions = @() # next process loads the durable journal
                        Restore-CuraPendingPluginTransactions -PluginsPath $plugins -LogPath $argsInstall.LogPath
                    } else { Undo-CuraPluginTransactions -LogPath $argsInstall.LogPath }
                }
            } else {
                Save-CuraSnapshot -Snapshot ([PSCustomObject]@{ biblioteca_version = 'new' }) -SnapshotPath $receipt
                if ($mode -eq 'confirmed') {
                    $script:PluginTransactions = @() # receipt committed; cleanup interrupted
                    Restore-CuraPendingPluginTransactions -PluginsPath $plugins -LogPath $argsInstall.LogPath -SnapshotPath $receipt
                } else { Complete-CuraPluginTransactions }
                Assert ([IO.File]::ReadAllText((Join-Path $plugins 'cura_demo.rb')) -eq 'new cura_demo.rb') 'new loader verified'
                $ver = [PSCustomObject]@{ Year = 2026; PluginsPath = $plugins }
                $manifest = [PSCustomObject]@{ biblioteca_version = 'new'; plugins = @($plugin) }
                $snap = [PSCustomObject]@{ biblioteca_version = 'new'; sketchup_versions = @([PSCustomObject]@{ year = 2026; plugins_path = $plugins; plugins = @($plugin) }); fonts = @() }
                Assert (Test-CuraUpToDate -Manifest $manifest -OldSnapshot $snap -DetectedVersions @($ver)) 'idempotent no-op'
            }
        } else { Assert (-not $ok) "$mode fails without success receipt" }
        if ($mode -notin @('success', 'confirmed')) {
            Assert ((Get-CuraPluginTreeSignature $plugins) -eq $oldDigest) "$mode rollback restores every byte/root"
            Assert ([IO.File]::ReadAllText($receipt) -eq '{"biblioteca_version":"old"}') "$mode old receipt preserved"
        }
        if ($mode -in @('copy', 'write', 'receipt', 'rollback')) { Assert $script:Injected "$mode injected error actually reached" }
        Assert ([IO.File]::ReadAllText((Join-Path $plugins 'TT_Lib2/paid.rb')) -eq 'third-party plugin') "$mode third-party untouched"
        Assert ([IO.File]::ReadAllText((Join-Path $case 'identity.json')) -eq 'identity outside Plugins') "$mode identity untouched"
        Assert (@(Get-ChildItem -LiteralPath $case -Recurse -Force -Directory | Where-Object Name -like '.cura-plugin-transaction-*').Count -eq 0) "$mode no incomplete transaction"
        Assert ($script:PluginTransactions.Count -eq 0) "$mode no pending transaction"
    }
    $collision = [PSCustomObject]@{ id = 'other'; roots = @('cura_demo.rb') }
    $caseCollision = [PSCustomObject]@{ id = 'other'; roots = @('cura_DEMO.rb') }
    $migrated = [PSCustomObject]@{ id = 'other'; roots = @('cura_legacy.rb') }
    $oldPlugin = [PSCustomObject]@{ id = 'cura-demo'; roots = @('cura_legacy.rb') }
    Assert (-not (Test-CuraPluginPlan -Plugins @($plugin, $collision) -OldPlugins @())) 'same-root collision rejected'
    Assert (-not (Test-CuraPluginPlan -Plugins @($plugin, $caseCollision) -OldPlugins @())) 'case-insensitive collision rejected'
    Assert (-not (Test-CuraPluginPlan -Plugins @($plugin, $migrated) -OldPlugins @($oldPlugin))) 'old-root migration collision rejected'
    $partialPath = Join-Path $fixture 'partial'
    New-Item -ItemType Directory -Path (Join-Path $partialPath 'cura_demo') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $partialPath 'cura_demo/core.rbe'), 'remaining payload')
    $partialReceipt = @(Get-CuraPresentPluginReceipts -Plugins @($plugin) -PluginsPath $partialPath)
    Assert ($partialReceipt.Count -eq 1 -and $partialReceipt[0].version -eq 'new') 'partial old plugin retains original receipt'
    # Fresh install has no previous roots/receipt and must commit normally.
    $fresh = Join-Path $fixture 'fresh/SketchUp/Plugins'
    New-Item -ItemType Directory -Path $fresh -Force | Out-Null
    $script:Fault = ''; $script:SketchUpOpen = $false
    Assert (Install-CuraPluginTransaction -Stage (Join-Path $fixture 'stage-good') -PluginsPath $fresh -Roots $plugin.roots -OldRoots @() -LogPath (Join-Path $fixture 'fresh.log')) 'fresh install without old roots'
    Save-CuraSnapshot -Snapshot ([PSCustomObject]@{ biblioteca_version = 'new' }) -SnapshotPath (Join-Path $fixture 'fresh/installed.json')
    Complete-CuraPluginTransactions
    Assert ((Get-Content -LiteralPath (Join-Path $fixture 'fresh/installed.json') -Raw | ConvertFrom-Json).biblioteca_version -eq 'new') 'fresh receipt persisted'
    $actualZip = Join-Path $fixture 'actual-payload.zip'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../payload/cura-ferramentas.rbz') -Destination $actualZip
    $actualPlugin = [PSCustomObject]@{ roots = @('cura_ferramentas', 'cura_ferramentas.rb') }
    Prepare-CuraPluginPayload -Plugin $actualPlugin -Archive $actualZip -Stage (Join-Path $fixture 'actual-stage')
    Assert (Test-Path -LiteralPath (Join-Path $fixture 'actual-stage/cura_ferramentas.rb')) 'checked-in payload accepted'
    # HTTPS policy is exercised with a fake transport; no network or certificate
    # store changes. The real factory must disable automatic redirects.
    Assert (-not (New-CuraHttpsRequest -Uri ([uri]'https://example.invalid/file') -TimeoutSec 5).AllowAutoRedirect) 'real HTTPS transport disables auto redirects'
    $realRequestFunction = ${function:New-CuraHttpsRequest}.ToString()
    function New-CuraHttpsRequest {
        param([uri]$Uri, [int]$TimeoutSec)
        $script:Requests += $Uri.AbsoluteUri
        $status = 200; $headers = @{}
        if ($script:HttpsMode -eq 'downgrade') { $status = 302; $headers.Location = 'http://example.invalid/payload' }
        if ($script:HttpsMode -eq 'loop') { $status = 302; $headers.Location = '/again' }
        if ($script:HttpsMode -eq 'relative' -and $script:Requests.Count -eq 1) { $status = 302; $headers.Location = '/payload' }
        $response = [PSCustomObject]@{ StatusCode = $status; Headers = $headers }
        $response | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:DisposedResponses++ }
        $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value { [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('HTTPS fixture bytes'), $false) }
        $request = [PSCustomObject]@{ Response = $response }
        $request | Add-Member -MemberType ScriptMethod -Name GetResponse -Value { $this.Response }
        return $request
    }
    $httpsOut = Join-Path $fixture 'download.bin'
    $script:Requests = @(); $script:DisposedResponses = 0; $script:HttpsMode = 'ok'
    Reject { Receive-CuraHttpsFile -Url 'http://example.invalid/file' -OutFile $httpsOut } 'HTTP initial URL refused'
    Assert ($script:Requests.Count -eq 0) 'HTTP never reaches transport'
    $script:HttpsMode = 'downgrade'
    Reject { Receive-CuraHttpsFile -Url 'https://example.invalid/file' -OutFile $httpsOut } 'HTTP redirect refused'
    Assert ($script:Requests.Count -eq 1) 'downgrade stopped before HTTP request'
    Assert (-not (Test-Path -LiteralPath $httpsOut)) 'rejected redirects write no payload'
    Assert ($script:DisposedResponses -eq 1) 'redirect response disposed'
    $script:Requests = @(); $script:DisposedResponses = 0; $script:HttpsMode = 'relative'
    Receive-CuraHttpsFile -Url 'https://example.invalid/file' -OutFile $httpsOut
    Assert ($script:Requests.Count -eq 2 -and $script:Requests[1] -eq 'https://example.invalid/payload') 'relative redirect resolves over HTTPS'
    Assert ([IO.File]::ReadAllText($httpsOut) -eq 'HTTPS fixture bytes') 'HTTPS download bytes copied'
    Assert ($script:DisposedResponses -eq 2) 'all HTTPS responses disposed'
    $script:Requests = @(); $script:HttpsMode = 'loop'
    Reject { Receive-CuraHttpsFile -Url 'https://example.invalid/file' -OutFile $httpsOut } 'redirect loop bounded'
    Assert ($script:Requests.Count -eq 11) 'maximum redirect count enforced'
    ${function:New-CuraHttpsRequest} = [scriptblock]::Create($realRequestFunction)
    # The scheduled wrapper embeds this same HTTPS implementation; no native
    # task is registered here.
    function New-ScheduledTaskAction { param($Execute, $Argument) $script:TaskArguments = $Argument; [PSCustomObject]@{} }
    function New-ScheduledTaskTrigger { param([switch]$AtLogOn, [switch]$Daily, $At) [PSCustomObject]@{} }
    function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) [PSCustomObject]@{} }
    function New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable, [switch]$DontStopOnIdleEnd, $ExecutionTimeLimit) [PSCustomObject]@{} }
    function Register-ScheduledTask { [CmdletBinding()]param($TaskName, $Action, $Trigger, $Principal, $Settings, [switch]$Force) }
    Register-CuraUpdater -TaskName 'fixture' -OfficialBaseUrl 'https://example.invalid' -LogPath (Join-Path $fixture 'schedule.log')
    $encoded = ($script:TaskArguments -split '-EncodedCommand ')[1]
    $wrapper = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
    $wrapperErrors = $null; $wrapperTokens = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($wrapper, [ref]$wrapperTokens, [ref]$wrapperErrors)
    Assert ($wrapperErrors.Count -eq 0) 'generated scheduled wrapper parses'
    Assert ($wrapper.Contains('$request.AllowAutoRedirect = $false')) 'scheduled wrapper disables auto redirects'
    Assert ($wrapper.Contains('Receive-CuraHttpsFile -Url $u')) 'scheduled wrapper uses HTTPS downloader'
    Write-Host "PASS: $script:Assertions PowerShell plugin assertions (real isolated filesystem; Windows native locking/ACLs pending)."
} finally {
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete($fixture, $true) }
}
