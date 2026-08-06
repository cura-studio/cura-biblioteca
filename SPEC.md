# SPEC — Instalador Biblioteca CURA 9.2 (caveman PT-BR, doc interno)

Instalador "eterno" 2 plataformas. Bootstrapper fino: conteúdo + lógica baixados em runtime de GitHub Releases. Rebuild de instalador ≈ nunca.

## Arquitetura

```
Aluno
 ├─ Windows: BibliotecaCURA-Setup.exe (Inno, per-user, sem admin)
 │    └─ baixa scripts/install.ps1 (latest) → executa
 └─ Mac: 1 linha Terminal: /bin/bash -c "$(curl -fsSL <RAW_SH_URL>)"
      └─ install.sh baixa manifest → executa

GitHub repo joaotegoni/cura-biblioteca (público)
 └─ Release "latest" assets:
    manifest.json, cura-ferramentas.rbz, fonts.zip, install.ps1, install.sh, BibliotecaCURA-Setup.exe
```

URLs canônicas:
- BASE = `https://github.com/joaotegoni/cura-biblioteca/releases/latest/download`
- RAW_SH_URL = `https://raw.githubusercontent.com/joaotegoni/cura-biblioteca/main/scripts/install.sh`
- Override p/ teste local: env `CURA_BASE_URL` (aceita `file:///...` ou dir local). Ambos scripts respeitam.

## manifest.json (schema 1)

```json
{
  "schema": 1,
  "biblioteca_version": "9.2.0",
  "min_sketchup": 2018,
  "plugins": [
    {
      "id": "cura-ferramentas",
      "name": "cura | ferramentas",
      "version": "1.0.0",
      "file": "cura-ferramentas.rbz",
      "url": null,
      "sha256": "<calculado por tools/make_manifest.py>",
      "roots": ["cura_ferramentas", "cura_ferramentas.rb"]
    }
  ],
  "fonts": { "file": "fonts.zip", "url": null, "sha256": "<idem>" },
  "remove": []
}
```

Regras:
- `url: null` → download de `BASE/<file>`. URL absoluta → usa ela (futuro: endpoint autenticado assinatura — NÃO implementar auth agora, só suportar URL absoluta). Implementado só em `plugins[]` (install.sh `fetch_absolute_url`, install.ps1 `Get-CuraRemoteFile`). Em `fonts` o campo existe no schema mas é RESERVADO: nenhum dos dois instaladores lê — fonts.zip sempre vem do asset da release.
- `biblioteca_version` = versão da biblioteca inteira e ÚNICO critério de no-op do auto-update (install.sh e `Test-CuraUpToDate` no ps1 saem sem fazer nada se ela não mudou). Manual, e tem que casar com a tag sem o `v` — o CI recusa a release se divergir.
- `plugins[].version` = a constante `VERSION` de dentro do .rbz; é o que o updater in-plugin compara pra decidir o banner de atualização. Manual, conferido por `make_manifest.py` contra o zip.
- `roots` = entradas raiz que o .rbz cria em Plugins/ → snapshot de desinstalação + limpeza de versão velha do próprio plugin antes de instalar. Conferido por `make_manifest.py` contra o zip.
- `fonts: null` → pula fontes SEM erro. Hoje as fontes existem: `payload/fonts.zip` é gerado por `tools/make_fonts.py` (allowlist das 5 clássicas + `--google` inteiro) e traz um `names.json` com o nome de registro de cada arquivo pro Windows.
- `remove` = SÓ match exato de nome (arquivo ou pasta) dentro de cada `Plugins/`. NUNCA glob/wildcard. Hoje VAZIA: a lista das TT_* saiu porque tirava dependência de plugin pago do aluno (TT_Lib2 sustenta Solid Inspector², Vertex Tools, QuadFace Tools) numa execução silenciosa do auto-update. Nome novo aqui só entra com o mesmo cuidado do "limpar sketchup": o que sai do `Plugins/` vai pro porão de recuperação (`Documentos/cura-plugins-removidos/<data-hora>/SketchUp <ano>/`), nunca é apagado.
- REGRA OPERACIONAL: renomeou um root de plugin, ou tirou um plugin do manifest? o nome ANTIGO entra na lista `remove` no MESMO release. A limpeza de upgrade só remove roots do plugin que vai ser reinstalado com sucesso (proteção contra download corrompido apagar cópia boa), então root antigo órfão só sai do disco via `remove`.
- sha256 SEMPRE verificado pós-download. Falhou → aborta item com msg clara, não instala corrompido.

