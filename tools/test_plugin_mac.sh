#!/bin/bash
# Real Bash 3.2/file operations against temporary profiles. Never changes HOME,
# invokes launchd, or runs the installer's dispatcher.
set -Eeuo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/install.sh"
TEST_ROOT="$(mktemp -d "/private/tmp/cura-plugin-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TMP_DIR="$TEST_ROOT/runtime"
mkdir -p "$TMP_DIR"
awk '/^is_local_base\(\)/ {p=1} /^do_uninstall\(\)/ {exit} p {print}' "$SCRIPT" > "$TEST_ROOT/functions.sh"
source "$TEST_ROOT/functions.sh"
log() {
  printf '%s\n' "$*" >> "$TEST_ROOT/test.log"
  if [ -n "${LOG_PATH:-}" ] && [ "$LOG_PATH" != "$TEST_ROOT/test.log" ]; then printf '%s\n' "$*" >> "$LOG_PATH"; fi
}
err() { log "$*"; }
say() { log "$*"; }
warn() { log "$*"; }
banner() { :; }
log_header() { :; }
register_updater() { :; }
pgrep() { return 1; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@"; then fail "accepted: $*"; fi; }
US=$'\x1f'
QUIET=1
C_VERDE='' C_RESET='' C_ERRO='' SEPARADOR='' BETA_NOTE=''

python3 - "$TEST_ROOT" <<'PY'
import json, stat, sys, zipfile
from pathlib import Path
base = Path(sys.argv[1])
for mode in ('good', 'missing', 'thirdparty', 'traversal', 'symlink', 'duplicate'):
    with zipfile.ZipFile(base / (mode + '.zip'), 'w') as archive:
        archive.writestr('cura_demo/core.rbe', b'new encoded payload')
        if mode != 'missing': archive.writestr('cura_demo.rb', b'new loader')
        if mode == 'thirdparty': archive.writestr('TT_Lib2/paid.rb', b'overwrite')
        if mode == 'traversal': archive.writestr('cura_demo/../../identity.json', b'overwrite')
        if mode == 'symlink':
            entry = zipfile.ZipInfo('cura_demo/link')
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, '../../identity.json')
        if mode == 'duplicate': archive.writestr('CURA_DEMO.RB', b'collision')
(base / 'broken.zip').write_bytes(b'valid hash, invalid archive')
PY
prepare_plugin_payload "$TEST_ROOT/good.zip" 'cura_demo,cura_demo.rb' "$TEST_ROOT/valid-stage"
for mode in missing thirdparty traversal symlink duplicate broken; do
  reject prepare_plugin_payload "$TEST_ROOT/$mode.zip" 'cura_demo,cura_demo.rb' "$TEST_ROOT/stage-$mode"
done
reject prepare_plugin_payload "$TEST_ROOT/good.zip" 'TT_Lib2' "$TEST_ROOT/stage-thirdparty-root"

run_case() {
  local mode="$1" case_root="$TEST_ROOT/$1" rc=0
  mkdir -p "$case_root/assets" "$case_root/runtime"
  local plugins="$case_root/Application Support/SketchUp 2026/SketchUp/Plugins"
  mkdir -p "$plugins/cura_demo" "$plugins/TT_Lib2" "$case_root/Application Support/CURA-Biblioteca"
  printf 'old loader\n' > "$plugins/cura_demo.rb"
  printf 'old encoded\n' > "$plugins/cura_demo/core.rbe"
  printf 'third party\n' > "$plugins/TT_Lib2/paid.rb"
  printf 'old renamed root\n' > "$plugins/cura_demo_legacy.rb"
  printf 'identity outside Plugins\n' > "$case_root/identity.json"
  cp "$TEST_ROOT/good.zip" "$case_root/assets/plugin.rbz"
  case "$mode" in extract) cp "$TEST_ROOT/broken.zip" "$case_root/assets/plugin.rbz" ;; esac
  python3 - "$case_root" "$plugins" "$mode" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, plugins, mode = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
sha = hashlib.sha256((root/'assets/plugin.rbz').read_bytes()).hexdigest()
if mode == 'hash': sha = '0' * 64
manifest = {'schema': 1, 'biblioteca_version': 'new', 'min_sketchup': 2018,
'plugins': [{'id': 'cura-demo', 'name': 'CURA demo', 'version': 'new', 'file': 'plugin.rbz', 'url': None, 'sha256': sha, 'roots': ['cura_demo', 'cura_demo.rb']}], 'remove': ['TT_Lib2']}
if mode in ('collision', 'casecollision', 'renamecollision'):
    second_root = {'collision': 'cura_demo.rb', 'casecollision': 'cura_DEMO.rb', 'renamecollision': 'cura_demo_legacy.rb'}[mode]
    manifest['plugins'].append({'id': 'cura-other', 'name': 'CURA other', 'version': 'new', 'file': 'missing-other.rbz', 'url': None, 'sha256': sha, 'roots': [second_root]})
