#!/bin/bash
# scripts/install.sh — instalador da Biblioteca CURA (macOS)
#
# bash 3.2-compativel (macOS ships 3.2 por padrao): sem associative array,
# sem mapfile/readarray, sem ${var,,}. Ver SPEC.md na raiz do repo.
#
# Uso:
#   /bin/bash -c "$(curl -fsSL https://github.com/joaotegoni/cura-biblioteca/releases/latest/download/install.sh)"
#   ./install.sh --uninstall
#   ./install.sh --limpar
#
# Variaveis de ambiente:
#   CURA_BASE_URL   override da URL/dir base dos assets (teste local). Aceita
#                   caminho absoluto ("/path/to/release") ou "file:///path" ->
#                   copia local (cp) em vez de curl. Default: release "latest"
#                   do GitHub.
#
# Exit codes: 0 = ok; 1 = parcial (SketchUp nao encontrado); 2 = falha.
# -E (errtrace): sem isso o trap ERR abaixo NAO dispara dentro de funcoes —
# e onde quase tudo de arriscado (cp/mkdir/unzip) realmente roda.
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DEFAULT_BASE_URL="https://github.com/joaotegoni/cura-biblioteca/releases/latest/download"
BASE_URL="${CURA_BASE_URL:-$DEFAULT_BASE_URL}"
BASE_URL="${BASE_URL%/}"

# aviso de beta — some quando a biblioteca sair do beta (remover as 2 linhas e
# os usos de $BETA_NOTE). Ver README, secao "beta".
BETA_NOTE="esta é uma versão beta: seguimos testando e corrigindo. se algo falhar, mande o log pro suporte."

APP_SUPPORT_DIR="$HOME/Library/Application Support"
CURA_STATE_DIR="$APP_SUPPORT_DIR/CURA-Biblioteca"
SNAPSHOT_PATH="$CURA_STATE_DIR/installed.json"
LOG_PATH="$CURA_STATE_DIR/install.log"
FONTS_DIR="$HOME/Library/Fonts"

# pasta compartilhada do Cura Upscaler (Photoshop). NAO e per-user de proposito:
# o .atn que o aluno carrega no Photoshop tem este caminho CRAVADO dentro dele
# (tools/make_photoshop.py, MAC_DIR), entao tem que ser o mesmo pra qualquer
# usuario da maquina. /Users/Shared existe em todo mac, e gravavel sem admin e
# e legivel por todo mundo. Se este caminho mudar, mudam junto: MAC_DIR do
# make_photoshop.py, o PASTAS[] do tools/instalar-cura-upscaler.jsx e o
# $script:PhotoshopDir do install.ps1.
PHOTOSHOP_BASE_DIR="/Users/Shared/CURA-Biblioteca"
PHOTOSHOP_DIR="$PHOTOSHOP_BASE_DIR/photoshop"

# porao de recuperacao: TUDO que sai de um Plugins/ por acao nossa (o "limpar
# sketchup" e a lista "remove" do manifest) vai pra ca — nunca apaga, sempre da
# pra arrastar de volta. carimbo com segundos: duas rodadas no mesmo minuto nao
# colidem na mesma pasta.
RECOVERY_BASE="$HOME/Documents/cura-plugins-removidos/$(date +%Y-%m-%d-%H%M%S)"

# lock de concorrencia (launchagent de auto-update x execucao manual sobre o
# mesmo installed.json/Plugins) — ver acquire_lock/release via cleanup().
LOCK_DIR="$CURA_STATE_DIR/.lock"
LOCK_HELD=0

# launchagent de auto-update. em quiet o plist e reescrito so quando muda e o
# launchctl nunca e chamado — ver register_updater. caminho fica sob $HOME,
# entao testes com HOME isolado nao tocam o launchd real da maquina.
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
UPDATER_LABEL="com.cura.biblioteca.updater"
UPDATER_PLIST="$LAUNCH_AGENTS_DIR/$UPDATER_LABEL.plist"

# flags aceitos em $1/$2, independentes e em qualquer ordem. o launchagent de
# auto-update chama "curl ... | bash -s -- --quiet", entao --quiet chega como
# $1; --uninstall e uso manual. varremos os dois primeiros args pra nao
# depender de posicao.
UNINSTALL=0
QUIET=0
LIMPAR=0
for _arg in "${1:-}" "${2:-}"; do
  case "$_arg" in
    --uninstall) UNINSTALL=1 ;;
    --quiet) QUIET=1 ;;
    --limpar) LIMPAR=1 ;;
    "") ;;
    # sem esse ramo, um typo ("--Limpar", "--unistall", "--help") caia direto
    # na instalacao completa em silencio — o oposto do que o aluno pediu. err()
    # e as cores ainda nao existem aqui, entao a mensagem vai crua no stderr.
    *)
      printf '%s\n' "opção desconhecida: $_arg. use --uninstall ou --limpar." >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Cores (identidade visual CURA — só quando stdout é tty; sem tty = plain)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_VERDE=$'\033[38;5;151m'
  C_BOLD=$'\033[1m'
  C_ERRO=$'\033[38;5;131m'
  C_RESET=$'\033[0m'
else
  C_VERDE=""
  C_BOLD=""
  C_ERRO=""
  C_RESET=""
fi
SEPARADOR="----------------------------------------"

# separador de campo pros registros TSV internos (manifest/snapshot parsing).
# NAO usa tab: bash trata tab como "IFS whitespace" e COLAPSA delimitadores
# consecutivos (perde campos vazios, ex. url:null). 0x1f (unit separator) e
# um caractere de controle que nunca aparece em texto normal e nao sofre
# esse colapso — testado e confirmado antes de usar.
US=$'\x1f'

# ---------------------------------------------------------------------------
# Temp dir + cleanup
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cura-biblioteca.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
  # so libera o lock se ESTE processo foi quem tomou (nunca mexe num lock de
  # outra execucao so porque o dir existe).
  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$CURA_STATE_DIR"

# ---------------------------------------------------------------------------
# Log + mensagens (voz CURA: lowercase, sem emoji; excecao = numeros, siglas
# e nomes de produto como SketchUp/GitHub)
# ---------------------------------------------------------------------------
log() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '[%s] %s\n' "$ts" "$1" >> "$LOG_PATH"
}