## Fluxo de instalação (idêntico nas 2 plataformas)

1. Banner PT-BR ("Biblioteca CURA — instalador").
2. SketchUp aberto? (proc `SketchUp*`) → pede fechar e confirmar (Enter/retry). Não mata processo.
3. Baixa manifest (retry 3×, timeout 30s). Falha → msg "sem internet ou GitHub inacessível" + path do log, exit 2.
4. Detecta versões: glob dir `SketchUp 20*`; extrai ano; filtra `>= min_sketchup`. Cria subpasta `Plugins` se faltar (só quando dir da versão existe).
   - Win: `%APPDATA%\SketchUp\SketchUp 20XX\SketchUp\Plugins`
   - Mac: `~/Library/Application Support/SketchUp 20XX/SketchUp/Plugins`
5. Zero versão achada → aviso: "SketchUp não encontrado — instalando só as fontes; instale o SketchUp e rode este instalador de novo." Segue p/ fontes, exit 1.
6. Por versão: limpeza — remove itens da lista `remove` + `roots` de instalação anterior (upgrade limpo). Loga cada remoção.
7. Download payloads em dir temp (mktemp) → sha256 → unzip .rbz (rbz = zip) DENTRO de cada `Plugins/` (overwrite). Download 1×, instala N×.
8. Fontes (se manifest tiver): unzip fonts.zip; instala .ttf/.otf/.ttc per-user:
   - Mac: copia p/ `~/Library/Fonts/`
   - Win: copia p/ `%LOCALAPPDATA%\Microsoft\Windows\Fonts\` (criar dir) + registra valor em `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts`: nome = "<basename> (TrueType)", dado = path completo. Sem admin.
9. Snapshot JSON (p/ desinstalar): lista exata do que instalou (por versão SketchUp: paths dos roots; fontes: paths; versão biblioteca; data ISO).
   - Mac: `~/Library/Application Support/CURA-Biblioteca/installed.json`
   - Win: `%LOCALAPPDATA%\CURA-Biblioteca\installed.json`
10. Log completo (tudo que fez, timestamps): mesmo dir, `install.log` (append, header com data). Aluno manda esse arquivo pro suporte.
11. Resumo final PT-BR, sem emoji: "ok / instalado: cura | ferramentas v1.0.0 em N versões do SketchUp (2021, 2025); X fontes. log: <path>". Instrui abrir SketchUp > Extensões pra conferir.

Idempotente: re-rodar = conserto (limpa + reinstala). Exit codes: 0 ok, 1 parcial (sem SketchUp), 2 falha. Só no `install.ps1` existe também o **3** = tem SketchUp, mas todo ele é anterior ao `min_sketchup` (só as fontes foram instaladas): o `installer.iss` precisa desse código pra não escrever "SketchUp não encontrado, instale o SketchUp" na tela final de quem tem o 2017.

## Modos e auto-update

Além da instalação interativa, os dois scripts têm:
- `--quiet` / `-Quiet` — modo do auto-update agendado: sem prompt nenhum; SketchUp aberto ADIA (exit 0, sem alarde) em vez de esperar; no-op quando o snapshot já está na `biblioteca_version` do manifest e os arquivos estão no lugar.
- `--limpar` / `-Limpar` — "limpar SketchUp": move todo plugin de terceiro pro porão (`Documentos/cura-plugins-removidos/<data-hora>/SketchUp <ano>/`), preservando `cura_*` (nossos) e `su_*` (nativos Trimble: sandbox, dynamiccomponents, solarnorth). Nunca apaga, sempre pede confirmação, nunca roda em quiet.
- `--uninstall` / `-Uninstall` (+ `-Force` pro desinstalador do Inno).

O agendamento é registrado na instalação interativa: launchagent `com.cura.biblioteca.updater` (login + reserva diária) no mac, tarefa agendada (logon + diária) no Windows. Os dois puxam `install.sh`/`install.ps1` da release "latest" — a URL literal, nunca `CURA_BASE_URL`, pra teste local não sequestrar o updater da máquina. Lock per-user (dir `.lock` no mac, mutex nomeado no Windows) impede updater e execução manual de brigarem pelo mesmo `installed.json`.

Isso é uma camada. A outra é o updater DENTRO do plugin (`cura_ferramentas/core/updater.rb`): no boot, throttle de 24h, compara `plugins[0].version` do mesmo manifest com `CURA::Tools::VERSION`, e se for estritamente maior mostra banner com botão "atualizar" (baixa o .rbz, confere sha256, instala por `Sketchup.install_from_archive`). Fail-silent: rede é cortesia de fundo. Consequência de contrato: `plugins[].version` do manifest TEM que casar com a `VERSION` assada no .rbz, senão o banner ou nunca aparece ou nunca some.

## Desinstalação — "explicando cada um"

Modo `--uninstall` (sh) / `-Uninstall` (ps1): lê snapshot → imprime lista item a item (plugin X na versão Y, fonte Z) → confirma → remove SÓ o que está no snapshot → remove snapshot → resumo. Sem snapshot → msg "nada instalado por este instalador". Windows: exe Inno registra "Biblioteca CURA" em Adicionar/Remover; desinstalador chama o ps1 cacheado com -Uninstall (funciona offline → cachear install.ps1 em `%LOCALAPPDATA%\CURA-Biblioteca\` na instalação).

## Arquivos a produzir

### Efetor A (Mac + manifest)
- `scripts/install.sh` — bash **3.2-compatível** (macOS ships 3.2: SEM assoc array, SEM mapfile, SEM ${var,,}). `set -euo pipefail`. `mktemp -d` + `trap cleanup EXIT`. Paths SEMPRE quoted (espaços). curl `-fsSL --retry 3 --connect-timeout 30`. sha256: `shasum -a 256`. unzip: `unzip -oq`. Suporta `--uninstall`, `--quiet`, `--limpar` e `CURA_BASE_URL` (se começa com `/` ou `file://`, copia local em vez de curl). Confirmações: `read -r` de `/dev/tty` (script vem de pipe! stdin ocupado — OBRIGATÓRIO /dev/tty p/ prompts).
- `manifest.json` — como schema acima, sha256 real do payload/cura-ferramentas.rbz.
- `tools/make_manifest.py` — python3 stdlib puro (pathlib, hashlib, json, zipfile, re): recalcula sha256 de payload/* e reescreve só esse campo no manifest.json. Uso: CI e manutenção. Não bumpa versão nenhuma — versão é manual —, mas CONFERE, com erro fatal (SystemExit 1): `roots` e `plugins[].version` contra o conteúdo real do .rbz.
- `tools/make_fonts.py` — monta `payload/fonts.zip` (fontTools, dependência só de build): allowlist das 5 clássicas no argumento posicional, `--google <pasta>` entra inteiro; curadoria pela família da name table; família com 3+ arquivos vira `.ttc`, com 1 ou 2 fica como veio; gera `names.json` com o nome de registro de cada arquivo pro Windows.

### Efetor B (Windows + CI + docs)
- `scripts/install.ps1` — **PowerShell 5.1** (Win10 default; nada de sintaxe pwsh7). Início: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`. Download: `Invoke-WebRequest -UseBasicParsing`. Hash: `Get-FileHash -Algorithm SHA256`. **Expand-Archive exige extensão .zip** → copiar .rbz p/ temp como .zip antes. Param: `[switch]$Uninstall`, `[switch]$Force`, `[switch]$Quiet`, `[switch]$Limpar`, `$BaseUrl` (default BASE; aceita path local p/ teste, ou `CURA_BASE_URL`). Saída console PT-BR SEM acento quebrado: console 5.1 usa codepage legada → `[Console]::OutputEncoding = [Text.Encoding]::UTF8` no início e salvar .ps1 **UTF-8 com BOM** (5.1 lê BOM; sem BOM = mojibake).
- `windows/installer.iss` — Inno Setup 6. `PrivilegesRequired=lowest`, `Languages: BrazilianPortuguese` (compiler:Languages\BrazilianPortuguese.isl), AppId GUID fixo (gerar 1× e cravar), AppName "Biblioteca CURA", DefaultDirName `{localappdata}\CURA-Biblioteca` (só cache/log — plugins vão pro %APPDATA% do SketchUp via ps1). Embute SÓ `scripts/install.ps1` como fallback ([Files]). [Code]: no install, tenta baixar install.ps1 mais novo de BASE (ITD não — usar `WinHttp.WinHttpRequest.5.1` COM em Pascal ou simplesmente rodar powershell que baixa); falhou download → usa o embutido (offline-tolerante na lógica, payload sempre exige internet). Executa `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <cached>\install.ps1` visível (aluno vê progresso), captura exit code → mensagem final. [UninstallRun]: `powershell ... -File <cached>\install.ps1 -Uninstall -Confirm:$false` + Inno remove cache/log. Wizard mínimo: welcome → progress → finished (texto resumo + checkbox "ver log").
- `windows/cura.ico` — gerar via python3+PIL de `~/dev/cura-ferramentas/src/cura_ferramentas/core/assets/` (buscar cura-marca-*-512.png; se não achar, `find ~/dev/cura-ferramentas -name "*512*.png"`). Tamanhos 16/32/48/256 no .ico. PIL disponível no python3 local.
- `.github/workflows/release.yml` — trigger `push: tags: ['v*']`. Job 1 (ubuntu): roda `tools/make_manifest.py` (garante sha256 atual) + **gate de versão**, sobe artifacts. Job 2 (windows-latest): `choco install innosetup -y`, `iscc windows\installer.iss`, exe → artifact. Job 3: `softprops/action-gh-release@v2` anexa: exe, payload/cura-ferramentas.rbz, payload/fonts.zip, manifest.json, scripts/install.sh, scripts/install.ps1, com `fail_on_unmatched_files: true` (os 6 são obrigatórios: faltar um publica release verde e quebrada) e `prerelease: contains(github.ref_name, '-')`.
  - Gate de versão (falha o job com `::error::`): tag sem o `v` e sem o sufixo tem que ser igual a `biblioteca_version` (senão o parque inteiro faz no-op e ninguém recebe a release); `plugins[0].version` tem que ser igual à `VERSION` dentro do .rbz e à `CURA_UI_VERSION` do shell.html. Sufixo de tag só é aceito na forma `-rcN` (aviso amarelo, sai como prerelease invisível pro parque, serve pra teste); qualquer outro hífen (`-beta`, `-final`) é erro duro — é o jeito mais fácil de publicar uma release que ninguém recebe.
- `README.md` — PT-BR normal (aluno lê): seção aluno (Windows: baixar exe, SmartScreen "Saiba mais > Executar assim mesmo" enquanto sem assinatura; Mac: colar 1 linha no Terminal), seção **publicar uma versão** (runbook: os 3 números manuais, a armadilha do hífen, o `curl -sI` de conferência depois de publicar), seção **reverter (kill switch)** (ir pra frente > flip pra pre-release + apagar a tag remota, com o aviso de que o rollback roda instalação de verdade na máquina do aluno), seção futuro (assinatura de código Win/Mac = slots prontos; plugin por assinatura = trocar `url` no manifest p/ endpoint autenticado).

## Identidade visual CURA (obrigatória em TUDO user-facing)

Fonte: DNA CURA (`dna-cura/visual.md`, espinha E1–E7). Assets já copiados em `assets/` do repo (cura-marca-tight.svg, cura-marca-branco-tight.svg, cura-marca-preto.png, cura-marca-branco.png). Masters 512px: `~/dev/cura-ferramentas/src/cura_ferramentas/core/assets/cura-marca-{preto,branco,verde}-512.png`.

**Paleta (E1 — fechada, sem gradiente/tom fora dela):**
- branco `#FFFFFF` · preto `#000000` · verde cura `#AFBCAF` (default)
- terracota `#B34E31` — SÓ pra mensagens de erro no terminal (única secundária usada; 1 por peça)

**Voz/copy (E5):** TUDO lowercase (títulos, resumos, prompts) — exceto números, siglas e nomes de produto (SketchUp, Windows, GitHub). **Sem emoji** (nem ✅ — trocar resumo final por texto puro "ok /"). Sem exclamação em série. Brand mark grafado `{ cura }` (com chaves, espaços internos) SÓ como marca no banner/imagem; em frase corrida = **cura** sem chaves.

**Terminal (install.sh + install.ps1) — banner obrigatório no início:**
```
  { cura }  biblioteca 9.0
  instalador mac            ← ou "instalador windows"
```
- sh: ANSI 256-color quando stdout é tty (`[ -t 1 ]`): marca em verde cura ≈ `\033[38;5;151m`, texto bold `\033[1m`, erro em terracota ≈ `\033[38;5;131m`, reset `\033[0m`. Sem tty → plain ASCII sem escapes.
- ps1: se `$Host.UI.SupportsVirtualTerminal` → mesmos códigos ANSI via `$([char]27)`; senão fallback `Write-Host -ForegroundColor` (marca DarkGreen, erro DarkRed, resto default). Nunca depender de truecolor.
- Resumo final sem emoji, lowercase: `ok / instalado: cura | ferramentas v0.8.0 em 2 versões do SketchUp (2021, 2025). log: <path>`.
- E7 no espírito: separadores = linha reta `─` ou `-`, sem caixas ASCII rebuscadas.

**Inno wizard (efetor B):**
- `windows/wizard-large.bmp` 164×314 24-bit: fundo verde cura `#AFBCAF` chapado (E7: plano sólido, borda dura, sem gradiente/sombra), marca preta (cura-marca-preto.png, alpha compositado sobre o verde) centrada no terço superior, largura ~120px. Sem texto extra (Guarujá não licenciada pra embed; marca SVG/PNG já tem texto em path).
- `windows/wizard-small.bmp` 55×58 24-bit: marca preta sobre verde cura.
- `windows/cura.ico` (16/32/48/256): quadrado chapado verde cura + marca preta centrada (~70% da largura). Cantos retos (E7).
- Gerar via `tools/make_assets.py` (python3+PIL, stdlib+PIL only) — regenerável, entra no repo.
- `installer.iss`: `WizardStyle=modern`, `WizardImageFile`/`WizardSmallImageFile`/`SetupIconFile` apontando pros assets. [Messages] em PT-BR lowercase voz CURA: WelcomeLabel1 `biblioteca cura`; WelcomeLabel2 `este instalador baixa e instala a versão mais recente dos plugins e fontes do método cura.%n%nfeche o SketchUp antes de continuar.`; FinishedHeadingLabel `pronto`; FinishedLabel `biblioteca cura instalada. abra o SketchUp e confira o menu Extensões.`
- AppName mantém `Biblioteca CURA` (Adicionar/Remover do Windows = contexto do sistema, capitalização natural ajuda aluno achar).

**README.md:** topo com `<p align="center"><img src="assets/cura-marca-tight.svg" width="140"></p>`, título `# biblioteca cura`, headings lowercase. Prosa normal (aluno lê), sem emoji.

## Regras de código (obrigatórias, dos arquivos de memória)

- Shell: `set -euo pipefail`; mktemp+trap; nunca path sem quote; testar com `bash -n`.
- Python: pathlib, sem `strftime` com locale, stdlib only.
- PS: 5.1-safe, TLS12, BOM UTF-8.
- Destrutivo (remoção): SÓ nomes exatos do manifest/snapshot. Nunca rm -rf de glob solto. Nunca tocar em nada fora de Plugins/, Fonts e dirs CURA-Biblioteca.
- Msgs de erro: sempre com path do log e próximo passo pro aluno.
- Sem feature além deste spec (YAGNI). Sem auth, sem telemetria, sem auto-update do .exe — o exe é bootstrapper: quem se atualiza sozinho é o conteúdo (scripts + payload) via release "latest".
- Versão é manual em 3 lugares (tag, `biblioteca_version`, `plugins[].version`) e nenhum script bumpa nada. Toda automação nova aqui é CONFERÊNCIA que quebra o CI, nunca bump automático.
