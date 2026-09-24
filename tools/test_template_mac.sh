#!/bin/bash
# Funcoes reais, somente diretórios temporários. Não executa instalador/launchd
# e não troca HOME. Requer python3 apenas para exercitar os dois parsers.
set -Eeuo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/install.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cura-template-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TMP_DIR="$TEST_ROOT/runtime"
APP_SUPPORT_DIR="$TEST_ROOT/Application Support"
CURA_STATE_DIR="$APP_SUPPORT_DIR/CURA-Biblioteca"
LOG_PATH="$TEST_ROOT/test.log"
FONTS_DIR="$TEST_ROOT/fonts"
PHOTOSHOP_DIR="$TEST_ROOT/photoshop"
SNAPSHOT_PATH="$CURA_STATE_DIR/installed.json"
US=$'\x1f'
mkdir -p "$TMP_DIR" "$CURA_STATE_DIR" "$TEST_ROOT/Applications"
# O trecho só declara funções e estado; não contém o dispatcher no fim.
awk '/^is_safe_leaf_name\(\)/ {p=1} /^do_install\(\)/ {exit} p {print}' "$SCRIPT" > "$TMP_DIR/functions.sh"
source "$TMP_DIR/functions.sh"
log() { printf '%s\n' "$*" >> "$LOG_PATH"; }
err() { log "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@"; then fail "aceitou: $*"; fi; }

write_helper_scripts
PYTHON_TEST="$(command -v python3)"
printf 'template fixture\n' > "$TEST_ROOT/CURA.skp"
TEMPLATE_SHA256="$(shasum -a 256 "$TEST_ROOT/CURA.skp" | awk '{print $1}')"
TEMPLATE_PRESENT=1
TEMPLATE_FILE=CURA.skp
TEMPLATE_MIN=2018

for test_year in 2017 2018 2024 2026; do
  mkdir -p "$APP_SUPPORT_DIR/SketchUp $test_year/SketchUp"
done
mkdir -p "$TEST_ROOT/Applications/SketchUp 2030/SketchUp.app"
mkdir -p "$TEST_ROOT/Applications/SketchUp 2024/SketchUp.app"
mkdir -p "$TEST_ROOT/Applications/SketchUp 2099"
discover_template_dirs "$APP_SUPPORT_DIR" "$TEST_ROOT/Applications" 2018
[ "${#TEMPLATE_DIRS[@]}" -eq 4 ] || fail 'detecção/deduplicação de versões'
reject templates_up_to_date
for template_dir in "${TEMPLATE_DIRS[@]}"; do
  install_template_file "$TEST_ROOT/CURA.skp" "$template_dir/CURA.skp" "$TEMPLATE_SHA256"
  cmp -s "$TEST_ROOT/CURA.skp" "$template_dir/CURA.skp" || fail 'bytes diferentes'
  ITEM_PATHS+=("$template_dir/CURA.skp")
  ITEM_LABELS+=("template CURA")
done
[ ! -e "$APP_SUPPORT_DIR/SketchUp 2017/SketchUp/Templates" ] || fail 'instalou em 2017'
[ -f "$APP_SUPPORT_DIR/SketchUp 2030/SketchUp/Templates/CURA.skp" ] || fail 'app sem perfil'
reject templates_up_to_date # existência sem recibo ainda precisa instalação

for parser in python awk; do
  if [ "$parser" = python ]; then PYTHON3_BIN="$PYTHON_TEST"; else PYTHON3_BIN=""; fi
  BIBLIOTECA_VERSION=10.2.0
  write_snapshot
  SNAP_ITEM_PATHS=(); SNAP_ITEM_LABELS=()
  read_snapshot
  [ "${#SNAP_ITEM_PATHS[@]}" -eq 4 ] || fail "snapshot $parser"
  templates_up_to_date || fail "no-op $parser"
done

target="$APP_SUPPORT_DIR/SketchUp 2024/SketchUp/Templates/CURA.skp"
install_template_file "$TEST_ROOT/CURA.skp" "$target" "$TEMPLATE_SHA256"
[ ! -e "$CURA_STATE_DIR/template-backups" ] || fail 'backup em reinstalação idêntica'
printf 'meu template editado\n' > "$target"
cp "$target" "$TEST_ROOT/custom.skp"
templates_up_to_date || fail 'no-op deve preservar edição na mesma versão'
reject install_template_file "$TEST_ROOT/CURA.skp" "$target" badhash
cmp -s "$target" "$TEST_ROOT/custom.skp" || fail 'hash errado alterou original'
install_template_file "$TEST_ROOT/CURA.skp" "$target" "$TEMPLATE_SHA256"
cmp -s "$target" "$TEST_ROOT/custom.skp" || fail 'reparo da mesma release alterou edição'
[ ! -e "$CURA_STATE_DIR/template-backups" ] || fail 'reparo gerou backup desnecessário'
BIBLIOTECA_VERSION=10.2.1
install_template_file "$TEST_ROOT/CURA.skp" "$target" "$TEMPLATE_SHA256"
backups=("$CURA_STATE_DIR"/template-backups/cura.*/CURA.skp)
[ "${#backups[@]}" -eq 1 ] && cmp -s "${backups[0]}" "$TEST_ROOT/custom.skp" || fail 'backup original'
printf 'segunda edição\n' > "$target"
install_template_file "$TEST_ROOT/CURA.skp" "$target" "$TEMPLATE_SHA256"
backups=("$CURA_STATE_DIR"/template-backups/cura.*/CURA.skp)
[ "${#backups[@]}" -eq 2 ] || fail 'backup sobrescrito'
rm -f -- "$target"
reject templates_up_to_date
install_template_file "$TEST_ROOT/CURA.skp" "$target" "$TEMPLATE_SHA256"
templates_up_to_date || fail 'reparo faltante'
mkdir -p "$TEST_ROOT/Applications/SketchUp 2031/SketchUp.app"
discover_template_dirs "$APP_SUPPORT_DIR" "$TEST_ROOT/Applications" 2018
reject templates_up_to_date