log_header() {
  {
    printf '\n===== biblioteca cura — instalador mac — %s =====\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } >> "$LOG_PATH"
}

say() {
  # em quiet (auto-update sem terminal) so o log recebe — nada no stdout.
  if [ "$QUIET" != "1" ]; then
    printf '%s\n' "$1"
  fi
  log "$1"
}

err() {
  printf '%s%s%s\n' "$C_ERRO" "$1" "$C_RESET" >&2
  log "erro: $1"
}

# aviso: visivel como o err() (stderr, aparece mesmo em quiet no updater.err),
# mas SEM o terracota — a paleta reserva a cor pra erro terminal, e aviso nao
# ganha cor propria. usado pelo passo bonus do cura upscaler, que nunca e falha
# de instalacao: o log registra "aviso:", nao "erro:".
warn() {
  printf '%s\n' "$1" >&2
  log "aviso: $1"
}

# catch-all pra falhas inesperadas (disco cheio, permissao negada, etc) que
# set -e aborta sem passar pelos caminhos de erro ja tratados — evita
# traceback cru do sistema sem explicacao e sem apontar pro log. nao muda os
# exit codes documentados (0/1/2): esses caminhos usam "exit N" explicito, que
# nao dispara ERR. so falhas de comando realmente inesperadas caem aqui.
trap 'err "erro inesperado. log: $LOG_PATH."; exit 2' ERR

banner() {
  # sem banner em quiet: o modo auto-update nao imprime nada no stdout.
  if [ "$QUIET" = "1" ]; then
    return 0
  fi
  printf '\n'
  printf '  %s%s{ cura }%s  biblioteca\n' "$C_BOLD" "$C_VERDE" "$C_RESET"
  printf '  %sinstalador mac%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s\n\n' "$SEPARADOR"
}

# ---------------------------------------------------------------------------
# Helpers gerais
# ---------------------------------------------------------------------------
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# imprime um array JSON de strings (uma por linha, indentado) a partir dos
# argumentos recebidos apos o indent. Zero argumentos -> nada impresso
# (array JSON vazio e valido mesmo com so espaco em branco entre [ e ]).
print_json_string_array() {
  local indent="$1"; shift
  local n=$#
  local i=0
  local item
  for item in "$@"; do
    i=$((i + 1))
    if [ "$i" -lt "$n" ]; then
      printf '%s"%s",\n' "$indent" "$(json_escape "$item")"
    else
      printf '%s"%s"\n' "$indent" "$(json_escape "$item")"
    fi
  done
}

is_local_base() {
  case "$1" in
    /*) return 0 ;;
    file://*) return 0 ;;
    *) return 1 ;;
  esac
}

local_base_path() {
  case "$1" in
    file://*) printf '%s' "${1#file://}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# roda "$@" com timeout manual de $1 segundos (sem depender de `timeout`,
# que nao vem por padrao no macOS). Usado so pra checar se python3 responde
# sem travar (stub do CLT em Mac sem Xcode Command Line Tools pode abrir
# popup de instalacao em vez de rodar).
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  local watcher=$!
  local status=0
  wait "$pid" 2>/dev/null || status=$?
  kill -9 "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$status"
}

PYTHON3_BIN=""
detect_python3() {
  if command -v python3 >/dev/null 2>&1; then
    local resolved
    resolved="$(command -v python3)"
    # /usr/bin/python3 e o stub do Xcode Command Line Tools: sem CLT
    # instalado, so CHAMAR esse binario (mesmo pra --version) dispara um
    # popup grafico do sistema pedindo pra instalar o CLT — sem relacao
    # visivel com a biblioteca cura, confunde o aluno nao-tecnico. xcode-
    # select -p retorna rapido e sem popup quando o CLT esta ausente, entao
    # usamos ele pra decidir se e seguro invocar o stub. (parser awk de
    # fallback cobre tudo que o parser python cobre — ver parse_manifest/
    # write_snapshot/read_snapshot, todos com branch awk equivalente.)
    if [ "$resolved" = "/usr/bin/python3" ] && ! xcode-select -p >/dev/null 2>&1; then
      return 0
    fi
    if run_with_timeout 5 python3 --version >/dev/null 2>&1; then
      PYTHON3_BIN="python3"
    fi
  fi
}

verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ]
}

# fetch_asset <nome-relativo-a-BASE_URL> <destino>
# aborta o script (exit 2) em falha de rede/local — sem internet no meio da
# instalacao compromete o download inteiro, nao só este item.
fetch_asset() {
  local name="$1" dest="$2"
  if is_local_base "$BASE_URL"; then
    local src_dir src
    src_dir="$(local_base_path "$BASE_URL")"
    src="$src_dir/$name"
    if [ ! -e "$src" ]; then
      err "arquivo não encontrado em modo local: $src. log: $LOG_PATH."
      exit 2
    fi
    cp "$src" "$dest"
  else
    # --connect-timeout so limita o HANDSHAKE: sem --speed-limit/--speed-time o
    # download que trava no meio (wi-fi ruim, proxy engasgado) pendura o
    # instalador pra sempre, com a tela parada e sem nada pra ler. aborta se
    # ficar 60s abaixo de 1 KB/s — teto por velocidade, nao por tempo total
    # (o fonts.zip tem ~9 MB e um link lento porem saudavel nao pode estourar).
    if ! curl -fsSL --retry 3 --connect-timeout 30 --speed-limit 1024 --speed-time 60 "$BASE_URL/$name" -o "$dest"; then
      err "falha ao baixar $name — sem internet ou GitHub inacessível. log: $LOG_PATH. verifique sua conexão e rode o instalador de novo."
      exit 2
    fi
  fi
}

# fetch_asset_optional <nome-relativo-a-BASE_URL> <destino>
# igual ao fetch_asset, mas NAO aborta: devolve 1 e deixa quem chama decidir.
# existe pro passo do photoshop, que e bonus — um 404 ou uma queda de rede la
# nao pode desfazer/impedir a instalacao do plugin e das fontes, que e o que o
# aluno realmente veio buscar.
fetch_asset_optional() {
  local name="$1" dest="$2"
  if is_local_base "$BASE_URL"; then
    local src_dir src
    src_dir="$(local_base_path "$BASE_URL")"
    src="$src_dir/$name"
    [ -e "$src" ] || return 1
    cp "$src" "$dest" || return 1
    return 0
  fi
  curl -fsSL --retry 3 --connect-timeout 30 --speed-limit 1024 --speed-time 60 "$BASE_URL/$name" -o "$dest" || return 1
  return 0
}

# fetch_absolute_url <url-ou-path-absoluta> <destino>
# usado quando um plugin declara "url" propria no manifest (em vez de null).
fetch_absolute_url() {
  local url="$1" dest="$2"
  if is_local_base "$url"; then
    local src
    src="$(local_base_path "$url")"
    if [ ! -e "$src" ]; then
      err "arquivo não encontrado em modo local: $src. log: $LOG_PATH."
      exit 2
    fi
    cp "$src" "$dest"
  else
    if ! curl -fsSL --retry 3 --connect-timeout 30 --speed-limit 1024 --speed-time 60 "$url" -o "$dest"; then
      err "falha ao baixar $url — sem internet ou GitHub inacessível. log: $LOG_PATH. verifique sua conexão e rode o instalador de novo."
      exit 2
    fi
  fi
}

# só nomes exatos (sem "/" nem "..") — nunca glob solto, nunca fora de
# Plugins/Fonts/CURA-Biblioteca (regra de codigo obrigatoria do SPEC).
# os nomes vindos do manifest sao expandidos SEM aspas (pra o IFS="," quebrar o
# CSV de roots), o que tambem liga pathname expansion: um "*" no manifest viraria
# glob contra o diretorio corrente logo antes de um rm -rf. barramos aqui.
is_safe_leaf_name() {
  case "$1" in
    "" | */* | *..*) return 1 ;;
    *[*?[]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_allowed_removal_path() {
  local p="$1"
  # ".." em QUALQUER posicao reprova antes de olhar prefixo: os padroes abaixo
  # casam por prefixo literal, entao "$PHOTOSHOP_DIR/../../algo" (ou o mesmo
  # truque nos Plugins/Fonts) passava na whitelist e virava alvo de rm -rf. o
  # caminho vem do installed.json, que e arquivo em disco e pode estar
  # adulterado/corrompido — nao ha caso legitimo com ".." no snapshot.
  case "$p" in
    *..*) return 1 ;;
  esac
  case "$p" in
    "$APP_SUPPORT_DIR"/SketchUp\ */SketchUp/Plugins/*) return 0 ;;
    "$FONTS_DIR"/*) return 0 ;;
    # pasta compartilhada do Photoshop: e da BIBLIOTECA (so o instalador
    # escreve la), entao o --uninstall pode tirar o que registrou no snapshot.
    "$PHOTOSHOP_DIR"/*) return 0 ;;
    "$CURA_STATE_DIR"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Scripts auxiliares (python3 + awk) embutidos — gravados em $TMP_DIR em
# runtime. install.sh e um arquivo unico distribuido via curl|bash, entao os
# parsers viajam dentro dele em vez de arquivos separados no release.
# ---------------------------------------------------------------------------
PARSE_MANIFEST_PY="$TMP_DIR/parse_manifest.py"
PARSE_MANIFEST_AWK="$TMP_DIR/parse_manifest.awk"
PARSE_SNAPSHOT_AWK="$TMP_DIR/parse_snapshot.awk"
WRITE_SNAPSHOT_PY="$TMP_DIR/write_snapshot.py"
WRITE_SNAPSHOT_AWK="$TMP_DIR/write_snapshot.awk"

write_helper_scripts() {
  cat > "$PARSE_MANIFEST_PY" <<'PYEOF'
import json
import sys

US = "\x1f"


def emit(*fields):
    print(US.join("" if f is None else str(f) for f in fields))


def main():
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    emit("SCALAR", "schema", data.get("schema", ""))
    emit("SCALAR", "biblioteca_version", data.get("biblioteca_version", ""))
    emit("SCALAR", "min_sketchup", data.get("min_sketchup", ""))

    for plugin in data.get("plugins", []) or []:
        roots = plugin.get("roots", []) or []
        url = plugin.get("url")
        emit(
            "PLUGIN",
            plugin.get("id", ""),
            plugin.get("name", ""),
            plugin.get("version", ""),
            plugin.get("file", ""),
            url if url else "",
            plugin.get("sha256", ""),
            ",".join(roots),
        )

    fonts = data.get("fonts")
    if fonts:
        families = fonts.get("families", []) or []
        emit("FONTS", fonts.get("file", ""), fonts.get("sha256", ""), ",".join(families))

    # bloco opcional (manifest velho em cache nao tem): ausente = etapa pulada.
    photoshop = data.get("photoshop")
    if photoshop:
        emit("PHOTOSHOP", photoshop.get("file", ""), photoshop.get("sha256", ""))

    for name in data.get("remove", []) or []:
        emit("REMOVE", name)


if __name__ == "__main__":
    main()
PYEOF

  # parser de fallback (sem python3) pro manifest.json do schema 1. NAO e
  # parser JSON generico: assume formatacao gerada por tools/make_manifest.py
  # (json.dumps indent=2 — 2 espacos por nivel, um elemento de array por
  # linha). Manifest e nosso, formato controlado; parser simples e aceitavel.
  cat > "$PARSE_MANIFEST_AWK" <<'AWKEOF'
BEGIN {
  state = "top"
  US = "\037"
}

function unesc(s) {
  gsub(/\\\\/, "\\", s)
  gsub(/\\"/, "\"", s)
  return s
}

function strval(line,    v) {
  v = line
  sub(/^[^:]*:[ \t]*"/, "", v)
  sub(/",?[ \t]*$/, "", v)
  return unesc(v)
}

function arrval(line,    v) {
  v = line
  sub(/^[ \t]*"/, "", v)
  sub(/",?[ \t]*$/, "", v)
  return unesc(v)
}

function rawval(line,    v) {
  v = line
  sub(/^[^:]*:[ \t]*/, "", v)
  sub(/,[ \t]*$/, "", v)
  gsub(/^[ \t]+|[ \t]+$/, "", v)
  return v
}

state == "top" && /^  "schema":/ { print "SCALAR" US "schema" US rawval($0); next }
state == "top" && /^  "biblioteca_version":/ { print "SCALAR" US "biblioteca_version" US strval($0); next }
state == "top" && /^  "min_sketchup":/ { print "SCALAR" US "min_sketchup" US rawval($0); next }

state == "top" && /^  "plugins": \[\]/ { next }
state == "top" && /^  "plugins": \[/ { state = "plugins_wait"; next }

state == "plugins_wait" && /^    \{/ {
  state = "plugin"
  p_id = ""; p_name = ""; p_version = ""; p_file = ""; p_url = ""; p_sha256 = ""; p_roots = ""
  next
}
state == "plugins_wait" && /^  \]/ { state = "top"; next }

state == "plugin" && /^      "id":/      { p_id = strval($0); next }
state == "plugin" && /^      "name":/    { p_name = strval($0); next }
state == "plugin" && /^      "version":/ { p_version = strval($0); next }
state == "plugin" && /^      "file":/    { p_file = strval($0); next }
state == "plugin" && /^      "url":/ {
  raw = rawval($0)
  p_url = (raw == "null") ? "" : strval($0)
  next
}
state == "plugin" && /^      "sha256":/  { p_sha256 = strval($0); next }
state == "plugin" && /^      "roots": \[\]/ { next }
state == "plugin" && /^      "roots": \[/ { state = "roots"; next }
state == "plugin" && /^    \}/ {
  print "PLUGIN" US p_id US p_name US p_version US p_file US p_url US p_sha256 US p_roots
  state = "plugins_wait"
  next
}

state == "roots" && /^      \]/ { state = "plugin"; next }
state == "roots" {
  v = arrval($0)
  p_roots = (p_roots == "") ? v : p_roots "," v
  next
}

state == "top" && /^  "fonts": null/ { next }
# o guard do bloco vazio: "fonts": {} numa linha so casa a regra de entrada mas
# NUNCA casa a regra de saida (o "}" ja passou), entao o parser ficaria preso no
# state ate o fim do arquivo e engoliria em silencio tudo que vem depois (o
# bloco photoshop e a lista remove). linha que ja traz o fechamento = bloco
# vazio = ausente, igual ao "if fonts:" do parser python.
state == "top" && /^  "fonts": \{/ && $0 !~ /\{[[:space:]]*\}/ {
  state = "fonts"
  f_file = ""; f_sha256 = ""; f_families = ""
  next
}
state == "fonts" && /^    "file":/    { f_file = strval($0); next }
state == "fonts" && /^    "sha256":/  { f_sha256 = strval($0); next }
state == "fonts" && /^    "families": \[\]/ { next }
state == "fonts" && /^    "families": \[/ { state = "families"; next }
state == "fonts" && /^  \}/ {
  print "FONTS" US f_file US f_sha256 US f_families
  state = "top"
  next
}
state == "families" && /^    \]/ { state = "fonts"; next }
state == "families" {
  v = arrval($0)
  f_families = (f_families == "") ? v : f_families "," v
  next
}

