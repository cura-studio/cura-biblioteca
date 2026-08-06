<#
.SYNOPSIS
    Instalador da Biblioteca CURA para SketchUp (Windows).
.DESCRIPTION
    Baixa manifest.json do GitHub Releases e instala os plugins (.rbz) e fontes
    em todas as versões do SketchUp encontradas no computador, sem precisar de
    privilégios de administrador (tudo per-user).
    Re-rodar o instalador conserta uma instalação (limpa e reinstala).
    Use -Uninstall para remover tudo que este instalador colocou no sistema.
.PARAMETER Uninstall
    Remove os itens registrados no snapshot desta instalação.
.PARAMETER Force
    Usado com -Uninstall para pular a confirmação (modo não-interativo,
    usado pelo desinstalador gerado pelo Inno Setup).
.PARAMETER BaseUrl
    Origem dos arquivos (manifest.json, .rbz, fonts.zip). Por padrão aponta
    para o release "latest" do GitHub. Aceita também um caminho local
    (pasta com os mesmos arquivos) para teste, ou a variável de ambiente
    CURA_BASE_URL (mesmo formato) quando -BaseUrl não for informado.
#>

#Requires -Version 5.0

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Force,
    # -Quiet: modo não-interativo usado pelo auto-update agendado. Sem prompts,
    # sem esperar o SketchUp fechar (adia se estiver aberto), no-op quando já
    # está na versão do manifest.
    [switch]$Quiet,
    # -Limpar: "limpar SketchUp". Move todo plugin de terceiro pra uma pasta de
    # recuperação em Documentos, preservando só o cura. Não instala nada.
    [switch]$Limpar,
    [string]$BaseUrl = $(if ($env:CURA_BASE_URL) { $env:CURA_BASE_URL } else { "https://github.com/joaotegoni/cura-biblioteca/releases/latest/download" })
)

# --- WOW64: o Setup.exe do Inno é 32-bit, então este script nasce em SysWOW64
# e enxerga o registro redirecionado (HKLM\SOFTWARE\WOW6432Node), onde o
# SketchUp não aparece. Re-executa em 64-bit REPASSANDO os parâmetros — sem
# repassar, a desinstalação do Inno viraria uma instalação completa. Se o
# sysnative não existir, segue em 32-bit mesmo. Tem que vir logo depois do
# param(), que é a primeira instrução executável obrigatória. ---
if ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and [Environment]::Is64BitOperatingSystem) {
    $sysnativePs = Join-Path $env:windir "sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $sysnativePs) {
        $fwd = @()
        foreach ($k in $PSBoundParameters.Keys) {
            $v = $PSBoundParameters[$k]
            if ($v -is [switch]) {
                if ($v.IsPresent) { $fwd += "-$k" }
            } else {
                $fwd += @("-$k", "$v")
            }
        }
        & $sysnativePs -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
        $rc = $LASTEXITCODE
        if ($null -eq $rc) { $rc = 2 }
        exit $rc
    }
}

# URL FIXA da release oficial — usada só pelo registro do auto-update. Nunca
# usa $BaseUrl aqui: o updater tem que puxar sempre da release de verdade,
# mesmo que esta execução esteja com CURA_BASE_URL apontando pasta de teste.
$script:OfficialBaseUrl = "https://github.com/joaotegoni/cura-biblioteca/releases/latest/download"
$script:UpdaterTaskName = "CURA Biblioteca Updater"
# Chave de fontes per-user. Escopo de SCRIPT de propósito: o -Uninstall roda e
# sai muito antes do bloco de fontes, então uma variável criada lá embaixo
# chegaria $null na remoção.
$script:FontsRegKey = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"

# --- TLS 1.2 + encoding do console (tem que vir antes de qualquer output) ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
} catch {
    # console antigo pode recusar a troca de encoding; segue mesmo assim
}

$ErrorActionPreference = "Stop"

# --- Identidade visual CURA (paleta E1 fechada: verde cura = marca, terracota
# = erro terminal, mais nada). ANSI 256-color quando o host suporta VT; senão
# cai pro Write-Host -ForegroundColor clássico. Nunca depende de truecolor. ---
$script:AnsiOk = $false
try {
    if ($Host.UI.SupportsVirtualTerminal) { $script:AnsiOk = $true }
} catch {
    $script:AnsiOk = $false
}
$script:Esc = [char]27
$script:AnsiMarca = "$($script:Esc)[1m$($script:Esc)[38;5;151m"
$script:AnsiErro  = "$($script:Esc)[1m$($script:Esc)[38;5;131m"
$script:AnsiReset = "$($script:Esc)[0m"

# --- Paths fixos (cache/log/snapshot deste instalador) ---
$AppDataDir   = Join-Path $env:LOCALAPPDATA "CURA-Biblioteca"
$LogPath      = Join-Path $AppDataDir "install.log"
$SnapshotPath = Join-Path $AppDataDir "installed.json"

if (-not (Test-Path -LiteralPath $AppDataDir)) {
    New-Item -ItemType Directory -Path $AppDataDir -Force | Out-Null
}

# ============================================================================
# Funções auxiliares
# ============================================================================

function Write-CuraBanner {
    param([Parameter(Mandatory = $true)][string]$LogPath)
    # sem número de versão aqui (paridade com o banner() do install.sh): o
    # banner é impresso antes do download do manifest, que é a única fonte de
    # verdade da versão. A versão real sai no resumo final.
    $marca = "{ cura }  biblioteca"
    if ($script:AnsiOk) {
        Write-Host "  $($script:AnsiMarca)$marca$($script:AnsiReset)"
    } else {
        Write-Host "  $marca" -ForegroundColor DarkGreen
    }
    Write-Host "  instalador windows"
    try {
        Add-Content -LiteralPath $LogPath -Value "" -Encoding UTF8
        Add-Content -LiteralPath $LogPath -Value "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $marca / instalador windows =====" -Encoding UTF8
    } catch {
        # log indisponível não trava o fluxo
    }
}

function Write-CuraLog {
    # Voz cura (E5): mensagem sempre em minúsculas, exceto números, siglas e
    # nomes de produto (SketchUp, Windows, GitHub). Sem emoji. Única cor fora
    # do default é o terracota de erro - aviso não ganha cor própria.
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true, Position = 1)][string]$Message,
        [switch]$IsError
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        # se o log não puder ser escrito (disco cheio, permissão), não trava o fluxo
    }
    if ($IsError) {
        if ($script:AnsiOk) {
            Write-Host "$($script:AnsiErro)$Message$($script:AnsiReset)"
        } else {
            Write-Host $Message -ForegroundColor DarkRed
        }
    } else {
        Write-Host $Message
    }
}

function Resolve-CuraLocalPath {
    # Se $BaseUrl aponta pra pasta local (teste), devolve o path resolvido.
    # Devolve $null se for uma URL remota de verdade.
    param([Parameter(Mandatory = $true)][string]$BaseUrl)
    $path = $BaseUrl
    if ($path -like "file://*") {
        $path = $path -replace '^file://', ''
    }
    if ($path -match '^https?://') {
        return $null
    }
    if (Test-Path -LiteralPath $path) {
        return $path
    }
    return $null
}

function Get-CuraRemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [int]$Retries = 3,
        [int]$TimeoutSec = 30
    )
    $attempt = 0
    $lastMessage = ""
    while ($attempt -lt $Retries) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec
            return $true
        } catch {
            $lastMessage = $_.Exception.Message
            Write-CuraLog -LogPath $LogPath -Message "aviso: tentativa $attempt de $Retries falhou para $Url : $lastMessage"
            if ($attempt -lt $Retries) {
                Start-Sleep -Seconds 2
            }
        }
    }
    Write-CuraLog -LogPath $LogPath -Message "erro / falha definitiva ao baixar $Url : $lastMessage" -IsError
    return $false
}