# O SketchUp abre durante o download, depois de outros componentes escritos.
# A etapa deve retornar, manter os recibos e marcar retry; nunca exit antes
# do snapshot/updater. Nenhum pgrep/launchd real neste teste.
fetch_asset_optional() { cp "$TEST_ROOT/CURA.skp" "$2"; }
pgrep() { [ "$SKETCHUP_OPEN" = 1 ]; }
warn() { log "$*"; }
say() { log "$*"; }
SKETCHUP_OPEN=1
QUIET=1
HAD_ERROR=0
paths_before="${#ITEM_PATHS[@]}"
install_templates
[ "$HAD_ERROR" = 1 ] || fail 'não marcou adiamento para retry'
[ "${#ITEM_PATHS[@]}" = "$paths_before" ] || fail 'perdeu recibos anteriores'
[ ! -e "$APP_SUPPORT_DIR/SketchUp 2031/SketchUp/Templates/CURA.skp" ] || fail 'escreveu com SketchUp aberto'
write_snapshot # prova que a etapa retornou sem encerrar o instalador
[ -s "$SNAPSHOT_PATH" ] || fail 'snapshot não persistiu após adiamento'
SKETCHUP_OPEN=0
HAD_ERROR=0
install_templates
[ "$HAD_ERROR" = 0 ] || fail 'retentativa não completou'
[ -f "$APP_SUPPORT_DIR/SketchUp 2031/SketchUp/Templates/CURA.skp" ] || fail 'ano novo não instalado na retentativa'

reject is_safe_template_path "$APP_SUPPORT_DIR/SketchUp 2024/SketchUp/Templates/outro.skp"
reject is_safe_template_path "$APP_SUPPORT_DIR/SketchUp 2024/SketchUp/Templates/../CURA.skp"
ln -s "$TEST_ROOT" "$APP_SUPPORT_DIR/SketchUp 2040"
reject install_template_file "$TEST_ROOT/CURA.skp" "$APP_SUPPORT_DIR/SketchUp 2040/SketchUp/Templates/CURA.skp" "$TEMPLATE_SHA256"
recover_template_file "$target"
[ ! -e "$target" ] || fail 'template não saiu na desinstalação'
recovered=("$CURA_STATE_DIR"/template-backups/uninstall.*/CURA.skp)
cmp -s "${recovered[0]}" "$TEST_ROOT/CURA.skp" || fail 'recuperação'
[ "${#backups[@]}" -eq 2 ] || fail 'recuperação apagou backup'

# Formato canônico indent=2, usado pelo gerador do manifest e parser awk.
for variant in valid absent null empty unsafe badhash badmin scalar; do
  "$PYTHON_TEST" - "$variant" "$TEMPLATE_SHA256" "$TEST_ROOT/manifest.json" <<'PY'
import json, sys
variant, sha, path = sys.argv[1:]
data = {'schema': 1, 'biblioteca_version': '10.2.0', 'min_sketchup': 2026,
        'plugins': [], 'fonts': {'file': 'fonts.zip', 'sha256': sha}}
template = {'file': 'CURA.skp', 'sha256': sha, 'min_sketchup': 2018}
if variant == 'unsafe': template['file'] = '../CURA.skp'
if variant == 'badhash': template['sha256'] = 'wrong'
if variant == 'badmin': template['min_sketchup'] = 'latest'
if variant == 'scalar': template = 'invalid'
if variant == 'null': template = None
if variant == 'empty': template = {}
if variant != 'absent': data['sketchup_template'] = template
data['remove'] = ['old_plugin']
with open(path, 'w') as f: json.dump(data, f, indent=2)
PY
  for parser in python awk; do
    if [ "$parser" = python ]; then PYTHON3_BIN="$PYTHON_TEST"; else PYTHON3_BIN=""; fi
    (
      TEMPLATE_PRESENT=0; TEMPLATE_FILE=""; TEMPLATE_SHA256=""; TEMPLATE_MIN=""
      parse_manifest "$TEST_ROOT/manifest.json"
      case "$variant" in
        valid)
          [ "$TEMPLATE_PRESENT" = 1 ] && [ "$TEMPLATE_MIN" = 2018 ] && [ "$MIN_SKETCHUP" = 2026 ] || exit 1 ;;
        absent|null) [ "$TEMPLATE_PRESENT" = 0 ] || exit 1 ;;
        *) exit 99 ;;
      esac
      [ "${REMOVE_NAMES[0]}" = old_plugin ] || exit 1
    ) && parse_rc=0 || parse_rc=$?
    case "$variant" in
      valid|absent|null) [ "$parse_rc" -eq 0 ] || fail "parser $parser: $variant ($parse_rc)" ;;
      *) [ "$parse_rc" -eq 2 ] || fail "parser aceitou $parser: $variant ($parse_rc)" ;;
    esac
  done
done
printf 'PASS macOS: versões, app sem perfil, hash, idempotência, reparo, backups, recuperação, symlink, parsers e snapshots.\n'