# bloco photoshop (Cura Upscaler): mesmo formato do fonts — opcional, some sem
# erro num manifest antigo. a linha "url": null cai fora de qualquer regra e e
# ignorada, igual acontece no bloco fonts. o mesmo guard de bloco vazio do
# fonts vale aqui: "photoshop": {} numa linha so entraria no state e nunca
# sairia, comendo a lista remove logo abaixo.
state == "top" && /^  "photoshop": null/ { next }
state == "top" && /^  "photoshop": \{/ && $0 !~ /\{[[:space:]]*\}/ {
  state = "photoshop"
  ps_file = ""; ps_sha256 = ""
  next
}
state == "photoshop" && /^    "file":/   { ps_file = strval($0); next }
state == "photoshop" && /^    "sha256":/ { ps_sha256 = strval($0); next }
state == "photoshop" && /^  \}/ {
  print "PHOTOSHOP" US ps_file US ps_sha256
  state = "top"
  next
}

state == "top" && /^  "remove": \[\]/ { next }
state == "top" && /^  "remove": \[/ { state = "remove"; next }
state == "remove" && /^  \]/ { state = "top"; next }
state == "remove" {
  print "REMOVE" US arrval($0)
  next
}
AWKEOF

  cat > "$PARSE_SNAPSHOT_AWK" <<'AWKEOF2'
BEGIN { state = "top"; US = "\037" }
function arrval(line,    v) {
  v = line
  sub(/^[ \t]*"/, "", v)
  sub(/",?[ \t]*$/, "", v)
  gsub(/\\\\/, "\\", v)
  gsub(/\\"/, "\"", v)
  return v
}
function strval(line,    v) {
  v = line
  sub(/^[^:]*:[ \t]*"/, "", v)
  sub(/",?[ \t]*$/, "", v)
  gsub(/\\\\/, "\\", v)
  gsub(/\\"/, "\"", v)
  return v
}
state == "top" && /^  "biblioteca_version":/ { print "SCALAR" US "biblioteca_version" US strval($0); next }
state == "top" && /^  "installed_at":/ { print "SCALAR" US "installed_at" US strval($0); next }
state == "top" && /^  "item_labels": \[\]/ { next }
state == "top" && /^  "item_labels": \[/ { state = "labels"; next }
state == "labels" && /^  \]/ { state = "top"; next }
state == "labels" { print "LABEL" US arrval($0); next }
state == "top" && /^  "item_paths": \[\]/ { saw_paths = 1; next }
state == "top" && /^  "item_paths": \[/ { saw_paths = 1; state = "paths"; next }
state == "paths" && /^  \]/ { state = "top"; next }
state == "paths" { print "PATH" US arrval($0); next }
# sentinela de integridade: o awk casa por regex e sai 0 em arquivo truncado,
# vazio ou lixo — sem isso o read_snapshot nao teria como distinguir "registro
# vazio de verdade" de "arquivo cortado no meio". a regra do "}" fica DEPOIS
# das regras de state de proposito: num arquivo cortado dentro do array a
# linha e consumida com "next" la em cima e saw_close nunca e setado.
/^\}/ { saw_close = 1 }
END { if (saw_close && saw_paths && state == "top") print "SENTINEL" US "ok" }
AWKEOF2

  cat > "$WRITE_SNAPSHOT_PY" <<'PYEOF2'
import json
import sys

US = "\x1f"


def main():
    tsv_path, out_path = sys.argv[1], sys.argv[2]
    biblioteca_version = ""
    installed_at = ""
    labels = []
    paths = []
    pending_label = None
    with open(tsv_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split(US)
            rtype = parts[0]
            if rtype == "SCALAR":
                key, val = parts[1], parts[2]
                if key == "biblioteca_version":
                    biblioteca_version = val
                elif key == "installed_at":
                    installed_at = val
            elif rtype == "LABEL":
                pending_label = parts[1]
            elif rtype == "PATH":
                labels.append(pending_label)
                paths.append(parts[1])
                pending_label = None

    data = {
        "biblioteca_version": biblioteca_version,
        "installed_at": installed_at,
        "item_labels": labels,
        "item_paths": paths,
    }
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
PYEOF2

  cat > "$WRITE_SNAPSHOT_AWK" <<'AWKEOF3'
BEGIN {
  FS = "\037"
  n = 0
  biblioteca_version = ""
  installed_at = ""
  pending_label = ""
}
function jesc(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  return s
}
$1 == "SCALAR" && $2 == "biblioteca_version" { biblioteca_version = $3 }
$1 == "SCALAR" && $2 == "installed_at" { installed_at = $3 }
$1 == "LABEL" { pending_label = $2 }
$1 == "PATH" {
  n++
  labels[n] = pending_label
  paths[n] = $2
}
END {
  printf "{\n"
  printf "  \"biblioteca_version\": \"%s\",\n", jesc(biblioteca_version)
  printf "  \"installed_at\": \"%s\",\n", jesc(installed_at)
  printf "  \"item_labels\": [\n"
  for (i = 1; i <= n; i++) {
    comma = (i < n) ? "," : ""
    printf "    \"%s\"%s\n", jesc(labels[i]), comma
  }
  printf "  ],\n"
  printf "  \"item_paths\": [\n"
  for (i = 1; i <= n; i++) {
    comma = (i < n) ? "," : ""
    printf "    \"%s\"%s\n", jesc(paths[i]), comma
  }
  printf "  ]\n"
  printf "}\n"
}
AWKEOF3
}

# ---------------------------------------------------------------------------
# Estado global do manifest (arrays paralelos — bash 3.2 nao tem assoc array)
# ---------------------------------------------------------------------------
MIN_SKETCHUP=""
BIBLIOTECA_VERSION=""
PLUGIN_IDS=(); PLUGIN_NAMES=(); PLUGIN_VERSIONS=(); PLUGIN_FILES=()
PLUGIN_URLS=(); PLUGIN_SHA256S=(); PLUGIN_ROOTS_CSV=()
FONTS_FILE=""; FONTS_SHA256=""
PHOTOSHOP_FILE=""; PHOTOSHOP_SHA256=""
# 1 = o manifest TEM bloco photoshop, mas ele veio quebrado (campo faltando ou
# sha256 fora do formato). Diferente de "sem bloco" (os dois campos vazios e
# esta flag em 0), que e o manifest antigo em cache e nao e erro nenhum.
PHOTOSHOP_INVALID=0
REMOVE_NAMES=()

parse_manifest() {
  local manifest_path="$1"
  local tsv="$TMP_DIR/manifest.tsv"

  # guarda barata antes de qualquer parser, protege os dois branches: resposta
  # que nao comeca com "{" nao e o nosso manifest. e o caso do wi-fi com tela
  # de login e do proxy corporativo, que devolvem HTML com HTTP 200 — o parser
  # awk engoliria isso em silencio e sairia com TUDO vazio.
  case "$(tr -d '[:space:]' < "$manifest_path" | cut -c1)" in
    '{') ;;
    *)
      err "manifest.json inválido (a resposta não é JSON) — sua rede pode estar interceptando o download (wi-fi com tela de login, proxy). log: $LOG_PATH. conecte em outra rede e rode o instalador de novo."
      exit 2
      ;;
  esac

  if [ -n "$PYTHON3_BIN" ]; then
    if ! "$PYTHON3_BIN" "$PARSE_MANIFEST_PY" "$manifest_path" > "$tsv" 2>"$TMP_DIR/parse_manifest.err"; then
      err "manifest.json inválido ou não foi possível interpretá-lo. log: $LOG_PATH."
      log "detalhe (python3): $(cat "$TMP_DIR/parse_manifest.err" 2>/dev/null)"
      exit 2
    fi
  else
    if ! awk -f "$PARSE_MANIFEST_AWK" "$manifest_path" > "$tsv"; then
      err "manifest.json inválido ou não foi possível interpretá-lo. log: $LOG_PATH."
      log "detalhe (awk): parse_manifest.awk falhou"
      exit 2
    fi
  fi

  while IFS="$US" read -r rtype f1 f2 f3 f4 f5 f6 f7; do
    case "$rtype" in
      SCALAR)
        case "$f1" in
          min_sketchup) MIN_SKETCHUP="$f2" ;;
          biblioteca_version) BIBLIOTECA_VERSION="$f2" ;;
        esac
        ;;
      PLUGIN)
        PLUGIN_IDS+=("$f1")
        PLUGIN_NAMES+=("$f2")
        PLUGIN_VERSIONS+=("$f3")
        PLUGIN_FILES+=("$f4")
        PLUGIN_URLS+=("$f5")
        PLUGIN_SHA256S+=("$f6")
        PLUGIN_ROOTS_CSV+=("$f7")
        ;;
      FONTS)
        FONTS_FILE="$f1"
        FONTS_SHA256="$f2"
        ;;
      PHOTOSHOP)
        PHOTOSHOP_FILE="$f1"
        PHOTOSHOP_SHA256="$f2"
        ;;
      REMOVE)
        REMOVE_NAMES+=("$f1")
        ;;
    esac
  done < "$tsv"

  # validacao pos-parse: o awk sai 0 mesmo sem casar UMA linha, entao um
  # manifest fora do formato viraria "tudo vazio" sem ninguem reclamar — e
  # vazio, mais adiante, significa "nenhum SketchUp compativel" (MIN_SKETCHUP
  # vazio faz o teste de ano falhar pra toda versao) + "sem fontes", e o
  # installed.json seria reescrito zerado, transformando o que esta no disco
  # em orfao. melhor parar aqui.
  if [ -z "$BIBLIOTECA_VERSION" ]; then
    err "manifest.json inválido (sem biblioteca_version). log: $LOG_PATH. tente de novo mais tarde."
    exit 2
  fi
  case "$MIN_SKETCHUP" in
    [0-9][0-9][0-9][0-9]) ;;
    *)
      err "manifest.json inválido (min_sketchup='$MIN_SKETCHUP'). log: $LOG_PATH. tente de novo mais tarde."
      exit 2
      ;;
  esac
  if [ "${#PLUGIN_IDS[@]}" -eq 0 ] && [ -z "$FONTS_FILE" ]; then
    err "manifest.json inválido (sem plugins e sem fontes). log: $LOG_PATH. tente de novo mais tarde."
    exit 2
  fi

  # validacao pos-parse do bloco photoshop, mesma logica dos campos acima: o
  # awk sai 0 mesmo sem casar nada, entao um bloco meio-parseado viraria "file
  # sem sha" e o passo tentaria instalar sem conferir integridade. Aqui,
  # porem, NAO abortamos: o photoshop e bonus e nao pode derrubar plugin e
  # fontes (o passo la embaixo transforma isso em AVISO puro, sem HAD_ERROR e
  # sem mexer no exit code).
  # os dois campos vazios = manifest sem o bloco (cache antigo), caso normal.
  PHOTOSHOP_SHA256="$(printf '%s' "$PHOTOSHOP_SHA256" | tr 'A-F' 'a-f')"
  if [ -n "$PHOTOSHOP_FILE" ] || [ -n "$PHOTOSHOP_SHA256" ]; then
    local ps_ok=1
    [ -n "$PHOTOSHOP_FILE" ] || ps_ok=0
    is_safe_leaf_name "$PHOTOSHOP_FILE" || ps_ok=0
    [ "${#PHOTOSHOP_SHA256}" -eq 64 ] || ps_ok=0
    case "$PHOTOSHOP_SHA256" in *[!0-9a-f]*) ps_ok=0 ;; esac
    if [ "$ps_ok" = "0" ]; then
      log "aviso: bloco 'photoshop' do manifest inválido (file='$PHOTOSHOP_FILE', sha256='$PHOTOSHOP_SHA256') — cura upscaler não será instalado."
      PHOTOSHOP_INVALID=1
      PHOTOSHOP_FILE=""
      PHOTOSHOP_SHA256=""
    fi
  fi
}