function Get-CuraAsset {
    # Copia de pasta local (modo teste) ou baixa de $BaseUrl/$FileName (modo normal).
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    $localBase = Resolve-CuraLocalPath -BaseUrl $BaseUrl
    if ($null -ne $localBase) {
        $sourcePath = Join-Path $localBase $FileName
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            Write-CuraLog -LogPath $LogPath -Message "erro / arquivo local não encontrado: $sourcePath" -IsError
            return $false
        }
        Copy-Item -LiteralPath $sourcePath -Destination $OutFile -Force
        Write-CuraLog -LogPath $LogPath -Message "copiado localmente (modo teste): $sourcePath"
        return $true
    }
    $url = "$BaseUrl/$FileName"
    return Get-CuraRemoteFile -Url $url -OutFile $OutFile -LogPath $LogPath
}

function Get-CuraPluginPayload {
    # Baixa o payload de um plugin. Contrato do manifest (SPEC.md): url null
    # -> BASE/<file> (via Get-CuraAsset); url absoluta -> usa ela direto
    # (aceita também path local/file://, modo teste, espelhando
    # Resolve-CuraLocalPath). O Mac já respeita isso; aqui equipara.
    param(
        [Parameter(Mandatory = $true)]$Plugin,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    if ($Plugin.url) {
        $localPath = Resolve-CuraLocalPath -BaseUrl $Plugin.url
        if ($null -ne $localPath) {
            if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
                Write-CuraLog -LogPath $LogPath -Message "erro / arquivo local não encontrado: $localPath" -IsError
                return $false
            }
            Copy-Item -LiteralPath $localPath -Destination $OutFile -Force
            Write-CuraLog -LogPath $LogPath -Message "copiado localmente (modo teste, url própria): $localPath"
            return $true
        }
        return Get-CuraRemoteFile -Url $Plugin.url -OutFile $OutFile -LogPath $LogPath
    }
    return Get-CuraAsset -BaseUrl $BaseUrl -FileName $Plugin.file -OutFile $OutFile -LogPath $LogPath
}

function Get-CuraSketchUpVersions {
    # Detecta instalações do SketchUp por DUAS vias e une os anos:
    #   1. a pasta de perfil %APPDATA%\SketchUp\SketchUp 20XX;
    #   2. as chaves que o instalador da Trimble cria no registro
    #      (HKLM/HKCU \Software\SketchUp\SketchUp 20XX).
    # Só a pasta não bastava: ela é do PERFIL e não existe num SketchUp
    # recém-instalado que nunca foi aberto - o instalador dizia "SketchUp não
    # encontrado" com o programa ali na frente do aluno. Ler HKLM exige view
    # 64-bit; a guarda de sysnative lá no topo garante isso.
    # Devolve só os anos que atendem $MinVersion. Nunca lança erro se nada
    # existir (SketchUp não instalado ainda).
    param([Parameter(Mandatory = $true)][int]$MinVersion)
    $anos = @{}
    $root = Join-Path $env:APPDATA "SketchUp"
    try {
        $dirs = @(Get-ChildItem -Path $root -Directory -Filter "SketchUp 20*" -ErrorAction Stop)
    } catch {
        $dirs = @()
    }
    foreach ($dir in $dirs) {
        if ($dir.Name -match '20\d\d') { $anos[[int]$Matches[0]] = $true }
    }
    foreach ($hive in @("HKLM:\SOFTWARE\SketchUp", "HKCU:\Software\SketchUp")) {
        try {
            $keys = @(Get-ChildItem -Path $hive -ErrorAction Stop)
        } catch {
            continue
        }
        foreach ($k in $keys) {
            if ($k.PSChildName -match '^SketchUp (20\d\d)$') { $anos[[int]$Matches[1]] = $true }
        }
    }
    $result = @()
    foreach ($year in ($anos.Keys | Sort-Object)) {
        if ($year -ge $MinVersion) {
            $versionDir = Join-Path $root "SketchUp $year"
            $result += [PSCustomObject]@{
                Year        = $year
                VersionDir  = $versionDir
                PluginsPath = (Join-Path $versionDir "SketchUp\Plugins")
            }
        }
    }
    return $result
}

function Test-CuraSafeLeafName {
    # Espelha is_safe_leaf_name do install.sh (SPEC.md linha ~133): rejeita
    # nome vazio e qualquer nome contendo separador de path ("\" ou "/") ou
    # "..". Guarda anti path-traversal aplicada a todo nome vindo do
    # manifest/snapshot antes de virar alvo de remoção.
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name -match '[\\/]' -or $Name -match '\.\.') { return $false }
    return $true
}

function Remove-CuraExact {
    # Remove SÓ por nome exato (arquivo ou pasta) dentro de $ParentDir.
    # Nunca usa wildcard/glob - literal match apenas. Nome que falhar a
    # guarda anti path-traversal é rejeitado (log de aviso + skip) antes de
    # qualquer Join-Path.
    param(
        [Parameter(Mandatory = $true)][string]$ParentDir,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    if (-not (Test-CuraSafeLeafName -Name $Name)) {
        Write-CuraLog -LogPath $LogPath -Message "aviso: nome de remoção rejeitado (path-traversal?): '$Name' - ignorado."
        return
    }
    $target = Join-Path $ParentDir $Name
    if (Test-Path -LiteralPath $target) {
        try {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            Write-CuraLog -LogPath $LogPath -Message "removido: $target"
        } catch {
            Write-CuraLog -LogPath $LogPath -Message "aviso: falha ao remover $target : $($_.Exception.Message)"
        }
    }
}

function Get-CuraOldSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotPath
    )
    if (Test-Path -LiteralPath $SnapshotPath) {
        try {
            $raw = Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8
            return ($raw | ConvertFrom-Json)
        } catch {
            return $null
        }
    }
    return $null
}

function Wait-CuraSketchUpClosed {
    # Verifica (e, se interativo, aguarda) que o SketchUp não está aberto.
    # -Quiet: adia (exit 0), sem alarde, igual ao check inicial. Interativo:
    # pede pra fechar e espera enter, com opção de cancelar. Chamada tanto no
    # início do fluxo quanto de novo logo antes da 1ª remoção/Expand-Archive
    # (o download dos payloads pode levar minutos e o SketchUp pode ter sido
    # aberto nesse meio tempo).
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [switch]$Quiet
    )
    if ($Quiet) {
        if (Get-Process -Name "SketchUp*" -ErrorAction SilentlyContinue) {
            Write-CuraLog -LogPath $LogPath -Message "quiet: SketchUp aberto, adiando update."
            exit 0
        }
    } else {
        while ($true) {
            $procs = Get-Process -Name "SketchUp*" -ErrorAction SilentlyContinue
            if (-not $procs) { break }
            Write-Host "o SketchUp está aberto. feche o programa e pressione enter para continuar (ou digite 'sair' para cancelar)."
            $resp = Read-Host
            if ($resp -match '^(sair|exit|q)$') {
                Write-CuraLog -LogPath $LogPath -Message "aviso: instalação cancelada pelo usuário (SketchUp aberto)."
                exit 2
            }
        }
    }
}