(root/'assets/manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
snapshot = {'biblioteca_version': 'old', 'installed_at': 'old-date', 'item_labels': ['plugin CURA demo vold (SketchUp 2026)']*3, 'item_paths': [plugins+'/cura_demo', plugins+'/cura_demo.rb', plugins+'/cura_demo_legacy.rb']}
(root/'Application Support/CURA-Biblioteca/installed.json').write_text(json.dumps(snapshot, indent=2), encoding='utf-8')
PY
  cp "$case_root/Application Support/CURA-Biblioteca/installed.json" "$case_root/old-receipt.json"
  if [ "$mode" = download ]; then rm "$case_root/assets/plugin.rbz"; fi
  if [ "$mode" = fresh ]; then
    rm -rf -- "$plugins/cura_demo" "$plugins/cura_demo.rb" "$plugins/cura_demo_legacy.rb"
    rm "$case_root/Application Support/CURA-Biblioteca/installed.json"
  fi
  set +e
  (
    TMP_DIR="$case_root/runtime"
    APP_SUPPORT_DIR="$case_root/Application Support"
    CURA_STATE_DIR="$APP_SUPPORT_DIR/CURA-Biblioteca"
    SNAPSHOT_PATH="$CURA_STATE_DIR/installed.json"
    LOG_PATH="$case_root/install.log"
    LOCK_DIR="$CURA_STATE_DIR/.lock" LOCK_HELD=0
    FONTS_DIR="$case_root/fonts"
    PHOTOSHOP_DIR="$case_root/photoshop"
    PHOTOSHOP_BASE_DIR="$case_root/photoshop-base"
    RECOVERY_BASE="$case_root/recovery"
    BASE_URL="$case_root/assets"
    DEFAULT_BASE_URL="$BASE_URL"
    PLUGIN_TRANSACTIONS=() PLUGIN_TRANSACTION_COMMITTED=0 PLUGIN_ROLLBACK_FAILED=0
    trap 'rollback_plugin_transactions || true; if [ "$LOCK_HELD" = 1 ]; then rmdir "$LOCK_DIR"; fi' EXIT
    calls=0
    pgrep() {
      calls=$((calls+1))
      if [ "$mode" = early ]; then return 0; fi
      if [ "$mode" = late ] && [ "$calls" -ge 3 ]; then return 0; fi
      if [ "$mode" = reopened ] && [ "$injected" = 1 ]; then return 0; fi
      return 1
    }
    injected=0
    mv() {
      if [ "$mode" = cleanup ]; then
        case "$1" in */.cura-plugin-transaction.*) case "$2" in */.cura-plugin-committed.*) log 'injected cleanup'; return 1 ;; esac ;; esac
      fi
      if { [ "$mode" = receipt ] || [ "$mode" = reopened ]; } && [ "${3:-}" = "$SNAPSHOT_PATH" ]; then injected=1; log "injected $mode"; return 1; fi
      if { [ "$mode" = write ] || [ "$mode" = rollback ]; } && [ "$injected" = 0 ]; then
        case "$1" in */incoming/cura_demo.rb) injected=1; log "injected $mode"; return 1 ;; esac
      fi
      /bin/mv "$@"
    }
    cp() {
      if [ "$mode" = rollback ] && [ "$injected" = 1 ]; then
        local arg
        for arg in "$@"; do case "$arg" in */reference/cura_demo*) log "injected rollback restore failure"; return 1 ;; esac; done
      fi
      if [ "$mode" = copy ] && [ "$injected" = 0 ]; then
        case "${@: -1}" in */incoming/cura_demo.rb) injected=1; log "injected $mode"; return 1 ;; esac
      fi
      /bin/cp "$@"
    }
    set -Eeuo pipefail
    do_install
  ) > "$case_root/output.log" 2>&1
  rc=$?
  set -e
  if [ "$mode" = rollback ] || [ "$mode" = reopened ]; then
    local retained
    retained="$(find "$case_root" -name '.cura-plugin-transaction.*' -type d -print -quit)"
    [ -n "$retained" ] || fail 'incomplete rollback discarded its backup'
    [ "$(cat "$retained/reference/cura_demo.rb")" = 'old loader' ] || fail 'incomplete rollback backup invalid'
    cmp -s "$case_root/old-receipt.json" "$case_root/Application Support/CURA-Biblioteca/installed.json" || fail 'incomplete rollback rewrote old receipt'
    # Once IO is available, the retained real backup restores the profile.
    if [ "$mode" = reopened ]; then [ "$(cat "$plugins/cura_demo.rb")" = 'new loader' ] || fail 'rollback altered roots while SketchUp reopened'; fi
    recover_pending_plugin_transactions "$plugins" || fail 'retry of retained backup failed'
  fi
  if [ "$mode" = cleanup ]; then
    [ "$rc" -ne 0 ] || fail 'cleanup error not surfaced'
    [ "$(cat "$plugins/cura_demo.rb")" = 'new loader' ] || fail 'committed plugin was rolled back on cleanup failure'
    recover_pending_plugin_transactions "$plugins" "$case_root/Application Support/CURA-Biblioteca/installed.json" || fail 'confirmed journal cleanup retry failed'
    [ "$(cat "$plugins/cura_demo.rb")" = 'new loader' ] || fail 'confirmed journal was mistaken for pending rollback'
  fi
  [ "$(cat "$plugins/TT_Lib2/paid.rb")" = 'third party' ] || fail "$mode third party changed"
  [ "$(cat "$case_root/identity.json")" = 'identity outside Plugins' ] || fail "$mode identity changed"
  if [ "$mode" = success ] || [ "$mode" = fresh ] || [ "$mode" = cleanup ]; then
    [ "$rc" = 0 ] || [ "$mode" = cleanup ] || { cat "$case_root/output.log" "$TEST_ROOT/test.log"; fail 'success returned failure'; }
    [ "$(cat "$plugins/cura_demo.rb")" = 'new loader' ] || fail 'new loader not installed'
    [ ! -e "$plugins/cura_demo_legacy.rb" ] || fail 'renamed root was not removed transactionally'
    grep -q '"biblioteca_version": "new"' "$case_root/Application Support/CURA-Biblioteca/installed.json" || fail 'receipt did not commit'
    # No-op must complete even after the payload disappears, with no rewrite.
    rm "$case_root/assets/plugin.rbz"
    cp "$plugins/cura_demo.rb" "$case_root/loader-before"
    (
      TMP_DIR="$case_root/runtime" APP_SUPPORT_DIR="$case_root/Application Support" CURA_STATE_DIR="$case_root/Application Support/CURA-Biblioteca"
      SNAPSHOT_PATH="$CURA_STATE_DIR/installed.json" LOG_PATH="$case_root/install.log" LOCK_DIR="$CURA_STATE_DIR/.lock" LOCK_HELD=0
      PHOTOSHOP_DIR="$case_root/photoshop" BASE_URL="$case_root/assets"
      do_install
    ) > "$case_root/noop.log" 2>&1 || fail 'idempotent rerun failed'
    grep -q 'no-op' "$case_root/install.log" || fail 'rerun not no-op'
  else
    [ "$mode" = early ] || [ "$rc" -ne 0 ] || { cat "$case_root/output.log"; cat "$TEST_ROOT/test.log"; fail "$mode false success"; }
    [ "$(cat "$plugins/cura_demo.rb")" = 'old loader' ] || fail "$mode old loader lost"
    [ "$(cat "$plugins/cura_demo/core.rbe")" = 'old encoded' ] || fail "$mode old payload lost"
    [ "$(cat "$plugins/cura_demo_legacy.rb")" = 'old renamed root' ] || fail "$mode renamed old root lost"
    grep -q '"biblioteca_version": "old"' "$case_root/Application Support/CURA-Biblioteca/installed.json" || fail "$mode receipt falsely advanced"
    grep -q '/cura_demo.rb' "$case_root/Application Support/CURA-Biblioteca/installed.json" || fail "$mode old root receipt lost"
    if [ "$mode" = receipt ] || [ "$mode" = early ]; then
      cmp -s "$case_root/old-receipt.json" "$case_root/Application Support/CURA-Biblioteca/installed.json" || fail "$mode old receipt changed"
    fi
  fi
  case "$mode" in copy|write|receipt|rollback|reopened|cleanup) grep -q "injected $mode" "$case_root/install.log" || fail "$mode injection not reached" ;; esac
  [ -z "$(find "$case_root" -name '.cura-plugin-transaction.*' -print -quit)" ] || fail "$mode left transaction after verified rollback/commit"
  printf 'PASS macOS plugin: %s\n' "$mode"
}
for mode in download hash extract copy write receipt rollback reopened early late collision casecollision renamecollision success fresh cleanup; do run_case "$mode"; done

# Also validate the actual checked-in payload, not only synthetic archives.
prepare_plugin_payload "$(dirname "$SCRIPT")/../payload/cura-ferramentas.rbz" 'cura_ferramentas,cura_ferramentas.rb' "$TEST_ROOT/current-payload"
printf 'PASS macOS plugin: checked-in payload structure\n'

BASE_URL='http://127.0.0.1:9'
reject fetch_asset_optional 'plugin.rbz' "$TEST_ROOT/refused-http" 2> "$TEST_ROOT/http-refused.log"
grep -qi 'protocol.*http.*disabled' "$TEST_ROOT/http-refused.log" || fail 'curl did not reject HTTP by protocol policy'
printf 'PASS macOS plugin: HTTP refused before network request\n'