# ---------------------------------------------------------------------------
# Snapshot (installed.json) — escrita e leitura
# ---------------------------------------------------------------------------
ITEM_LABELS=(); ITEM_PATHS=()

write_snapshot() {
  local tsv="$TMP_DIR/snapshot_in.tsv"

  # nada a registrar nesta rodada, mas o registro anterior tinha itens:
  # preserva o installed.json antigo em vez de zerar. registro zerado
  # transforma tudo que esta no disco em orfao — o --uninstall so olha o
  # registro. de proposito NAO e erro: sob --quiet (launchagent, login +
  # diaria) isso viraria falha barulhenta e recorrente, e existe caso legitimo
  # de zero itens (sem SketchUp e manifest sem fontes).
  if [ "${#ITEM_LABELS[@]}" -eq 0 ] && [ "${#SNAP_ITEM_PATHS[@]}" -gt 0 ]; then
    log "aviso: nada a registrar nesta rodada; preservando installed.json anterior (${#SNAP_ITEM_PATHS[@]} itens)."
    return 0
  fi

  {
    printf 'SCALAR%sbiblioteca_version%s%s\n' "$US" "$US" "$BIBLIOTECA_VERSION"
    printf 'SCALAR%sinstalled_at%s%s\n' "$US" "$US" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if [ "${#ITEM_LABELS[@]}" -gt 0 ]; then
      local idx
      for idx in "${!ITEM_LABELS[@]}"; do
        printf 'LABEL%s%s\n' "$US" "${ITEM_LABELS[$idx]}"
        printf 'PATH%s%s\n' "$US" "${ITEM_PATHS[$idx]}"
      done
    fi
  } > "$tsv"

  # escrita atomica: grava em .tmp e so troca pelo destino final no mv — uma
  # escrita interrompida (disco cheio, processo morto, sleep) nunca deixa um
  # installed.json truncado no lugar.
  if [ -n "$PYTHON3_BIN" ]; then
    "$PYTHON3_BIN" "$WRITE_SNAPSHOT_PY" "$tsv" "$SNAPSHOT_PATH.tmp"
  else
    awk -f "$WRITE_SNAPSHOT_AWK" "$tsv" > "$SNAPSHOT_PATH.tmp"
  fi
  mv -f "$SNAPSHOT_PATH.tmp" "$SNAPSHOT_PATH"
}

SNAP_ITEM_LABELS=(); SNAP_ITEM_PATHS=()
SNAP_BIBLIOTECA_VERSION=""

# read_snapshot: le installed.json e popula SNAP_*. retorna 1 (sem abortar
# mesmo sob set -e — quem chama usa "read_snapshot || true") se o arquivo
# existir mas estiver corrompido/truncado; quem chama trata como "sem
# snapshot" em vez de propagar o traceback cru do python.
read_snapshot() {
  local tsv="$TMP_DIR/snapshot_out.tsv"
  if [ -n "$PYTHON3_BIN" ]; then
    if ! "$PYTHON3_BIN" - "$SNAPSHOT_PATH" > "$tsv" 2>"$TMP_DIR/read_snapshot.err" <<'PYEOF3'
import json
import sys

US = "\x1f"

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    d = json.load(fh)

print("SCALAR" + US + "biblioteca_version" + US + str(d.get("biblioteca_version", "")))
for label in d.get("item_labels", []) or []:
    print("LABEL" + US + str(label))
for path in d.get("item_paths", []) or []:
    print("PATH" + US + str(path))
PYEOF3
    then
      log "aviso: installed.json corrompido/ilegível, tratando como sem registro. detalhe (python3): $(cat "$TMP_DIR/read_snapshot.err" 2>/dev/null)"
      return 1
    fi
  else
    awk -f "$PARSE_SNAPSHOT_AWK" "$SNAPSHOT_PATH" > "$tsv"
    # o awk casa por regex e sai 0 em arquivo truncado, vazio ou lixo — sem
    # esta checagem a branch awk NUNCA reportava corrupcao (ao contrario da
    # branch python3), e o --uninstall tratava o registro cortado como
    # "registro vazio" e apagava o installed.json que o comentario de la manda
    # preservar pro suporte. a sentinela so sai quando o arquivo fecha com "}",
    # a chave item_paths apareceu e nenhum array ficou aberto.
    if ! grep -q '^SENTINEL' "$tsv"; then
      log "aviso: installed.json corrompido/ilegível, tratando como sem registro. detalhe (awk): estrutura incompleta (arquivo truncado ou não é um installed.json)"
      return 1
    fi
  fi

  while IFS="$US" read -r rtype f1 f2; do
    case "$rtype" in
      SCALAR)
        # "if" e nao "[ ... ] && VAR=": com o && o status do teste vira o
        # status do corpo do loop, e um SCALAR que nao e biblioteca_version na
        # ULTIMA linha (installed_at, sempre) fazia o while — e a funcao —
        # retornarem 1, ou seja: snapshot valido reportado como corrompido.
        if [ "$f1" = "biblioteca_version" ]; then
          SNAP_BIBLIOTECA_VERSION="$f2"
        fi
        ;;
      LABEL) SNAP_ITEM_LABELS+=("$f1") ;;
      PATH) SNAP_ITEM_PATHS+=("$f1") ;;
    esac
  done < "$tsv"
  return 0
}

# ---------------------------------------------------------------------------
# Fluxo: aguarda SketchUp fechar (nao mata processo)
# ---------------------------------------------------------------------------
wait_sketchup_closed() {
  # testa o terminal UMA vez, antes do loop. sem terminal de controle
  # (execucao headless) seguir e defensavel; COM terminal, uma leitura que
  # falha e ctrl+D do aluno — e seguir ai e exatamente o que esta funcao
  # existe pra impedir (trocar arquivo embaixo do SketchUp rodando corrompe a
  # sessao). o do_uninstall ja aborta nesse caso; aqui era o unico ponto que
  # seguia mesmo assim.
  local tem_tty=0
  if (: < /dev/tty) 2>/dev/null; then
    tem_tty=1
  fi
  while pgrep -x "SketchUp" >/dev/null 2>&1; do
    printf '\nSketchUp está aberto. feche-o completamente antes de continuar.\n'
    printf 'pressione enter para verificar de novo (ou ctrl+c para cancelar): '
    # le como condicao de if (nao dispara set -e em falha). checar so
    # "[ -r /dev/tty ]" nao basta: o device pode existir e passar no teste
    # de permissao mas nao ter terminal de controle (ex. execucao headless)
    # e a redirecao falhar mesmo assim — só a tentativa real de leitura
    # revela isso. 2>/dev/null antes do "<" suprime o erro cru do bash.
    if read -r _ 2>/dev/null < /dev/tty; then
      :
    elif [ "$tem_tty" = "1" ]; then
      err "não deu pra confirmar que o SketchUp está fechado — nada foi alterado. log: $LOG_PATH. feche o SketchUp e rode o instalador de novo."
      exit 2
    else
      log "aviso: /dev/tty indisponível — seguindo sem confirmar fechamento do SketchUp"
      break
    fi
  done
}

# ---------------------------------------------------------------------------
# Limpeza de um Plugins/ (lista remove + roots de instalacao anterior)
# ---------------------------------------------------------------------------
# move um item pro porao de recuperacao. retorna 1 (sem apagar nada) se nao
# der — quem chama escreve a mensagem em portugues. 2>/dev/null no mv: erro cru
# do mv na cara do aluno nao ajuda ninguem.
move_to_recovery() {
  local src="$1" dest_dir="$2"
  local nome
  nome="$(basename "$src")"
  mkdir -p "$dest_dir" 2>/dev/null || return 1
  # destino ja ocupado: nao sobrescreve nem mistura conteudo — pula e avisa.
  if [ -e "$dest_dir/$nome" ]; then
    return 1
  fi
  mv -- "$src" "$dest_dir/" 2>/dev/null || return 1
  return 0
}

cleanup_plugins_dir() {
  local plugins_dir="$1" year="$2"
  local name target dest_dir

  if [ "${#REMOVE_NAMES[@]}" -gt 0 ]; then
    for name in "${REMOVE_NAMES[@]}"; do
      is_safe_leaf_name "$name" || continue
      target="$plugins_dir/$name"
      if [ -e "$target" ]; then
        # a lista "remove" do manifest ja carregou plugin de TERCEIRO (o
        # manifest 9.1.1 pedia TT_Lib2, que e dependencia de Solid Inspector2,
        # Vertex Tools e QuadFace Tools). vale a mesma regra do "limpar
        # sketchup": NUNCA apaga — move pro porao, da pra arrastar de volta.
        # sem isso, uma edicao de manifest apaga plugin pago do aluno em
        # silencio, disparada pelo launchagent em --quiet.
        dest_dir="$RECOVERY_BASE/SketchUp $year"
        if move_to_recovery "$target" "$dest_dir"; then
          log "movido (lista remove): $target -> $dest_dir/"
        else
          log "aviso: não consegui mover (lista remove): $target — mantido no lugar"
        fi
      fi
    done
  fi
}