function Test-CuraUpToDate {
    # Decide se dá pra pular a instalação inteira (no-op). Só quando NADA mudou:
    # mesma biblioteca_version no snapshot, toda versão do SketchUp detectada já
    # está no snapshot com seus arquivos no lugar, e todas as fontes no lugar.
    # Se surgiu um SketchUp novo (não presente no snapshot), NÃO é no-op — tem
    # que instalar os plugins nele.
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        $OldSnapshot,
        $DetectedVersions
    )
    if ($null -eq $OldSnapshot) { return $false }
    if ($OldSnapshot.biblioteca_version -ne $Manifest.biblioteca_version) { return $false }

    foreach ($ver in $DetectedVersions) {
        $snapVer = $null
        foreach ($sv in $OldSnapshot.sketchup_versions) {
            if ($sv.year -eq $ver.Year) { $snapVer = $sv; break }
        }
        if ($null -eq $snapVer) { return $false }   # SketchUp novo -> precisa instalar

        # Autoritativo contra o MANIFEST atual, não contra o que o snapshot
        # registrou: todo root de todo plugin do manifest precisa existir de
        # verdade no Plugins/ desta versão. Corrige o caso de uma rodada
        # anterior ter falhado em instalar um plugin (sha256/download) - se o
        # snapshot só tivesse os plugins que ela registrou, o no-op passaria
        # mesmo faltando plugin em disco.
        foreach ($plugin in $Manifest.plugins) {
            foreach ($r in $plugin.roots) {
                if (-not (Test-Path -LiteralPath (Join-Path $ver.PluginsPath $r))) { return $false }
            }
        }
    }

    foreach ($f in $OldSnapshot.fonts) {
        if (-not (Test-Path -LiteralPath $f.file)) { return $false }
    }
    return $true
}