# remove so as raizes de UM plugin (roots_csv), chamada logo antes do unzip
# DAQUELE plugin especifico — nunca em bloco pra todos os plugins do manifest
# de uma vez (fix blocker: download/sha falho de um plugin nao pode apagar a
# copia antiga de OUTRO plugin, nem a dele proprio antes de saber que a nova
# versao vai substitui-la com sucesso).
cleanup_plugin_roots() {
  local plugins_dir="$1" roots_csv="$2"
  local name target old_ifs
  old_ifs="$IFS"
  IFS=','
  for name in $roots_csv; do
    is_safe_leaf_name "$name" || continue
    target="$plugins_dir/$name"
    if [ -e "$target" ]; then
      rm -rf -- "$target"
      log "removido (upgrade limpo): $target"
    fi
  done
  IFS="$old_ifs"
}

# ---------------------------------------------------------------------------
# LaunchAgent de auto-update (dispara no login + reserva diaria)
# ---------------------------------------------------------------------------
# updater.out/updater.err crescem sem teto (uma execucao por login + uma por
# dia, pra sempre). trunca em ~1 MB. trunca no MESMO arquivo em vez de
# rotacionar: o launchd segura o descritor destes dois enquanto o job roda.
rotate_updater_logs() {
  local f size
  for f in "$CURA_STATE_DIR/updater.out" "$CURA_STATE_DIR/updater.err"; do
    [ -f "$f" ] || continue
    size="$(stat -f %z "$f" 2>/dev/null || echo 0)"
    case "$size" in '' | *[!0-9]*) size=0 ;; esac
    if [ "$size" -gt 1048576 ]; then
      printf '[%s] log truncado (passou de 1 MB)\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$f"
    fi
  done
}

register_updater() {
  mkdir -p "$LAUNCH_AGENTS_DIR"
  rotate_updater_logs

  # o updater SEMPRE puxa da release oficial: DEFAULT_BASE_URL literal, nunca
  # $BASE_URL (um teste local sobrescreve via CURA_BASE_URL). o pipeline
  # "curl ... | bash -s -- --quiet" fica literal no plist e e avaliado pelo bash
  # do launchd em runtime — o auto-update sempre baixa a versao vigente. (forma
  # pipe, nao "$(curl ...)": bash -c avaliando "$(...)" literal trataria a 1a
  # palavra do script como comando, nao rodaria o script.)
  local plist_tmp="$TMP_DIR/updater.plist"
  cat > "$plist_tmp" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$UPDATER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>curl -fsSL $DEFAULT_BASE_URL/install.sh | /bin/bash -s -- --quiet</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>StandardOutPath</key>
  <string>$CURA_STATE_DIR/updater.out</string>
  <key>StandardErrorPath</key>
  <string>$CURA_STATE_DIR/updater.err</string>
</dict>
</plist>
PLISTEOF

  # em quiet e o PROPRIO updater rodando: reescreve o plist so quando o
  # conteudo mudou e NUNCA chama launchctl (o job nao pode dar unload em si
  # mesmo — essa e a razao original do guard). o launchd pega a definicao nova
  # no proximo login. sem isso o plist era write-once: quem instalasse hoje
  # ficaria com esta URL/intervalo/Label pra sempre, sem caminho de migracao.
  if [ "$QUIET" = "1" ]; then
    if cmp -s "$plist_tmp" "$UPDATER_PLIST"; then
      return 0
    fi
    mv -f "$plist_tmp" "$UPDATER_PLIST"
    log "auto-update: plist atualizado (quiet — launchd recarrega no próximo login)"
    return 0
  fi

  mv -f "$plist_tmp" "$UPDATER_PLIST"
  log "auto-update registrado (login + diária)"

  # em teste (CURA_BASE_URL setado) o plist ja foi escrito num HOME isolado; nao
  # mexemos no launchd real da maquina — so pulamos o load/unload.
  if [ -n "${CURA_BASE_URL:-}" ]; then
    log "modo teste: launchctl load/unload pulado"
    return 0
  fi

  # ativa sem exigir novo login: unload silencioso (pode nao estar carregado)
  # seguido de load. if protege o set -e de retorno nao-zero legitimo.
  if launchctl unload "$UPDATER_PLIST" >/dev/null 2>&1; then :; fi
  if launchctl load "$UPDATER_PLIST" >/dev/null 2>&1; then :; fi
}

# ---------------------------------------------------------------------------
# Lock de concorrencia (launchagent de auto-update x execucao manual sobre o
# mesmo installed.json/Plugins)
# ---------------------------------------------------------------------------
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
    return 0
  fi
  # lock existe: se tiver mais de 1h, o dono provavelmente morreu (crash,
  # forcar-encerrar) — considera travado e toma.
  local now mtime age
  now="$(date +%s)"
  mtime="$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo "$now")"
  age=$((now - mtime))
  if [ "$age" -gt 3600 ]; then
    log "lock parado há mais de 1h ($LOCK_DIR) — considerado travado, tomando."
    rm -rf "$LOCK_DIR"
    # mkdir e atomico: se duas execucoes chegam aqui quase juntas, so uma
    # consegue criar o dir — quem perde a corrida desiste (nao seta
    # LOCK_HELD, senao as duas sairiam achando que tem o lock e uma
    # removeria o lock legitimo da outra no cleanup).
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      return 0
    fi
    return 1
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Instalacao
# ---------------------------------------------------------------------------
do_install() {
  log_header
  banner

  if ! acquire_lock; then
    say "outra operação da biblioteca cura já está em andamento. tente de novo em alguns minutos."
    exit 0
  fi

  if [ "$QUIET" = "1" ]; then
    # em quiet nao ha terminal pra pedir pra fechar o SketchUp; e trocar
    # arquivos embaixo do programa rodando corromperia a sessao. se estiver
    # aberto, adia — o proximo gatilho (login/diaria) tenta de novo.
    if pgrep -x "SketchUp" >/dev/null 2>&1; then
      log "quiet: SketchUp aberto, adiando update"
      exit 0
    fi
  else
    wait_sketchup_closed
  fi

  detect_python3
  write_helper_scripts

  local manifest_path="$TMP_DIR/manifest.json"
  fetch_asset "manifest.json" "$manifest_path"
  parse_manifest "$manifest_path"

  local VERSION_YEARS=() VERSION_DIRS=() SKIPPED_YEARS=()
  local d base year plugins_dir
  for d in "$APP_SUPPORT_DIR"/"SketchUp 20"*; do
    [ -e "$d" ] || continue
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    year="${base#SketchUp }"
    year="${year%% *}"
    case "$year" in
      '' | *[!0-9]*) continue ;;
    esac
    if [ "$year" -ge "$MIN_SKETCHUP" ]; then
      plugins_dir="$d/SketchUp/Plugins"
      mkdir -p "$plugins_dir"
      VERSION_YEARS+=("$year")
      VERSION_DIRS+=("$plugins_dir")
    elif [ -d "$d/SketchUp/Plugins" ]; then
      # SketchUp instalado, mas abaixo do minimo desta versao da biblioteca.
      # guardamos pra conseguir DIZER isso ao aluno — sem essa lista o
      # instalador nao distingue "nao tem SketchUp" de "tem, mas e antigo" e
      # manda instalar o SketchUp pra quem ja tem.
      SKIPPED_YEARS+=("$year")
    fi
  done

  # no-op short-circuit (antes de baixar qualquer payload): nada mudou desde a
  # ultima instalacao? entao nao re-extrai — evita trabalho a cada disparo do
  # auto-update. exige: (1) mesma versao da biblioteca no snapshot, (2) todo
  # item registrado ainda no disco, (3) TODO root de TODO plugin do manifest
  # ATUAL presente em cada Plugins/ detectado agora (nao basta 1 de N plugins
  # "cobrir" o dir — pega o caso de um plugin ter falhado numa rodada anterior
  # e sumido do disco enquanto outro plugin do mesmo dir segue presente) e (4)
  # toda versao do SketchUp detectada AGORA ja coberta pelo snapshot — assim
  # uma instalacao "so fontes" que depois ganha um SketchUp novo NAO vira
  # no-op e os plugins entram. qualquer teste que falhe (path faltando, versao
  # diferente, SketchUp novo, root de plugin faltando) segue instalacao normal.
  if [ -f "$SNAPSHOT_PATH" ]; then
    # snapshot corrompido/ilegivel (read_snapshot loga aviso e retorna 1): "||
    # true" evita abortar sob set -e — SNAP_ITEM_PATHS fica vazio e o no-op
    # abaixo simplesmente nao dispara, seguindo como instalacao normal.
    read_snapshot || true
    if [ -n "$BIBLIOTECA_VERSION" ] && [ "$SNAP_BIBLIOTECA_VERSION" = "$BIBLIOTECA_VERSION" ] && [ "${#SNAP_ITEM_PATHS[@]}" -gt 0 ]; then
      local noop=1 snap_path plugins_dir_c pi_c root_name_c old_ifs_c ps_no_snap=1
      for snap_path in "${SNAP_ITEM_PATHS[@]}"; do
        case "$snap_path" in
          "$PHOTOSHOP_DIR"/*)
            # a pasta compartilhada so conta pro no-op quando o manifest BAIXADO
            # ainda tem bloco photoshop VALIDO (PHOTOSHOP_FILE vazio = bloco
            # ausente ou quebrado). manifest velho em cache nao pode furar o
            # no-op por causa de arquivo que ele nem gerencia mais.
            [ -n "$PHOTOSHOP_FILE" ] || continue
            ps_no_snap=0
            [ -e "$snap_path" ] || { noop=0; break; }
            ;;
          *)
            [ -e "$snap_path" ] || { noop=0; break; }
            ;;
        esac
      done
      # manifest COM bloco photoshop e registro SEM nenhum arquivo do upscaler:
      # a etapa bonus nunca completou (download/escrita falhou numa rodada
      # anterior — falha que, de proposito, nao derruba a instalacao nem segura
      # a biblioteca_version). fura o no-op pra tentar de novo. e este teste que
      # transforma "bonus falhou hoje" em "bonus retentado amanha".
      if [ -n "$PHOTOSHOP_FILE" ] && [ "$ps_no_snap" = "1" ]; then
        noop=0
      fi
      if [ "$noop" = "1" ] && [ "${#VERSION_DIRS[@]}" -gt 0 ]; then
        for plugins_dir_c in "${VERSION_DIRS[@]}"; do
          for pi_c in "${!PLUGIN_IDS[@]}"; do
            old_ifs_c="$IFS"
            IFS=','
            for root_name_c in ${PLUGIN_ROOTS_CSV[$pi_c]}; do
              is_safe_leaf_name "$root_name_c" || continue
              [ -e "$plugins_dir_c/$root_name_c" ] || noop=0
            done
            IFS="$old_ifs_c"
          done
        done
      fi
      if [ "$noop" = "1" ]; then
        log "no-op: biblioteca ja na versao $BIBLIOTECA_VERSION"
        # silencioso em quiet; em modo normal, uma linha curta.
        if [ "$QUIET" != "1" ]; then
          say "biblioteca já está atualizada (v$BIBLIOTECA_VERSION). nada a fazer."
        fi
        # self-cura (paridade com o install.ps1, que ja registra no ramo de
        # no-op): o no-op e o estado NORMAL do dia a dia. sem esta chamada o
        # plist do auto-update nunca mais era reescrito nem recarregado — plist
        # removido ou desatualizado significava aluno fora do parque, em
        # silencio. register_updater nao chama launchctl em quiet.
        register_updater
        exit 0
      fi
    fi
  fi

  local HAD_ERROR=0

  if [ "${#VERSION_YEARS[@]}" -eq 0 ]; then
    # tres situacoes MUITO diferentes que antes recebiam o mesmo texto (e o
    # texto errado em duas delas: "instale o SketchUp" pra quem ja tem).
    # a deteccao varre "Application Support/SketchUp 20*", que o SketchUp so
    # cria no PRIMEIRO lancamento — instalar o .app nao cria nada.
    if [ "${#SKIPPED_YEARS[@]}" -gt 0 ]; then
      say "seu SketchUp ${SKIPPED_YEARS[*]} não é compatível com esta versão da biblioteca (mínimo: SketchUp $MIN_SKETCHUP) — instalando só as fontes."
    elif ls -d /Applications/SketchUp\ 20* >/dev/null 2>&1; then
      say "o SketchUp está instalado mas nunca foi aberto — instalando só as fontes. abra o SketchUp uma vez, feche, e rode este instalador de novo (ou não faça nada: o instalador se atualiza sozinho e instala os plugins no próximo login)."
    else
      say "SketchUp não encontrado — instalando só as fontes. instale o SketchUp e rode este instalador de novo."
    fi
  else
    # download + verificacao de cada plugin (1x, independente de quantas
    # versoes do SketchUp existam)
    mkdir -p "$TMP_DIR/payload"
    local PLUGIN_OK=()
    local i file url sha_expected dest
    for i in "${!PLUGIN_IDS[@]}"; do
      file="${PLUGIN_FILES[$i]}"
      url="${PLUGIN_URLS[$i]}"
      sha_expected="${PLUGIN_SHA256S[$i]}"
      dest="$TMP_DIR/payload/$file"

      if [ -n "$url" ]; then
        fetch_absolute_url "$url" "$dest"
      else
        fetch_asset "$file" "$dest"
      fi

      if verify_sha256 "$dest" "$sha_expected"; then
        PLUGIN_OK+=("1")
      else
        err "arquivo $file corrompido no download (sha256 não confere) — ${PLUGIN_NAMES[$i]} não instalado. log: $LOG_PATH. tente rodar o instalador de novo mais tarde."
        PLUGIN_OK+=("0")
        HAD_ERROR=1
      fi
    done

    # re-checa SketchUp aberto imediatamente antes da 1a escrita destrutiva em
    # Plugins/: os downloads acima podem levar minutos, o check no topo de
    # do_install pode estar desatualizado. mesma logica de la: quiet adia
    # (exit 0), interativo espera fechar.
    if [ "$QUIET" = "1" ]; then
      if pgrep -x "SketchUp" >/dev/null 2>&1; then
        log "quiet: SketchUp aberto (abriu durante o download), adiando update"
        exit 0
      fi
    else
      wait_sketchup_closed
    fi

    # por versao: limpeza da lista remove (incondicional) + por plugin, so
    # remove a raiz antiga e reinstala se o download/sha desta rodada foi ok
    # (fix blocker: download/sha falho nao pode apagar a copia antiga que
    # ainda funciona — ela fica intacta e a proxima rodada tenta de novo)
    local vi year_v plugins_dir_v pi root_name root_path
    for vi in "${!VERSION_YEARS[@]}"; do
      year_v="${VERSION_YEARS[$vi]}"
      plugins_dir_v="${VERSION_DIRS[$vi]}"
      cleanup_plugins_dir "$plugins_dir_v" "$year_v"

      for pi in "${!PLUGIN_IDS[@]}"; do
        if [ "${PLUGIN_OK[$pi]}" = "1" ]; then
          cleanup_plugin_roots "$plugins_dir_v" "${PLUGIN_ROOTS_CSV[$pi]}"
          unzip -oq "$TMP_DIR/payload/${PLUGIN_FILES[$pi]}" -d "$plugins_dir_v"
          log "instalado: ${PLUGIN_NAMES[$pi]} v${PLUGIN_VERSIONS[$pi]} em SketchUp $year_v"

          local old_ifs="$IFS"
          IFS=','
          for root_name in ${PLUGIN_ROOTS_CSV[$pi]}; do
            # mesma guarda do cleanup_plugin_roots: esta expansao e sem aspas
            # (pro IFS quebrar o CSV) e portanto tambem faz glob.
            is_safe_leaf_name "$root_name" || continue
            root_path="$plugins_dir_v/$root_name"
            if [ -e "$root_path" ]; then
              ITEM_LABELS+=("plugin ${PLUGIN_NAMES[$pi]} v${PLUGIN_VERSIONS[$pi]} (SketchUp $year_v)")
              ITEM_PATHS+=("$root_path")
            fi
          done
          IFS="$old_ifs"
        fi
      done
    done
  fi

  # fontes (independe de ter achado SketchUp — instala sempre que o manifest tiver)
  local FONTS_INSTALLED_COUNT=0
  if [ -n "$FONTS_FILE" ]; then
    local fonts_dest="$TMP_DIR/payload/$FONTS_FILE"
    mkdir -p "$TMP_DIR/payload"
    fetch_asset "$FONTS_FILE" "$fonts_dest"
    if verify_sha256 "$fonts_dest" "$FONTS_SHA256"; then
      mkdir -p "$FONTS_DIR"
      local extract_dir="$TMP_DIR/fonts_extracted"
      mkdir -p "$extract_dir"
      unzip -oq "$fonts_dest" -d "$extract_dir"
      local fontfile fontbase
      while IFS= read -r fontfile; do
        fontbase="$(basename "$fontfile")"
        cp "$fontfile" "$FONTS_DIR/$fontbase"
        FONTS_INSTALLED_COUNT=$((FONTS_INSTALLED_COUNT + 1))
        ITEM_LABELS+=("fonte $fontbase")
        ITEM_PATHS+=("$FONTS_DIR/$fontbase")
        log "fonte instalada: $FONTS_DIR/$fontbase"
      done < <(find "$extract_dir" -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \))
    else
      err "arquivo $FONTS_FILE corrompido no download (sha256 não confere) — fontes não instaladas. log: $LOG_PATH. tente rodar o instalador de novo mais tarde."
      HAD_ERROR=1
    fi
  else
    log "fontes: manifest sem fontes (fonts: null), etapa pulada."
  fi

  # cura upscaler (Photoshop) — BONUS. Tres regras que valem so pra este passo:
  #   1. independe de SketchUp (igual as fontes) e independe do Photoshop estar
  #      instalado: sao 3 arquivos numa pasta, quem liga o atalho e o aluno
  #      rodando o instalar-cura-upscaler.jsx uma vez;
  #   2. NUNCA derruba a instalacao NEM o exit code — download, sha ou escrita
  #      que falham viram AVISO e mais nada (sem HAD_ERROR): a biblioteca_version
  #      e gravada normalmente e o exit segue o que plugin/fontes deram (sucesso
  #      puro = 0). O retry nao vem do HAD_ERROR e sim do no-op la em cima, que
  #      exige os arquivos do upscaler no registro quando o manifest tem o bloco
  #      — falhou hoje, a rodada de amanha fura o no-op e tenta de novo. No
  #      Windows isso ainda mata o modal de erro do Inno (exit 2) por falha de
  #      bonus;
  #   3. manifest sem o bloco (cache antigo de uma release anterior) = etapa
  #      pulada em silencio, sem apagar nada do que ja esta la.
  # A pasta e compartilhada de proposito (ver PHOTOSHOP_DIR la em cima): dir 777
  # e arquivos 644. 777 e nao 775 porque /Users/Shared nasce com grupo wheel — o
  # SEGUNDO usuario do mac nao esta nesse grupo e com 775 nao conseguiria gravar
  # (nem remover) nada la. Sem sticky bit: o rm-antes-de-cp de uma rodada de
  # outro usuario precisa poder tirar o arquivo 644 que nao e dele.
  # RISCO ACEITO (de projeto, nao descuido): pasta 0777 sem sticky significa que
  # qualquer usuario ou processo local da maquina pode trocar o CuraUpscaler.jsx
  # que o F2 executa. Aceito porque as alternativas quebram o produto: o .atn
  # tem o caminho CRAVADO (per-user nao serve), 775 morre no grupo wheel do
  # /Users/Shared e o sticky bit mata o rm-antes-de-cp cross-user — e nada disso
  # pode exigir admin.
  local PHOTOSHOP_INSTALLED_COUNT=0
  if [ "$PHOTOSHOP_INVALID" = "1" ]; then
    warn "o manifest veio com o bloco do cura upscaler quebrado — ele não foi instalado (o resto da biblioteca seguiu normal). log: $LOG_PATH."
  elif [ -n "$PHOTOSHOP_FILE" ]; then
    mkdir -p "$TMP_DIR/payload"
    local ps_dest="$TMP_DIR/payload/$PHOTOSHOP_FILE"
    if ! fetch_asset_optional "$PHOTOSHOP_FILE" "$ps_dest"; then
      warn "não deu pra baixar $PHOTOSHOP_FILE — cura upscaler não instalado (o resto da biblioteca seguiu normal). log: $LOG_PATH."
    elif ! verify_sha256 "$ps_dest" "$PHOTOSHOP_SHA256"; then
      warn "arquivo $PHOTOSHOP_FILE corrompido no download (sha256 não confere) — cura upscaler não instalado. log: $LOG_PATH. o instalador tenta de novo sozinho mais tarde."
    else
      local ps_extract="$TMP_DIR/photoshop_extracted"
      rm -rf "$ps_extract"
      mkdir -p "$ps_extract"
      if ! unzip -oq "$ps_dest" -d "$ps_extract"; then
        warn "não deu pra abrir $PHOTOSHOP_FILE — cura upscaler não instalado. log: $LOG_PATH."
      elif ! mkdir -p "$PHOTOSHOP_DIR" 2>/dev/null; then
        warn "não deu pra criar $PHOTOSHOP_DIR — cura upscaler não instalado. log: $LOG_PATH."
      else
        # a pasta pode ter sido criada por OUTRO usuario da maquina (ou por uma
        # versao anterior deste instalador): chmod que falha e so log, nunca
        # erro — o que importa e conseguir gravar os arquivos.
        chmod 777 "$PHOTOSHOP_BASE_DIR" 2>/dev/null || log "aviso: não consegui ajustar permissão de $PHOTOSHOP_BASE_DIR (pasta de outro usuário?)"
        chmod 777 "$PHOTOSHOP_DIR" 2>/dev/null || log "aviso: não consegui ajustar permissão de $PHOTOSHOP_DIR (pasta de outro usuário?)"

        local ps_falhou=0 psfile psbase
        while IFS= read -r psfile; do
          psbase="$(basename "$psfile")"
          # mesma guarda de sempre antes de compor caminho de rm/cp.
          is_safe_leaf_name "$psbase" || continue
          # rm antes do cp: arquivo gravado por outro usuario da maquina nao e
          # sobrescrivel (644), mas E removivel numa pasta 777 sem sticky bit. e
          # o que torna a segunda rodada limpa em vez de meio-atualizada.
          rm -f "$PHOTOSHOP_DIR/$psbase" 2>/dev/null || true
          if cp "$psfile" "$PHOTOSHOP_DIR/$psbase" 2>/dev/null; then
            chmod 644 "$PHOTOSHOP_DIR/$psbase" 2>/dev/null || true
            PHOTOSHOP_INSTALLED_COUNT=$((PHOTOSHOP_INSTALLED_COUNT + 1))
            ITEM_LABELS+=("photoshop $psbase")
            ITEM_PATHS+=("$PHOTOSHOP_DIR/$psbase")
            log "cura upscaler: $PHOTOSHOP_DIR/$psbase"
          else
            ps_falhou=1
            log "aviso: não consegui gravar $PHOTOSHOP_DIR/$psbase"
          fi
        done < <(find "$ps_extract" -type f)

        if [ "$ps_falhou" = "1" ] || [ "$PHOTOSHOP_INSTALLED_COUNT" -eq 0 ]; then
          warn "cura upscaler não instalado por completo (sem permissão na pasta compartilhada?) — o resto da biblioteca seguiu normal. log: $LOG_PATH."
        fi
      fi
    fi
  else
    log "photoshop: manifest sem o bloco photoshop, etapa pulada."
  fi

  # reconciliacao com a rodada anterior. o installed.json e reconstruido do
  # ZERO a cada rodada, entao item que saiu do manifest (fonte que virou .ttc,
  # plugin que mudou de raiz) ficava no disco sem registro nenhum: orfao,
  # invisivel pro --uninstall e pro proprio instalador. varre o registro
  # anterior e resolve item por item — mas so remove dentro do escopo que ESTA
  # rodada realmente gerenciou. o que cai fora (tipico: Plugins/ de um SketchUp
  # abaixo do min_sketchup) NAO e apagado — seria tirar ferramenta que funciona
  # de quem nao tem pra onde atualizar; fica no registro como legado, pra o
  # --uninstall ainda dar conta dele.
  #
  # o carry-forward roda SEMPRE (mesmo com HAD_ERROR=1), igual ao
  # $mantidosAbaixoDoMinimo do install.ps1: rodada com erro em um item nao pode
  # apagar do registro o caminho de OUTRO item que nem foi tocado (o plugin no
  # SketchUp abaixo do minimo). o snapshot e reconstruido do zero, entao deixar
  # de re-anexar aqui significa perder o caminho pra sempre — orfao invisivel
  # pro --uninstall. quem continua gateado por HAD_ERROR e so a REMOCAO: com
  # erro na rodada, o que esta no disco pode ser justamente o que nao conseguiu
  # ser reinstalado agora.
  if [ "${#SNAP_ITEM_PATHS[@]}" -gt 0 ]; then
    local si snap_p snap_lbl in_new in_scope vd np
    for si in "${!SNAP_ITEM_PATHS[@]}"; do
      snap_p="${SNAP_ITEM_PATHS[$si]}"
      snap_lbl="${SNAP_ITEM_LABELS[$si]:-item}"

      in_new=0
      if [ "${#ITEM_PATHS[@]}" -gt 0 ]; then
        for np in "${ITEM_PATHS[@]}"; do
          if [ "$np" = "$snap_p" ]; then
            in_new=1
            break
          fi
        done
      fi
      if [ "$in_new" = "1" ]; then
        continue
      fi

      # escopo gerido agora: as fontes (so se instalamos fontes nesta rodada —
      # manifest sem fontes nao pode significar "apague as 22 que ja estao la")
      # e os Plugins/ das versoes do SketchUp que esta rodada atendeu.
      in_scope=0
      if [ "$FONTS_INSTALLED_COUNT" -gt 0 ]; then
        case "$snap_p" in "$FONTS_DIR"/*) in_scope=1 ;; esac
      fi
      # mesma regra das fontes pro cura upscaler: so entra no escopo se ESTA
      # rodada realmente escreveu na pasta compartilhada — manifest sem o bloco
      # photoshop nunca pode significar "apague o que ja esta la".
      if [ "$in_scope" = "0" ] && [ "$PHOTOSHOP_INSTALLED_COUNT" -gt 0 ]; then
        case "$snap_p" in "$PHOTOSHOP_DIR"/*) in_scope=1 ;; esac
      fi
      if [ "$in_scope" = "0" ] && [ "${#VERSION_DIRS[@]}" -gt 0 ]; then
        for vd in "${VERSION_DIRS[@]}"; do
          case "$snap_p" in "$vd"/*) in_scope=1; break ;; esac
        done
      fi

      if [ "$in_scope" = "1" ]; then
        if [ "$HAD_ERROR" = "0" ] && is_allowed_removal_path "$snap_p" && [ -e "$snap_p" ]; then
          rm -rf -- "$snap_p"
          log "removido (saiu desta versão da biblioteca): $snap_p"
        fi
        continue
      fi

      if [ -e "$snap_p" ]; then
        # prefixo "legado:" e idempotente — nao se acumula a cada rodada.
        case "$snap_lbl" in
          legado:*) ;;
          *) snap_lbl="legado: $snap_lbl" ;;
        esac
        ITEM_LABELS+=("$snap_lbl")
        ITEM_PATHS+=("$snap_p")
        log "mantido no registro como legado (fora do escopo desta versão): $snap_p"
      fi
    done
  fi

  # se algo falhou nesta rodada (HAD_ERROR=1), NAO grava a nova
  # biblioteca_version — grava a versao antiga do snapshot anterior (ou vazio
  # se nunca houve snapshot), pra proxima rodada do updater nao cair no no-op
  # e tentar de novo o que faltou.
  if [ "$HAD_ERROR" = "1" ]; then
    BIBLIOTECA_VERSION="$SNAP_BIBLIOTECA_VERSION"
  fi

  write_snapshot

  # resumo final (sem separador no stdout em quiet)
  if [ "$QUIET" != "1" ]; then
    printf '\n%s\n' "$SEPARADOR"
  fi

  # o upscaler chega instalado mas ainda desligado: quem carrega o atalho F2 no
  # Photoshop e o aluno, rodando o bootstrap uma vez. sem esta frase, os 3
  # arquivos ficam na pasta compartilhada sem ninguem nunca saber.
  local photoshop_note=""
  if [ "$PHOTOSHOP_INSTALLED_COUNT" -gt 0 ]; then
    photoshop_note=" cura upscaler instalado: pra ligar o atalho F2, abra o Photoshop em Arquivo > Scripts > Procurar e escolha $PHOTOSHOP_DIR/instalar-cura-upscaler.jsx (uma vez só)."
  fi

  if [ "${#VERSION_YEARS[@]}" -eq 0 ]; then
    if [ "$FONTS_INSTALLED_COUNT" -gt 0 ]; then
      say "fontes instaladas: $FONTS_INSTALLED_COUNT. log: $LOG_PATH.$photoshop_note"
    else
      say "log: $LOG_PATH.$photoshop_note"
    fi
    # registra o auto-update mesmo no caminho "so fontes": e justo aqui que ele
    # importa — quando o SketchUp aparecer depois, o gatilho instala os plugins
    # (o no-op acima nao dispara nesse caso). em quiet nao chama launchctl.
    register_updater
    # fonte com falha de integridade (HAD_ERROR=1) e falha real, nao "parcial
    # limpo" — nao mascarar num exit 1 igual ao caso 100% saudavel.
    if [ "$HAD_ERROR" = "1" ]; then
      exit 2
    fi
    exit 1
  fi

  local ok_plugins_desc="" first=1 piece
  for i in "${!PLUGIN_IDS[@]}"; do
    if [ "${PLUGIN_OK[$i]}" = "1" ]; then
      piece="${PLUGIN_NAMES[$i]} v${PLUGIN_VERSIONS[$i]}"
      if [ "$first" = "1" ]; then
        ok_plugins_desc="$piece"
        first=0
      else
        ok_plugins_desc="$ok_plugins_desc, $piece"
      fi
    fi
  done

  local versions_desc="" y
  for y in "${VERSION_YEARS[@]}"; do
    if [ -z "$versions_desc" ]; then
      versions_desc="$y"
    else
      versions_desc="$versions_desc, $y"
    fi
  done

  local ver_word="versões"
  [ "${#VERSION_YEARS[@]}" = "1" ] && ver_word="versão"

  local fonts_suffix=""
  if [ "$FONTS_INSTALLED_COUNT" -gt 0 ]; then
    fonts_suffix="; $FONTS_INSTALLED_COUNT fontes"
  fi

  # quem tem 2017 e 2024 lia so "instalado em 1 versão" e nao fazia ideia de
  # que uma ficou pra tras. dizer explicitamente.
  local skipped_note=""
  if [ "${#SKIPPED_YEARS[@]}" -gt 0 ]; then
    skipped_note=" SketchUp ${SKIPPED_YEARS[*]} não recebe mais atualização da biblioteca (mínimo: SketchUp $MIN_SKETCHUP)."
  fi

  local msg
  if [ -z "$ok_plugins_desc" ]; then
    msg="nenhum plugin instalado (falha de integridade) em ${#VERSION_YEARS[@]} ${ver_word} do SketchUp (${versions_desc})${fonts_suffix}. log: $LOG_PATH.${skipped_note}${photoshop_note}"
  else
    msg="instalado: ${ok_plugins_desc} em ${#VERSION_YEARS[@]} ${ver_word} do SketchUp (${versions_desc})${fonts_suffix}. log: $LOG_PATH.${skipped_note}${photoshop_note} abra o SketchUp e confira o menu Extensões. ${BETA_NOTE}"
  fi

  if [ "$HAD_ERROR" = "1" ]; then
    say "$msg"
    log "resumo: instalação parcial (havia item com falha de integridade)"
    # falha parcial e exatamente quando a retentativa agendada mais importa —
    # registra igual ao caminho de sucesso (em quiet nao chama launchctl).
    register_updater
    exit 2
  fi

  if [ "$QUIET" != "1" ]; then
    printf '%sok /%s %s\n' "$C_BOLD" "$C_RESET" "$msg"
  fi
  log "resumo: ok / $msg"
  # instalacao bem-sucedida: registra o auto-update (login + diaria). em quiet
  # so reescreve o plist se mudou, sem chamar launchctl.
  register_updater
  exit 0
}

# ---------------------------------------------------------------------------
# Desinstalacao — "explicando cada um"
# ---------------------------------------------------------------------------
do_uninstall() {
  log_header
  banner

  if ! acquire_lock; then
    say "outra operação da biblioteca cura já está em andamento. tente de novo em alguns minutos."
    exit 0
  fi

  if [ ! -f "$SNAPSHOT_PATH" ]; then
    say "nada instalado por este instalador (nenhum registro encontrado em $SNAPSHOT_PATH)."
    exit 0
  fi

  detect_python3
  write_helper_scripts
  # snapshot corrompido/ilegivel: read_snapshot loga aviso e retorna 1. esse
  # caso e tratado separado do "registro vazio" de verdade: preservamos o
  # installed.json (unica pista do que estava instalado, pro suporte) em vez
  # de apagar — so removemos quando o arquivo foi lido com sucesso e esta
  # genuinamente vazio.
  local snap_read_ok=1
  read_snapshot || snap_read_ok=0

  if [ "$snap_read_ok" = "0" ]; then
    say "não foi possível ler o registro de instalação (arquivo corrompido). o arquivo foi mantido em $SNAPSHOT_PATH para o suporte."
    exit 0
  fi

  if [ "${#SNAP_ITEM_PATHS[@]}" -eq 0 ]; then
    say "nada instalado por este instalador (registro vazio em $SNAPSHOT_PATH)."
    rm -f "$SNAPSHOT_PATH"
    exit 0
  fi

  say "a biblioteca cura vai remover os seguintes itens:"
  local i tem_photoshop=0
  for i in "${!SNAP_ITEM_PATHS[@]}"; do
    printf -- '- %s: %s\n' "${SNAP_ITEM_LABELS[$i]:-item}" "${SNAP_ITEM_PATHS[$i]}"
    case "${SNAP_ITEM_PATHS[$i]}" in "$PHOTOSHOP_DIR"/*) tem_photoshop=1 ;; esac
  done

  # a lista acima nao deixa claro que os 3 arquivos do upscaler moram numa pasta
  # da MAQUINA (/Users/Shared), nao do perfil: quem confirma achando que remove
  # "a minha instalacao" tira o atalho F2 de todo mundo que usa este mac.
  if [ "$tem_photoshop" = "1" ]; then
    printf '%s\n' "o cura upscaler é compartilhado — remover tira ele de todos os usuários deste computador."
  fi

  printf 'confirma a remoção? (s/n): '
  local resp=""
  # ver nota em wait_sketchup_closed: "[ -r /dev/tty ]" sozinho nao basta,
  # a tentativa real de leitura e que revela terminal indisponivel.
  if ! read -r resp 2>/dev/null < /dev/tty; then
    err "não foi possível confirmar (terminal indisponível). desinstalação cancelada por segurança. log: $LOG_PATH."
    exit 2
  fi

  case "$resp" in
    s | S | sim | Sim | SIM) ;;
    *)
      say "cancelado. nada foi removido."
      exit 0
      ;;
  esac

  local path
  for path in "${SNAP_ITEM_PATHS[@]}"; do
    if is_allowed_removal_path "$path"; then
      if [ -e "$path" ]; then
        rm -rf -- "$path"
        log "removido (uninstall): $path"
      fi
    else
      log "aviso: caminho fora do escopo permitido, ignorado na desinstalação: $path"
    fi
  done

  # pasta compartilhada do Photoshop: os arquivos ja sairam pelo laco acima
  # (estao no snapshot). o rmdir so remove dir VAZIO — se outro usuario da
  # maquina tambem instalou, os arquivos dele seguram a pasta e nada acontece.
  rmdir "$PHOTOSHOP_DIR" 2>/dev/null || true
  rmdir "$PHOTOSHOP_BASE_DIR" 2>/dev/null || true

  # desregistra o auto-update junto: unload silencioso + remove o plist, antes
  # de apagar o snapshot. em teste (CURA_BASE_URL) pula o launchctl real mas
  # ainda remove o plist do HOME isolado.
  if [ -z "${CURA_BASE_URL:-}" ]; then
    if launchctl unload "$UPDATER_PLIST" >/dev/null 2>&1; then :; fi
  fi
  if [ -e "$UPDATER_PLIST" ]; then
    rm -f "$UPDATER_PLIST"
    log "auto-update desregistrado"
  fi

  rm -f "$SNAPSHOT_PATH"
  printf '%sok /%s biblioteca cura desinstalada. log: %s\n' "$C_BOLD" "$C_RESET" "$LOG_PATH"
  log "resumo: ok / biblioteca cura desinstalada"
  exit 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# "limpar sketchup": esvazia o Plugins/ de TODA versao encontrada, preservando
# so o que comeca com cura_. NUNCA apaga — MOVE pra uma pasta de recuperacao em
# Documentos, porque aqui a gente mexe em plugin pago de terceiro (TT_Lib2 e
# dependencia de Solid Inspector2, Vertex Tools, QuadFace Tools).
# ponytail: sem seleção item-a-item e sem varrer versoes < MIN_SKETCHUP no
# filtro do do_install — de proposito, limpeza tem que pegar todas. Se um dia
# precisar de escolha por plugin, vira UI no proprio cura | ferramentas.
do_limpar() {
  local destino_base achados=() d base year plugins_dir item nome resposta
  local falhas=0 nao_sairam=""

  if [ "$QUIET" = "1" ]; then
    err "--limpar nao roda em modo silencioso: exige confirmacao."
    # "exit" e nao "return": do_limpar e chamado como ultimo comando do "then"
    # la embaixo, entao um return nao-zero NAO e isento do set -e e disparava o
    # trap ERR, imprimindo "erro inesperado" por cima da mensagem certa.
    exit 2
  fi

  # mesmas duas protecoes do do_install, que faltavam aqui: (1) mover pasta de
  # plugin com o SketchUp aberto quebra a sessao em curso, e o aluno culpa a
  # limpeza; (2) o launchagent de auto-update pode disparar no meio da limpeza
  # mexendo no mesmo Plugins/ — e exatamente pra isso que o lock existe.
  if ! acquire_lock; then
    say "outra operação da biblioteca cura já está em andamento. tente de novo em alguns minutos."
    exit 0
  fi
  wait_sketchup_closed

  destino_base="$RECOVERY_BASE"

  for d in "$APP_SUPPORT_DIR"/"SketchUp 20"*; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    year="${base#SketchUp }"
    year="${year%% *}"
    case "$year" in '' | *[!0-9]*) continue ;; esac
    plugins_dir="$d/SketchUp/Plugins"
    [ -d "$plugins_dir" ] || continue
    for item in "$plugins_dir"/*; do
      [ -e "$item" ] || continue
      nome="$(basename "$item")"
      # su_* sao os plugins que a propria Trimble instala aqui (su_sandbox =
      # Sandbox Tools, su_dynamiccomponents, su_solarnorth). Mover isso tira
      # ferramenta nativa do SketchUp do aluno — fica de fora da limpeza.
      case "$nome" in cura_* | su_*) continue ;; esac
      achados+=("$year$US$plugins_dir$US$nome")
    done
  done

  if [ "${#achados[@]}" -eq 0 ]; then
    printf '%s\n' "nada pra limpar: so o cura esta instalado."
    return 0
  fi

  printf '%s\n' "$SEPARADOR"
  printf '%s\n' "${C_BOLD}vao sair do SketchUp ${#achados[@]} itens:${C_RESET}"
  for item in "${achados[@]}"; do
    printf '  SketchUp %s  ->  %s\n' "${item%%"$US"*}" "${item##*"$US"}"
  done
  printf '%s\n' "$SEPARADOR"
  printf '%s\n' "eles NAO serao apagados. vao pra:"
  printf '  %s\n' "$destino_base"
  printf '%s\n' "o cura | ferramentas fica onde esta."
  printf '\n%s' "confirma? [s/N] "
  # 2>/dev/null ANTES do "<": o bash aplica redirect da esquerda pra direita, e
  # na ordem invertida a falha de abrir /dev/tty vaza o erro cru do bash na
  # cara do aluno. mesma armadilha documentada no wait_sketchup_closed.
  read -r resposta 2>/dev/null < /dev/tty || resposta=""
  case "$resposta" in
    s | S | sim | SIM) ;;
    *) printf '%s\n' "cancelado, nada foi movido."; return 0 ;;
  esac

  for item in "${achados[@]}"; do
    year="${item%%"$US"*}"
    nome="${item##*"$US"}"
    plugins_dir="${item#*"$US"}"; plugins_dir="${plugins_dir%"$US"*}"
    if move_to_recovery "$plugins_dir/$nome" "$destino_base/SketchUp $year"; then
      log "limpeza: movido $plugins_dir/$nome"
    else
      falhas=$((falhas + 1))
      nao_sairam="$nao_sairam
  SketchUp $year  ->  $nome"
      log "limpeza: nao consegui mover $plugins_dir/$nome — continua la"
    fi
  done

  # numa operacao vendida como "nunca apaga, sempre da pra desfazer", dizer
  # "pronto" quando o item continua no Plugins/ e o pior tipo de mentira. o
  # fecho e condicional e a saida e nao-zero quando ficou item pra tras.
  if [ "$falhas" -gt 0 ]; then
    err "$falhas item(ns) nao sairam do Plugins e continuam la:$nao_sairam"
    printf '%s\n' "o que saiu esta em:"
    printf '  %s\n' "$destino_base"
    printf '%s\n' "log: $LOG_PATH"
    exit 1
  fi

  printf '\n%s\n' "${C_VERDE}pronto.${C_RESET} tudo que saiu esta em:"
  printf '  %s\n' "$destino_base"
  printf '%s\n' "arrependeu? e so arrastar de volta pra pasta Plugins."
}

if [ "$LIMPAR" = "1" ]; then
  do_limpar
elif [ "$UNINSTALL" = "1" ]; then
  do_uninstall
else
  do_install
fi