function Register-CuraUpdater {
    # Registra a tarefa agendada per-user (sem admin) que roda o auto-update:
    # no logon + diária de reserva. A ação baixa SEMPRE o install.ps1 mais
    # recente da release oficial e roda -Quiet. Falha aqui é aviso, nunca erro
    # fatal — a instalação principal já terminou com sucesso quando chegamos aqui.
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$OfficialBaseUrl,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    try {
        # comando interno: TLS 1.2, baixa o install.ps1 latest pro TEMP e roda
        # -Quiet. Empacotado com -EncodedCommand (base64 UTF-16LE) pra não
        # depender de escaping de aspas na linha de comando da tarefa agendada.
        # Roda o baixado como PROCESSO FILHO (não `&` direto): install.ps1
        # termina com `exit`, que mataria este wrapper inteiro antes de
        # conseguir copiar o script pro cache depois. Rodando como filho, o
        # exit code vem por $LASTEXITCODE sem derrubar o wrapper. Se rodou
        # até um dos exit codes esperados do próprio script (0/1/2/3 - ou seja,
        # não foi um crash/parse error), copia o baixado por cima do cache em
        # {localappdata}\CURA-Biblioteca\install.ps1 (se o dir existir), pra
        # que o uninstall do Inno (que roda essa cópia congelada) também
        # receba fixes futuros.
        $inner = @"
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$u='$OfficialBaseUrl/install.ps1'
`$o=Join-Path `$env:TEMP 'cura-updater.ps1'
try { Invoke-WebRequest -Uri `$u -OutFile `$o -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop } catch { exit 0 }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `$o -Quiet
`$code = `$LASTEXITCODE
if (`$code -eq 0 -or `$code -eq 1 -or `$code -eq 2 -or `$code -eq 3) {
    `$cache = Join-Path `$env:LOCALAPPDATA 'CURA-Biblioteca'
    if (Test-Path -LiteralPath `$cache) {
        Copy-Item -LiteralPath `$o -Destination (Join-Path `$cache 'install.ps1') -Force -ErrorAction SilentlyContinue
    }
}
exit `$code
"@
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"

        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
            $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
            $trigLogon = New-ScheduledTaskTrigger -AtLogOn
            $trigDaily = New-ScheduledTaskTrigger -Daily -At "12:00"
            # roda como o usuário atual, privilégio limitado (sem admin), só quando logado.
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
            $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trigLogon, $trigDaily) `
                -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
            Write-CuraLog -LogPath $LogPath -Message "auto-update registrado (logon + diária)"
        } else {
            # fallback sem o módulo ScheduledTasks (Win7 + WMF 5.1): schtasks.exe
            # (só logon). O /TR aceita no máximo 262 caracteres e o
            # -EncodedCommand sozinho passa de 1800 - embutir o base64 aqui
            # nunca criava a tarefa. Grava o wrapper como arquivo e aponta a
            # tarefa pra ele (~135 caracteres).
            $updaterPath = Join-Path $AppDataDir "updater.ps1"
            Set-Content -LiteralPath $updaterPath -Value $inner -Encoding UTF8
            # as \" são pro schtasks, não pro PowerShell: ele repassa a string
            # inteira entre aspas e o schtasks precisa das aspas internas pra
            # aguentar um caminho de perfil com espaço.
            $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \`"$updaterPath\`""
            & schtasks.exe /Create /TN $TaskName /TR $tr /SC ONLOGON /F 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-CuraLog -LogPath $LogPath -Message "auto-update registrado via schtasks (logon)"
            } else {
                Write-CuraLog -LogPath $LogPath -Message "aviso: não foi possível registrar o auto-update (schtasks retornou $LASTEXITCODE) - a biblioteca não vai se atualizar sozinha nesta máquina."
            }
        }
    } catch {
        Write-CuraLog -LogPath $LogPath -Message "aviso: não foi possível registrar o auto-update: $($_.Exception.Message)"
    }
}

function Unregister-CuraUpdater {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    try {
        # log honesto: só diz que desregistrou se alguma das duas vias tirou a
        # tarefa de verdade. "não estava registrada" também é informação útil
        # numa triagem de "o aluno não recebe update".
        $removido = $false
        if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
            try {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
                $removido = $true
            } catch {
                $removido = $false
            }
        }
        if (-not $removido) {
            & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $removido = $true }
        }
        if ($removido) {
            Write-CuraLog -LogPath $LogPath -Message "auto-update desregistrado"
        } else {
            Write-CuraLog -LogPath $LogPath -Message "auto-update não estava registrado (nada a remover)"
        }
    } catch {
        # tarefa pode nem existir — ignorar
    }
}

function Invoke-CuraUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotPath,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [switch]$Force
    )
    if (-not (Test-Path -LiteralPath $SnapshotPath)) {
        Write-Host "nada instalado por este instalador (nenhum snapshot encontrado)."
        exit 0
    }

    # Reaproveita Get-CuraOldSnapshot (já protegido com try/catch) em vez de
    # ler/parsear cru aqui - snapshot corrompido não pode virar exceção não
    # tratada no meio do -Uninstall.
    $snap = Get-CuraOldSnapshot -SnapshotPath $SnapshotPath
    if ($null -eq $snap) {
        Write-CuraLog -LogPath $LogPath -Message "aviso: snapshot ilegível ou corrompido ($SnapshotPath) - nada a desinstalar."
        Write-Host "não foi possível ler o registro desta instalação (arquivo corrompido)."
        Write-Host "log: $LogPath"
        exit 0
    }

    Write-Host "itens que serão removidos:"
    foreach ($ver in $snap.sketchup_versions) {
        foreach ($p in $ver.plugins) {
            Write-Host "  - plugin $($p.name) v$($p.version) (SketchUp $($ver.year))"
        }
    }
    foreach ($f in $snap.fonts) {
        Write-Host "  - fonte: $($f.file)"
    }

    if (-not $Force) {
        $resp = Read-Host "confirma a remoção? (s/n)"
        if ($resp -notmatch '^[sSyY]') {
            Write-Host "cancelado pelo usuário. nada foi removido."
            exit 0
        }
    }

    # Whitelist de prefixo no PARENTDIR: Remove-CuraExact já valida o Name
    # (path-traversal), mas o plugins_path em si vem cru do snapshot - se
    # estiver corrompido/adulterado apontando pra fora da árvore do
    # SketchUp, nada deveria ser removido lá. Mesma ideia da whitelist de
    # fontes logo abaixo.
    $sketchUpRootUninstall = [System.IO.Path]::GetFullPath((Join-Path $env:APPDATA "SketchUp"))
    foreach ($ver in $snap.sketchup_versions) {
        $pluginsPathSafe = $false
        try {
            $resolvedPluginsPath = [System.IO.Path]::GetFullPath($ver.plugins_path)
            $pluginsPathSafe = $resolvedPluginsPath.StartsWith($sketchUpRootUninstall, [StringComparison]::OrdinalIgnoreCase)
        } catch {
            $pluginsPathSafe = $false
        }
        if (-not $pluginsPathSafe) {
            Write-CuraLog -LogPath $LogPath -Message "aviso: plugins_path fora do diretório esperado, ignorado: $($ver.plugins_path)"
            continue
        }
        foreach ($p in $ver.plugins) {
            foreach ($r in $p.roots) {
                Remove-CuraExact -ParentDir $ver.plugins_path -Name $r -LogPath $LogPath
            }
        }
    }
    # Whitelist de prefixo (espelha is_allowed_removal_path do install.sh):
    # só remove o arquivo de fonte do snapshot se ele está DENTRO do dir de
    # fontes per-user esperado - nunca confia cegamente no path gravado.
    $winFontsDirUninstall = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
    foreach ($f in $snap.fonts) {
        $fontInsideExpectedDir = $false
        try {
            $resolvedFont     = [System.IO.Path]::GetFullPath($f.file)
            $resolvedFontsDir = [System.IO.Path]::GetFullPath($winFontsDirUninstall)
            $fontInsideExpectedDir = $resolvedFont.StartsWith($resolvedFontsDir, [StringComparison]::OrdinalIgnoreCase)
        } catch {
            $fontInsideExpectedDir = $false
        }
        if (-not $fontInsideExpectedDir) {
            Write-CuraLog -LogPath $LogPath -Message "aviso: caminho de fonte fora do diretório esperado, ignorado: $($f.file)"
            continue
        }
        if (Test-Path -LiteralPath $f.file) {
            Remove-Item -LiteralPath $f.file -Force -ErrorAction SilentlyContinue
            Write-CuraLog -LogPath $LogPath -Message "fonte removida: $($f.file)"
        }
        # -ErrorAction não suprime erro de BINDING: reg_name vazio no snapshot
        # estouraria aqui no meio da desinstalação.
        if (-not [string]::IsNullOrEmpty($f.reg_name)) {
            Remove-ItemProperty -Path $script:FontsRegKey -Name $f.reg_name -ErrorAction SilentlyContinue
        }
    }

    Unregister-CuraUpdater -TaskName $script:UpdaterTaskName -LogPath $LogPath

    Remove-Item -LiteralPath $SnapshotPath -Force -ErrorAction SilentlyContinue
    Write-CuraLog -LogPath $LogPath -Message "desinstalação concluída. snapshot removido."
    Write-Host ""
    Write-Host "biblioteca cura removida deste computador."
    Write-Host "log: $LogPath"
    exit 0
}

# ============================================================================
# Fluxo principal
# ============================================================================

Write-CuraBanner -LogPath $LogPath

# --- Lock de concorrência: mutex nomeado per-user. Evita dois processos
# mexendo ao mesmo tempo em Plugins/ e installed.json - ex.: a Tarefa
# Agendada dispara no logon/12h bem na hora em que o aluno roda o
# Setup.exe de novo. WaitOne(0) não espera: se já tem dono, desiste na hora
# em vez de travar (o próximo gatilho do updater tenta de novo sozinho).
# Vale pro fluxo de instalação E pro -Uninstall - por isso é adquirido antes
# do "if ($Uninstall)". Liberado no finally lá embaixo.
$script:CuraMutex = New-Object System.Threading.Mutex($false, 'Local\CuraBibliotecaInstaller')
$script:CuraMutexOwned = $false
try {
    $script:CuraMutexOwned = $script:CuraMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # dono anterior encerrou sem liberar (crash) - ainda assim conseguimos o lock
    $script:CuraMutexOwned = $true
}
if (-not $script:CuraMutexOwned) {
    Write-CuraLog -LogPath $LogPath -Message "aviso: outra operação da biblioteca cura já está em andamento - encerrando."
    if (-not $Quiet) {
        Write-Host "outra operação da biblioteca cura já está em andamento. tente novamente em alguns instantes."
    }
    $script:CuraMutex.Dispose()
    exit 0
}

function Invoke-CuraLimpar {
    # "limpar SketchUp": esvazia o Plugins/ de TODA versão encontrada,
    # preservando só o que começa com cura_. NUNCA apaga — MOVE pra uma pasta
    # de recuperação em Documentos, porque aqui a gente mexe em plugin pago de
    # terceiro (TT_Lib2 é dependência de Solid Inspector², Vertex Tools,
    # QuadFace Tools).
    # ponytail: sem seleção item-a-item, e o -MinVersion 0 é de propósito —
    # limpeza tem que pegar todas as versões, inclusive as que o instalador
    # pula. Se um dia precisar de escolha por plugin, vira UI no próprio plugin.
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [switch]$Force
    )

    $destinoBase = Join-Path ([Environment]::GetFolderPath('MyDocuments')) `
        ("cura-plugins-removidos\" + (Get-Date -Format "yyyy-MM-dd-HHmm"))

    $achados = @()
    foreach ($v in @(Get-CuraSketchUpVersions -MinVersion 0)) {
        if (-not (Test-Path -LiteralPath $v.PluginsPath)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $v.PluginsPath -Force -ErrorAction SilentlyContinue) {
            # su_* são os plugins que a própria Trimble instala aqui
            # (su_sandbox = Sandbox Tools, su_dynamiccomponents, su_solarnorth).
            # Mover isso tira ferramenta nativa do SketchUp do aluno.
            if ($item.Name -like 'cura_*' -or $item.Name -like 'su_*') { continue }
            # lixo do Explorer que o -Force traz junto: não é plugin, não
            # entra na contagem (o mac já ignora o equivalente, .DS_Store).
            if ($item.Name -in @('desktop.ini', 'Thumbs.db')) { continue }
            $achados += [PSCustomObject]@{ Year = $v.Year; Path = $item.FullName; Name = $item.Name }
        }
    }

    if ($achados.Count -eq 0) {
        Write-Host "nada pra limpar: só o cura está instalado."
        return
    }

    Write-Host ""
    Write-Host "vão sair do SketchUp $($achados.Count) itens:"
    foreach ($a in $achados) { Write-Host "  SketchUp $($a.Year)  ->  $($a.Name)" }
    Write-Host ""
    Write-Host "eles NÃO serão apagados. vão pra:"
    Write-Host "  $destinoBase"
    Write-Host "o cura | ferramentas fica onde está."

    if (-not $Force) {
        $resp = Read-Host "confirma? [s/N]"
        if ($resp -notmatch '^(s|sim)$') {
            Write-Host "cancelado, nada foi movido."
            return
        }
    }

    $movidos = 0
    $falhas  = 0
    foreach ($a in $achados) {
        $destino = Join-Path $destinoBase ("SketchUp " + $a.Year)
        New-Item -ItemType Directory -Path $destino -Force | Out-Null
        # nome já ocupado no destino (duas limpezas no mesmo minuto, ou o mesmo
        # plugin em duas versões do SketchUp) ganha sufixo em vez de estourar o
        # Move-Item.
        $alvo = Join-Path $destino $a.Name
        $n = 2
        while (Test-Path -LiteralPath $alvo) {
            $alvo = Join-Path $destino ($a.Name + "-" + $n)
            $n++
        }
        try {
            Move-Item -LiteralPath $a.Path -Destination $alvo -Force
            Write-CuraLog -LogPath $LogPath -Message "limpeza: movido $($a.Path)"
            $movidos++
        } catch {
            # Move-Item de PASTA não atravessa volume ("must have identical
            # roots") - acontece de verdade com Documentos redirecionado pro D:
            # ou pra um servidor. Copia e só então apaga a origem: se a cópia
            # falhar, a origem fica intacta.
            try {
                Copy-Item -LiteralPath $a.Path -Destination $alvo -Recurse -Force
                Remove-Item -LiteralPath $a.Path -Recurse -Force
                Write-CuraLog -LogPath $LogPath -Message "limpeza: movido (cópia + remoção, volumes diferentes) $($a.Path)"
                $movidos++
            } catch {
                Write-CuraLog -LogPath $LogPath -Message "limpeza: não consegui mover $($a.Name) - $($_.Exception.Message)" -IsError
                Write-Host "não consegui mover $($a.Name) — pulei."
                $falhas++
            }
        }
    }

    $itemWord = if ($movidos -eq 1) { "item movido" } else { "itens movidos" }
    Write-Host ""
    if ($falhas -gt 0) {
        Write-Host "$movidos $itemWord, $falhas não saíram (veja o log)."
    } else {
        Write-Host "pronto. $movidos $itemWord."
    }
    Write-Host "tudo que saiu está em:"
    Write-Host "  $destinoBase"
    Write-Host "arrependeu? é só arrastar de volta pra pasta Plugins."
    Write-Host "abra o SketchUp pra conferir."
}

try {
    if ($Limpar) {
        if ($Quiet) {
            Write-CuraLog -LogPath $LogPath -Message "-Limpar não roda em modo silencioso: exige confirmação." -IsError
            exit 2
        }
        # mexer em Plugins/ com o SketchUp aberto deixa a limpeza pela metade:
        # plugin com binário nativo carregado (.so/.dll) trava o Move-Item, e o
        # programa ainda reescreve arquivo lá ao fechar. A limpeza é sempre
        # interativa, então o modo interativo do Wait é o certo aqui.
        Wait-CuraSketchUpClosed -LogPath $LogPath
        # sem -Force: a confirmação da limpeza é sempre pedida (README e o
        # --limpar do mac não têm escape).
        Invoke-CuraLimpar -LogPath $LogPath
        exit 0
    }

    if ($Uninstall) {
        Invoke-CuraUninstall -SnapshotPath $SnapshotPath -LogPath $LogPath -Force:$Force
    }

    # --- 2. SketchUp aberto? ---
    # Quiet (auto-update): não trocar arquivo embaixo do programa rodando. Se
    # estiver aberto, adia pro próximo gatilho (exit 0, sem alarde).
    # Interativo: pede pra fechar (não mata o processo).
    Wait-CuraSketchUpClosed -LogPath $LogPath -Quiet:$Quiet

    $TempDir = Join-Path $env:TEMP ("cura-biblioteca-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    try {
        # --- 3. Baixa manifest.json ---
        $manifestPath = Join-Path $TempDir "manifest.json"
        $ok = Get-CuraAsset -BaseUrl $BaseUrl -FileName "manifest.json" -OutFile $manifestPath -LogPath $LogPath
        if (-not $ok) {
            Write-CuraLog -LogPath $LogPath -Message "erro / não foi possível baixar manifest.json. sem internet ou GitHub inacessível." -IsError
            # registra o auto-update mesmo sem manifest: a máquina que pegou a
            # internet fora se conserta sozinha no próximo logon, sem depender
            # de o aluno rodar o Setup.exe de novo. A função é tolerante a
            # falha e idempotente.
            Register-CuraUpdater -TaskName $script:UpdaterTaskName -OfficialBaseUrl $script:OfficialBaseUrl -LogPath $LogPath
            Write-Host ""
            Write-Host "log completo em: $LogPath"
            exit 2
        }
        $manifestRaw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
        $manifest = $manifestRaw | ConvertFrom-Json

        $oldSnapshot = Get-CuraOldSnapshot -SnapshotPath $SnapshotPath
        $hadErrors = $false

        # --- 4/5. Detecta versões do SketchUp ---
        # @() força array mesmo quando exatamente 1 versão é detectada (o
        # PowerShell 5.1 "desembrulha" coleção de 1 elemento no retorno de
        # função, o que quebraria .Count mais abaixo).
        $allVersions = @(Get-CuraSketchUpVersions -MinVersion 0)
        $versions = @($allVersions | Where-Object { $_.Year -ge $manifest.min_sketchup })
        # versões antigas demais pro release atual: não recebem plugin, mas
        # precisam aparecer na mensagem final - senão o aluno cujo único
        # SketchUp é o 2017 lê "SketchUp não encontrado", que é falso.
        $belowMin = @($allVersions | Where-Object { $_.Year -lt $manifest.min_sketchup })
        $noSketchUpFound = ($versions.Count -eq 0)

        # --- No-op: nada mudou desde a última instalação? pula tudo. Mantém o
        # auto-update diário/logon barato e não fica re-extraindo plugin à toa
        # (re-churn de arquivo reindexaria o SketchUp sem motivo). ---
        if (Test-CuraUpToDate -Manifest $manifest -OldSnapshot $oldSnapshot -DetectedVersions $versions) {
            Write-CuraLog -LogPath $LogPath -Message "no-op: biblioteca já na versão $($manifest.biblioteca_version)."
            # self-cura: garante que a tarefa agendada existe/está com a
            # definição mais recente mesmo quando não há nada pra
            # (re)instalar - interativo OU -Quiet (idempotente via
            # Register-ScheduledTask -Force). Sem isso, o wrapper do updater
            # nunca se atualiza sozinho: a tarefa roda sempre -Quiet, então
            # só o ramo -not $Quiet nunca bastava.
            Register-CuraUpdater -TaskName $script:UpdaterTaskName -OfficialBaseUrl $script:OfficialBaseUrl -LogPath $LogPath
            if (-not $Quiet) {
                Write-Host ""
                Write-Host "biblioteca já está atualizada (v$($manifest.biblioteca_version)). nada a fazer."
                Write-Host "log: $LogPath"
            }
            exit 0
        }

        $snapshotVersions = @()

        if ($noSketchUpFound) {
            Write-CuraLog -LogPath $LogPath -Message "aviso: nenhuma instalação do SketchUp (>= $($manifest.min_sketchup)) foi encontrada. instalando somente as fontes; instale o SketchUp e rode este instalador de novo para os plugins."
        } else {
            # --- 7a. Baixa e verifica cada payload de plugin uma única vez ---
            $verifiedPlugins = @()
            foreach ($plugin in $manifest.plugins) {
                $destFile = Join-Path $TempDir $plugin.file
                $ok = Get-CuraPluginPayload -Plugin $plugin -BaseUrl $BaseUrl -OutFile $destFile -LogPath $LogPath
                if (-not $ok) {
                    Write-CuraLog -LogPath $LogPath -Message "erro / falha ao baixar $($plugin.name) ($($plugin.file)). este item não será instalado." -IsError
                    $hadErrors = $true
                    continue
                }
                $hash = (Get-FileHash -LiteralPath $destFile -Algorithm SHA256).Hash
                if ($hash.ToLower() -ne $plugin.sha256.ToLower()) {
                    Write-CuraLog -LogPath $LogPath -Message "erro / sha256 não confere para $($plugin.file) (esperado $($plugin.sha256), obtido $hash). download corrompido, item não será instalado." -IsError
                    $hadErrors = $true
                    continue
                }
                # Expand-Archive só aceita .zip - copia o .rbz pra .zip antes
                $zipPath = Join-Path $TempDir ([System.IO.Path]::GetFileNameWithoutExtension($plugin.file) + ".zip")
                Copy-Item -LiteralPath $destFile -Destination $zipPath -Force
                $verifiedPlugins += [PSCustomObject]@{ Plugin = $plugin; ZipPath = $zipPath }
                Write-CuraLog -LogPath $LogPath -Message "payload verificado: $($plugin.name) v$($plugin.version) (sha256 ok)"
            }

            # --- 6. Re-checa SketchUp antes da 1ª remoção/Expand-Archive: o
            # download+verificação acima pode ter levado minutos, e o
            # processo pode ter sido aberto nesse meio tempo. ---
            Wait-CuraSketchUpClosed -LogPath $LogPath -Quiet:$Quiet

            # --- 6/7b. Por versão: limpeza (remove list + roots antigos/atuais) e instalação ---
            foreach ($ver in $versions) {
                if (-not (Test-Path -LiteralPath $ver.PluginsPath)) {
                    New-Item -ItemType Directory -Path $ver.PluginsPath -Force | Out-Null
                }

                # Lista `remove` (plugins mortos) é incondicional - independe
                # de $verifiedPlugins.
                foreach ($name in $manifest.remove) {
                    Remove-CuraExact -ParentDir $ver.PluginsPath -Name $name -LogPath $LogPath
                }

                $installedPluginsForVersion = @()
                foreach ($vp in $verifiedPlugins) {
                    # Só limpa os roots (snapshot antigo + manifest atual)
                    # DESTE plugin, e só porque ele passou na verificação de
                    # sha256 - imediatamente antes do Expand-Archive dele.
                    # Plugin que falhou a verificação nunca chega aqui (não
                    # está em $verifiedPlugins) e mantém a cópia antiga
                    # intacta no disco.
                    $pluginRootsToClean = @()
                    if (($null -ne $oldSnapshot) -and ($null -ne $oldSnapshot.sketchup_versions)) {
                        foreach ($oldVer in $oldSnapshot.sketchup_versions) {
                            if ($oldVer.year -eq $ver.Year) {
                                foreach ($p in $oldVer.plugins) {
                                    if ($p.id -eq $vp.Plugin.id) {
                                        foreach ($r in $p.roots) { $pluginRootsToClean += $r }
                                    }
                                }
                            }
                        }
                    }
                    foreach ($r in $vp.Plugin.roots) { $pluginRootsToClean += $r }
                    $pluginRootsToClean = $pluginRootsToClean | Select-Object -Unique
                    foreach ($name in $pluginRootsToClean) {
                        Remove-CuraExact -ParentDir $ver.PluginsPath -Name $name -LogPath $LogPath
                    }

                    try {
                        Expand-Archive -LiteralPath $vp.ZipPath -DestinationPath $ver.PluginsPath -Force
                        Write-CuraLog -LogPath $LogPath -Message "instalado $($vp.Plugin.name) v$($vp.Plugin.version) em SketchUp $($ver.Year)"
                        $installedPluginsForVersion += [PSCustomObject]@{
                            id      = $vp.Plugin.id
                            name    = $vp.Plugin.name
                            version = $vp.Plugin.version
                            roots   = $vp.Plugin.roots
                        }
                    } catch {
                        Write-CuraLog -LogPath $LogPath -Message "erro / falha ao extrair $($vp.Plugin.name) em SketchUp $($ver.Year): $($_.Exception.Message)" -IsError
                        $hadErrors = $true
                    }
                }

                $snapshotVersions += [PSCustomObject]@{
                    year         = $ver.Year
                    plugins_path = $ver.PluginsPath
                    plugins      = $installedPluginsForVersion
                }
            }
        }

        # --- 8. Fontes (independe de ter SketchUp encontrado ou não) ---
        $installedFonts = @()
        if ($null -ne $manifest.fonts) {
            $fontsZipDest = Join-Path $TempDir $manifest.fonts.file
            $ok = Get-CuraAsset -BaseUrl $BaseUrl -FileName $manifest.fonts.file -OutFile $fontsZipDest -LogPath $LogPath
            if (-not $ok) {
                Write-CuraLog -LogPath $LogPath -Message "erro / falha ao baixar fontes ($($manifest.fonts.file)). fontes não serão instaladas." -IsError
                $hadErrors = $true
            } else {
                $fontsHash = (Get-FileHash -LiteralPath $fontsZipDest -Algorithm SHA256).Hash
                if ($fontsHash.ToLower() -ne $manifest.fonts.sha256.ToLower()) {
                    Write-CuraLog -LogPath $LogPath -Message "erro / sha256 não confere para $($manifest.fonts.file). fontes não serão instaladas." -IsError
                    $hadErrors = $true
                } else {
                    # Passo inteiro dentro de try/catch: descompactar, criar o
                    # dir de fontes do perfil e a chave do registro são passos
                    # arriscados (ACL, redirecionamento, disco cheio) e uma
                    # exceção aqui subiria pro catch global - que faz exit 2
                    # ANTES de gravar o snapshot e de registrar o auto-update,
                    # deixando plugin em disco sem installed.json. Mesma
                    # maquinaria de $hadErrors já usada nos plugins: falha de
                    # fonte vira "fica pra próxima rodada".
                    try {
                        $fontsZipRenamed = Join-Path $TempDir "fonts-payload.zip"
                        Copy-Item -LiteralPath $fontsZipDest -Destination $fontsZipRenamed -Force
                        $fontsExtractDir = Join-Path $TempDir "fonts-extract"
                        New-Item -ItemType Directory -Path $fontsExtractDir -Force | Out-Null
                        # ZipFile em vez de Expand-Archive: a maioria dos
                        # arquivos tem colchete no nome (Inter[opsz,wght].ttf,
                        # convenção das Google Fonts variáveis) e o
                        # Expand-Archive do PS 5.1 trata colchete como wildcard
                        # em alguns caminhos internos. A API .NET não tem
                        # semântica de glob nenhuma.
                        Add-Type -AssemblyName System.IO.Compression.FileSystem
                        [System.IO.Compression.ZipFile]::ExtractToDirectory($fontsZipRenamed, $fontsExtractDir)

                        $winFontsDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
                        New-Item -ItemType Directory -Path $winFontsDir -Force | Out-Null

                        # A chave de fontes per-user NÃO existe num perfil que
                        # nunca instalou fonte (PC recém-formatado): ela nasce
                        # junto com o diretório acima, no primeiro uso.
                        # New-ItemProperty cria VALOR, não cria a chave. Test-Path
                        # antes do New-Item pra nunca mexer numa chave que já
                        # tem as fontes do aluno dentro.
                        $fontsKeyOk = $true
                        if (-not (Test-Path -LiteralPath $script:FontsRegKey)) {
                            try {
                                New-Item -Path $script:FontsRegKey -Force | Out-Null
                            } catch {
                                Write-CuraLog -LogPath $LogPath -Message "erro / não consegui criar a chave de fontes do usuário: $($_.Exception.Message). fontes não serão registradas." -IsError
                                $hadErrors = $true
                                $fontsKeyOk = $false
                            }
                        }

                        # O nome do VALOR no registro é o que o Windows mostra na
                        # lista de fontes. Pra .ttc ele precisa listar TODAS as
                        # faces da coleção separadas por " & ", senão só a primeira
                        # aparece no Photoshop/InDesign/Illustrator. Esses nomes são
                        # gerados junto com o fonts.zip (tools/make_fonts.py) e vêm
                        # em names.json — aqui não dá pra ler a name table sem
                        # dependência externa.
                        $regNames = @{}
                        $namesJson = Join-Path $fontsExtractDir "names.json"
                        if (Test-Path -LiteralPath $namesJson) {
                            try {
                                $parsed = Get-Content -LiteralPath $namesJson -Raw -Encoding UTF8 | ConvertFrom-Json
                                foreach ($p in $parsed.PSObject.Properties) { $regNames[$p.Name] = $p.Value }
                            } catch {
                                Write-CuraLog -LogPath $LogPath -Message "names.json ilegível, caindo no nome do arquivo: $($_.Exception.Message)"
                            }
                        }

                        # Copiar o arquivo e gravar o registro PERSISTE a fonte,
                        # mas quem publica a lista na sessão em curso é o logon.
                        # AddFontResourceW + broadcast de WM_FONTCHANGE fazem as
                        # fontes aparecerem sem reiniciar o computador.
                        # Best-effort: se o Add-Type falhar, segue sem isso.
                        $script:FontApiOk = $false
                        try {
                            if (-not ('Cura.FontApi' -as [type])) {
                                Add-Type -Namespace Cura -Name FontApi -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
public static extern int AddFontResourceW(string path);
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
'@
                            }
                            $script:FontApiOk = $true
                        } catch {
                            Write-CuraLog -LogPath $LogPath -Message "aviso: não deu pra carregar a api de fontes do Windows ($($_.Exception.Message)) - as fontes só aparecem depois de logoff e login."
                        }

                        if ($fontsKeyOk) {
                            $fontFiles = Get-ChildItem -LiteralPath $fontsExtractDir -Recurse -File | Where-Object {
                                $_.Extension -match '^\.(ttf|otf|ttc)$'
                            }
                            foreach ($f in $fontFiles) {
                                # coleção sem nome pronto no names.json não pode
                                # ser instalada: o nome do registro teria que
                                # listar todas as faces separadas por " & " e
                                # aqui não dá pra ler a name table. Registrada
                                # pelo nome do arquivo, só a 1ª face apareceria
                                # nos programas e o aluno teria que desinstalar
                                # na mão - fonte que fica pra próxima rodada é
                                # o estrago menor.
                                if ((-not $regNames.ContainsKey($f.Name)) -and ($f.Extension -ieq '.ttc')) {
                                    Write-CuraLog -LogPath $LogPath -Message "erro / sem nome de registro para $($f.Name) - coleção não instalada (só a 1ª face apareceria nos programas)." -IsError
                                    $hadErrors = $true
                                    continue
                                }
                                try {
                                    if ($regNames.ContainsKey($f.Name)) {
                                        $regName = $regNames[$f.Name]
                                    } else {
                                        # (TrueType) vale pra .ttf e pra .ttc com
                                        # outlines glyf; (OpenType) é só pra CFF (.otf).
                                        $sufixo = if ($f.Extension -ieq '.otf') { '(OpenType)' } else { '(TrueType)' }
                                        $regName = "$([System.IO.Path]::GetFileNameWithoutExtension($f.Name)) $sufixo"
                                    }
                                    $destFontPath = Join-Path $winFontsDir $f.Name
                                    Copy-Item -LiteralPath $f.FullName -Destination $destFontPath -Force
                                    New-ItemProperty -Path $script:FontsRegKey -Name $regName -Value $destFontPath -PropertyType String -Force | Out-Null
                                    if ($script:FontApiOk) {
                                        [Cura.FontApi]::AddFontResourceW($destFontPath) | Out-Null
                                    }
                                    Write-CuraLog -LogPath $LogPath -Message "fonte instalada: $($f.Name)"
                                    $installedFonts += [PSCustomObject]@{ file = $destFontPath; reg_name = $regName }
                                } catch {
                                    # arquivo já instalado e travado por outro app
                                    # (Photoshop/InDesign aberto), antivírus, ACL.
                                    # Não apagar o destino no catch: pode ser fonte
                                    # do próprio aluno. Com $hadErrors a rodada
                                    # grava a version antiga e o updater retenta.
                                    Write-CuraLog -LogPath $LogPath -Message "erro / falha ao instalar a fonte $($f.Name) (arquivo em uso por outro app?): $($_.Exception.Message)" -IsError
                                    $hadErrors = $true
                                }
                            }

                            if ($script:FontApiOk -and $installedFonts.Count -gt 0) {
                                try {
                                    # HWND_BROADCAST (0xffff) / WM_FONTCHANGE (0x1d),
                                    # SMTO_ABORTIFHUNG + 1s pra não travar atrás de
                                    # programa pendurado.
                                    $fontMsgResult = [IntPtr]::Zero
                                    [Cura.FontApi]::SendMessageTimeout([IntPtr]0xffff, 0x1d, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$fontMsgResult) | Out-Null
                                } catch {
                                    Write-CuraLog -LogPath $LogPath -Message "aviso: não deu pra avisar os programas abertos sobre as fontes novas: $($_.Exception.Message)"
                                }
                            }
                        }
                    } catch {
                        Write-CuraLog -LogPath $LogPath -Message "erro / falha ao preparar/instalar as fontes: $($_.Exception.Message)" -IsError
                        $hadErrors = $true
                    }
                }
            }
        } else {
            Write-CuraLog -LogPath $LogPath -Message "manifest ainda sem fontes definidas - etapa pulada."
        }

        # --- 8b. Fonte que saiu do payload: tira do disco e do registro. Sem
        # isso, fonte removida num release futuro ficaria pra sempre no
        # Photoshop do aluno E sumiria do snapshot (o -Uninstall nunca mais a
        # encontraria). Só roda em rodada limpa: com $hadErrors, o que está no
        # disco pode ser justamente o que não conseguiu ser reinstalado agora.
        # Mesma whitelist de prefixo do Invoke-CuraUninstall. ---
        if ((-not $hadErrors) -and ($null -ne $manifest.fonts) -and ($null -ne $oldSnapshot) -and ($null -ne $oldSnapshot.fonts)) {
            $arquivosNovos = @($installedFonts | ForEach-Object { $_.file })
            $fontsDirEsperado = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"))
            foreach ($old in $oldSnapshot.fonts) {
                if ($arquivosNovos -contains $old.file) { continue }
                $dentroDoEsperado = $false
                try {
                    $dentroDoEsperado = ([System.IO.Path]::GetFullPath($old.file)).StartsWith($fontsDirEsperado, [StringComparison]::OrdinalIgnoreCase)
                } catch {
                    $dentroDoEsperado = $false
                }
                if (-not $dentroDoEsperado) {
                    Write-CuraLog -LogPath $LogPath -Message "aviso: caminho de fonte fora do diretório esperado, ignorado: $($old.file)"
                    continue
                }
                if (Test-Path -LiteralPath $old.file) {
                    Remove-Item -LiteralPath $old.file -Force -ErrorAction SilentlyContinue
                }
                if (-not [string]::IsNullOrEmpty($old.reg_name)) {
                    Remove-ItemProperty -Path $script:FontsRegKey -Name $old.reg_name -ErrorAction SilentlyContinue
                }
                Write-CuraLog -LogPath $LogPath -Message "fonte obsoleta removida: $($old.file)"
            }
        }

        # --- 8c. Versão do SketchUp antiga demais pro min_sketchup atual: o
        # plugin que um release anterior instalou nela continua lá e continua
        # funcionando. Carrega a entrada do snapshot antigo pra frente (só o
        # que ainda existe em disco) em vez de deixar sumir - senão o
        # -Uninstall nunca mais acharia essa cópia e a desinstalação viraria
        # incompleta e silenciosa. Nunca apagar por conta própria: quem
        # instalou não pediu pra perder a ferramenta, e o updater roda em
        # silêncio. ---
        $mantidosAbaixoDoMinimo = @()
        if (($null -ne $oldSnapshot) -and ($null -ne $oldSnapshot.sketchup_versions)) {
            foreach ($oldVer in $oldSnapshot.sketchup_versions) {
                if ($versions.Year -contains $oldVer.year) { continue }
                if ([string]::IsNullOrEmpty($oldVer.plugins_path)) { continue }
                $aindaEmDisco = @()
                foreach ($p in $oldVer.plugins) {
                    $presente = $true
                    foreach ($r in $p.roots) {
                        if (-not (Test-Path -LiteralPath (Join-Path $oldVer.plugins_path $r))) { $presente = $false }
                    }
                    if ($presente) { $aindaEmDisco += $p }
                }
                if ($aindaEmDisco.Count -gt 0) {
                    $snapshotVersions += [PSCustomObject]@{
                        year         = $oldVer.year
                        plugins_path = $oldVer.plugins_path
                        plugins      = $aindaEmDisco
                    }
                    $mantidosAbaixoDoMinimo += $oldVer.year
                    Write-CuraLog -LogPath $LogPath -Message "mantido no snapshot sem update (SketchUp $($oldVer.year) < min_sketchup $($manifest.min_sketchup)): $($oldVer.plugins_path)"
                }
            }
        }

        # --- 9. Snapshot (para desinstalação futura) ---
        # Se algum item falhou (sha256/download/extração), grava a
        # biblioteca_version ANTIGA em vez da nova - senão a próxima rodada
        # do updater vê a version nova já batendo no snapshot e cai no no-op
        # (Test-CuraUpToDate), nunca mais retentando o item que faltou. Os
        # itens que instalaram com sucesso já ficam registrados normalmente
        # em $snapshotVersions/$installedFonts.
        $snapshotBibliotecaVersion = $manifest.biblioteca_version
        if ($hadErrors) {
            if ($null -ne $oldSnapshot) {
                $snapshotBibliotecaVersion = $oldSnapshot.biblioteca_version
            } else {
                $snapshotBibliotecaVersion = ""
            }
        }
        $snapshot = [PSCustomObject]@{
            biblioteca_version = $snapshotBibliotecaVersion
            installed_at       = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
            sketchup_versions  = $snapshotVersions
            fonts              = $installedFonts
        }
        # Escrita atômica: grava num .tmp e só substitui o snapshot real com
        # Move-Item -Force por cima - evita installed.json meio escrito se o
        # processo for interrompido no meio do Set-Content (queda de energia,
        # kill da tarefa por timeout, etc).
        $snapshotTmpPath = "$SnapshotPath.tmp"
        $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $snapshotTmpPath -Encoding UTF8
        Move-Item -LiteralPath $snapshotTmpPath -Destination $SnapshotPath -Force

        # --- 10. Auto-update: (re)registra a tarefa agendada sempre que uma
        # rodada chega até aqui - interativa OU -Quiet. Register-ScheduledTask
        # -Force é idempotente e atualiza a DEFINIÇÃO da tarefa (a instância
        # que está rodando agora, se for essa mesma tarefa, segue até o fim
        # normalmente); assim uma mudança futura no wrapper do updater
        # (Register-CuraUpdater) se propaga sozinha pro parque instalado, sem
        # depender de reinstalação manual.
        Register-CuraUpdater -TaskName $script:UpdaterTaskName -OfficialBaseUrl $script:OfficialBaseUrl -LogPath $LogPath

        # --- 11. Resumo final (voz cura: minúsculo, sem emoji, tag "ok /" só no
        # sucesso limpo - mesmo critério do install.sh: 1 = só "sem SketchUp",
        # 2 = qualquer falha de integridade/download, mesmo com SketchUp achado) ---
        Write-Host ""
        $fonteNoun  = if ($installedFonts.Count -eq 1) { "fonte" } else { "fontes" }
        $fonteVerbo = if ($installedFonts.Count -eq 1) { "instalada" } else { "instaladas" }
        if ($noSketchUpFound) {
            # 1 = não tem SketchUp nenhum; 3 = tem, mas é anterior ao
            # min_sketchup. Códigos diferentes porque o installer.iss escreve a
            # tela final a partir daqui: com 1 ele manda "instale o SketchUp",
            # frase falsa (e ticket de suporte na certa) pra quem tem o 2017.
            $exitSemSketchUp = 1
            if ($belowMin.Count -gt 0) {
                # tem SketchUp sim, só é anterior ao min_sketchup deste release.
                # Dizer "não encontrado" aqui é falso e vira ticket de suporte.
                $exitSemSketchUp = 3
                $anosAntigos = (($belowMin | ForEach-Object { $_.Year } | Sort-Object) -join ", ")
                Write-Host "o cura | ferramentas pede SketchUp $($manifest.min_sketchup) ou mais novo. neste computador encontrei só o SketchUp $anosAntigos."
                if ($installedFonts.Count -gt 0) {
                    Write-Host "as fontes foram instaladas normalmente."
                }
            } else {
                if ($installedFonts.Count -gt 0) {
                    Write-Host "SketchUp não encontrado neste computador. $($installedFonts.Count) $fonteNoun $fonteVerbo."
                } else {
                    Write-Host "SketchUp não encontrado neste computador."
                }
                Write-Host "instale o SketchUp e rode este instalador novamente para concluir a instalação dos plugins."
            }
            Write-Host "log: $LogPath"
            exit $exitSemSketchUp
        }

        # Só o que passou na verificação de sha256 entra no resumo: montar a
        # lista a partir de $manifest.plugins faria o instalador afirmar que
        # instalou justamente o item que o download corrompeu.
        $pluginSummaryParts = @()
        foreach ($vp in $verifiedPlugins) {
            $pluginSummaryParts += "$($vp.Plugin.name) v$($vp.Plugin.version)"
        }
        $verWord = if ($versions.Count -eq 1) { "versão" } else { "versões" }
        $versionsList = ($versions | ForEach-Object { $_.Year }) -join ", "
        if ($pluginSummaryParts.Count -eq 0) {
            $msg = "nenhum plugin instalado (falha de integridade) em $($versions.Count) $verWord do SketchUp ($versionsList); $($installedFonts.Count) $fonteNoun."
        } else {
            $pluginSummary = $pluginSummaryParts -join ", "
            $msg = "instalado: $pluginSummary em $($versions.Count) $verWord do SketchUp ($versionsList); $($installedFonts.Count) $fonteNoun."
        }

        if ($hadErrors) {
            Write-Host $msg
            Write-Host "algum item falhou (download, integridade ou fonte em uso) - veja o log para detalhes."
            Write-Host "log: $LogPath"
            exit 2
        }

        Write-Host "ok / $msg"
        Write-Host "abra o SketchUp > extensões pra conferir."
        if ($installedFonts.Count -gt 0) {
            Write-Host "se alguma fonte não aparecer no seu programa, feche e abra o programa (ou faça logoff e login)."
        }
        if ($mantidosAbaixoDoMinimo.Count -gt 0) {
            Write-Host "o cura | ferramentas continua instalado no seu SketchUp $($mantidosAbaixoDoMinimo -join ', '), mas não recebe mais atualização - a partir desta versão pedimos o $($manifest.min_sketchup). pra tirar, use o desinstalador."
        }
        # aviso de beta - remover quando a biblioteca sair do beta (ver README).
        Write-Host "esta é uma versão beta: seguimos testando e corrigindo. se algo falhar, mande o log pro suporte."
        Write-Host "log: $LogPath"
        exit 0
    } finally {
        if (Test-Path -LiteralPath $TempDir) {
            Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-CuraLog -LogPath $LogPath -Message "erro / erro inesperado: $($_.Exception.Message)" -IsError
    Write-Host ""
    Write-Host "log completo em: $LogPath"
    exit 2
} finally {
    if ($script:CuraMutexOwned) {
        $script:CuraMutex.ReleaseMutex()
    }
    $script:CuraMutex.Dispose()
}
# cura-eof
