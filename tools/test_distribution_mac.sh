#!/bin/bash
# Real install/uninstall functions, only owned temp profiles. No HOME override,
# native SketchUp, launchd, production cache, or network.
set -Eeuo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d /private/tmp/cura-distribution-test.XXXXXX)"
trap 'chmod -R u+rwX "$ROOT"; rm -rf -- "$ROOT"' EXIT
awk '/^is_local_base\(\)/ {p=1} /^do_limpar\(\)/ {exit} p {print}' "$REPO/scripts/install.sh" > "$ROOT/functions.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@"; then fail "accepted: $*"; fi; }
run_flow() {
  local case_root="$1" action="$2" rc=0
  set +e
  (
    set -Eeuo pipefail
    TMP_DIR="$case_root/runtime-$action"
    APP_SUPPORT_DIR="$case_root/Profile With Spaces/Application Support"
    CURA_STATE_DIR="$APP_SUPPORT_DIR/CURA-Biblioteca"
    SNAPSHOT_PATH="$CURA_STATE_DIR/installed.json"
    LOG_PATH="$case_root/$action.log"
    LOCK_DIR="$CURA_STATE_DIR/.lock" LOCK_HELD=0
    FONTS_DIR="$case_root/fonts" PHOTOSHOP_DIR="$case_root/photoshop" PHOTOSHOP_BASE_DIR="$case_root/photoshop-base"
    RECOVERY_BASE="$case_root/recovery" BASE_URL="$case_root/assets" DEFAULT_BASE_URL="$case_root/assets"
    UPDATER_PLIST="$case_root/unused.plist" US=$'\x1f'
    QUIET=1 C_VERDE='' C_RESET='' C_BOLD='' C_ERRO='' SEPARADOR='' BETA_NOTE=''
    export CURA_BASE_URL="$BASE_URL"
    mkdir -p "$TMP_DIR" "$CURA_STATE_DIR"
    source "$ROOT/functions.sh"
    log() { printf '%s\n' "$*" >> "$LOG_PATH"; }
    err() { log "erro: $*"; }
    warn() { log "$*"; }
    say() { log "$*"; }
    banner() { :; }
    log_header() { :; }
    register_updater() { :; }
    confirm_biblioteca_uninstall() { return 0; } # UI only
    pgrep() { return 1; } # these profile roots are never loaded in any app
    trap 'rollback_plugin_transactions || true; if [ "$LOCK_HELD" = 1 ]; then rmdir "$LOCK_DIR"; fi' EXIT
    if [ "$action" = uninstall ]; then do_uninstall; else do_install; fi
  ) > "$case_root/$action-output.log" 2>&1
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$case_root/$action-exit.txt"
}

for mode in warehouse warehouse-current warehouse-unowned fresh biblioteca legacy unowned invalid schema incoming-warehouse mixed uninstall-warehouse uninstall-biblioteca uninstall-invalid uninstall-mixed; do
  case_root="$ROOT/$mode"
  mkdir -p "$case_root"
  python3 - "$case_root" "$mode" <<'PY'
from pathlib import Path
import hashlib,json,sys,zipfile
root,mode=Path(sys.argv[1]),sys.argv[2]
app=root/'Profile With Spaces/Application Support'
versions=[2025,2026] if mode in ('mixed','uninstall-mixed') else [2026]
paths=[];labels=[];preserved=[]
for year in versions:
 plugins=app/f'SketchUp {year}/SketchUp/Plugins'
 module=plugins/'cura_ferramentas';module.mkdir(parents=True)
 (module/'core.rbe').write_bytes(f'old code {year}'.encode())
 (plugins/'cura_ferramentas.rb').write_bytes(f'old loader {year}'.encode())
 channel='warehouse' if mode.startswith('warehouse') or mode=='uninstall-warehouse' or (mode in ('mixed','uninstall-mixed') and year==2025) else 'biblioteca'
 marker={'schema':1,'product':'cura-ferramentas','channel':channel}
 if mode in ('invalid','uninstall-invalid'): (module/'distribution.json').write_text('{corrupt',encoding='utf-8')
 elif mode=='schema': (module/'distribution.json').write_text(json.dumps({**marker,'schema':99}),encoding='utf-8')
 elif mode not in ('legacy','unowned'): (module/'distribution.json').write_text(json.dumps(marker,indent=2),encoding='utf-8')
 (plugins/'TT_Lib2').mkdir();(plugins/'TT_Lib2/paid.rb').write_bytes(b'paid third party')
 (plugins/'cura_other_product').mkdir();(plugins/'cura_other_product/state.bin').write_bytes(b'other product unchanged')
 for p in [plugins/'TT_Lib2/paid.rb',plugins/'cura_other_product/state.bin']:
  preserved.append({'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
 if mode not in ('unowned','warehouse-unowned','fresh'):
  for p in [module,plugins/'cura_ferramentas.rb']: paths.append(str(p));labels.append(f'plugin cura | ferramentas v1.0.1 (SketchUp {year})')
if mode=='fresh':
 import shutil
 shutil.rmtree(module);(plugins/'cura_ferramentas.rb').unlink()
if mode.startswith('uninstall-'):(root/'unused.plist').write_bytes(b'fixture scheduler')
identity=app/'CURA/Ferramentas/access-state.json';identity.parent.mkdir(parents=True);identity.write_bytes(b'{"uuid":"external-identity-unchanged"}')
preserved.append({'path':str(identity),'sha256':hashlib.sha256(identity.read_bytes()).hexdigest()})
state=app/'CURA-Biblioteca';state.mkdir(parents=True)
if mode not in ('unowned','warehouse-unowned','fresh'):(state/'installed.json').write_text(json.dumps({'biblioteca_version':'10.3.0' if mode=='warehouse-current' else '10.2.0','installed_at':'old','item_paths':paths,'item_labels':labels},indent=2),encoding='utf-8')
assets=root/'assets';assets.mkdir()
with zipfile.ZipFile(assets/'cura-ferramentas.rbz','w') as z:
 z.writestr('cura_ferramentas/core.rbe',b'new protected code')
 z.writestr('cura_ferramentas.rb',b'new loader')
 z.writestr('cura_ferramentas/distribution.json',json.dumps({'schema':1,'product':'cura-ferramentas','channel':'warehouse' if mode=='incoming-warehouse' else 'biblioteca'}))
sha=hashlib.sha256((assets/'cura-ferramentas.rbz').read_bytes()).hexdigest()
manifest={'schema':1,'biblioteca_version':'10.3.0','min_sketchup':2018,'plugins':[{'id':'cura-ferramentas','name':'cura | ferramentas','version':'1.1.0','file':'cura-ferramentas.rbz','url':None,'sha256':sha,'roots':['cura_ferramentas','cura_ferramentas.rb']}],'fonts':None,'photoshop':None,'sketchup_template':None,'remove':['TT_Lib2']}
(assets/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
(root/'preserved.json').write_text(json.dumps(preserved),encoding='utf-8')
PY
  case "$mode" in uninstall-*) action=uninstall ;; *) action=install ;; esac
  run_flow "$case_root" "$action"
  python3 - "$case_root" "$mode" "$action" <<'PY'
from pathlib import Path
import hashlib,json,sys
root,mode,action=Path(sys.argv[1]),sys.argv[2],sys.argv[3]
app=root/'Profile With Spaces/Application Support'
rc=int((root/f'{action}-exit.txt').read_text())
expected=2 if mode in ('unowned','invalid','schema','incoming-warehouse','uninstall-invalid') else 0
assert rc==expected,(mode,rc,(root/f'{action}-output.log').read_text())
for item in json.loads((root/'preserved.json').read_text()):assert hashlib.sha256(Path(item['path']).read_bytes()).hexdigest()==item['sha256'],item
for year in ([2025,2026] if mode in ('mixed','uninstall-mixed') else [2026]):
 plugins=app/f'SketchUp {year}/SketchUp/Plugins';module=plugins/'cura_ferramentas'
 protected=mode.startswith('warehouse') or mode in ('unowned','invalid','schema','incoming-warehouse','uninstall-warehouse','uninstall-invalid') or (mode in ('mixed','uninstall-mixed') and year==2025)
 if protected:
  assert (module/'core.rbe').read_bytes()==f'old code {year}'.encode(),(mode,year)
  assert (plugins/'cura_ferramentas.rb').read_bytes()==f'old loader {year}'.encode()
 elif action=='uninstall':assert not module.exists() and not (plugins/'cura_ferramentas.rb').exists()
 else:
  assert (module/'core.rbe').read_bytes()==b'new protected code'
  assert json.loads((module/'distribution.json').read_text())['channel']=='biblioteca'
snapshot=app/'CURA-Biblioteca/installed.json'
if action=='install':
 receipt=json.loads(snapshot.read_text()) if snapshot.exists() else None
 if expected==0:
  assert receipt['biblioteca_version']=='10.3.0'
  if mode.startswith('warehouse'):assert receipt['item_paths']==[]
  if mode=='mixed':assert len(receipt['item_paths'])==2 and all('SketchUp 2026/' in p for p in receipt['item_paths'])
 elif receipt is not None:
  assert receipt['biblioteca_version']==('' if mode=='unowned' else '10.2.0')
  if mode=='unowned':assert receipt['item_paths']==[]
elif expected==0:
 assert not snapshot.exists()
 assert not (root/'unused.plist').exists(), 'Biblioteca scheduler retained after uninstall'
else:assert snapshot.exists()
PY
  if [[ "$mode" = warehouse* ]]; then
    cp "$case_root/Profile With Spaces/Application Support/CURA-Biblioteca/installed.json" "$case_root/receipt-before-noop.json"
    rm "$case_root/assets/cura-ferramentas.rbz"
    run_flow "$case_root" rerun
    [ "$(cat "$case_root/rerun-exit.txt")" = 0 ] || fail "$mode no-op returned failure"
    grep -q 'no-op:' "$case_root/rerun.log" || fail "$mode did not no-op"
    cmp -s "$case_root/receipt-before-noop.json" "$case_root/Profile With Spaces/Application Support/CURA-Biblioteca/installed.json" || fail "$mode no-op changed receipt"
  fi
  printf 'PASS macOS channel: %s\n' "$mode"
done

# Parser contract, including missing/unreadable metadata and whitespace in strings.
TMP_DIR="$ROOT/parse-runtime";mkdir -p "$TMP_DIR"
source "$ROOT/functions.sh"
LOG_PATH="$ROOT/parser.log";log() { printf '%s\n' "$*" >> "$LOG_PATH"; };err() { log "$*"; };pgrep() { return 1; }
parser_plugins="$ROOT/parser/SketchUp/Plugins";mkdir -p "$parser_plugins/cura_ferramentas"
marker="$parser_plugins/cura_ferramentas/distribution.json"
for text in $'{\f"schema":1,"product":"cura-ferramentas","channel":"biblioteca"}' '{"schema":1,"product":"cura-ferramentas","channel":"other"}' '{"schema":true,"product":"cura-ferramentas","channel":"biblioteca"}' '{"schema":1.0,"product":"cura-ferramentas","channel":"biblioteca"}' '{"schema":1,"product":"cura-ferramentas","channel":"warehouse","channel":"biblioteca"}' '{"schema":1,"product":"other","channel":"biblioteca"}' '{"schema":1,"product":"cura-ferramentas","channel":"biblio teca"}' '{"schema":1,"product":"cura-ferramentas","channel":"biblioteca","extra":1}' '{"schema":1,"schema":1,"channel":"biblioteca"}' 'null'; do
  printf '%s' "$text" > "$marker"
  [ "$(ferramentas_channel "$parser_plugins")" = invalid ] || fail "accepted invalid metadata: $text"
done
printf '{"channel":"warehouse", "product":"cura-ferramentas", "schema":1}' > "$marker"
[ "$(ferramentas_channel "$parser_plugins")" = warehouse ] || fail 'valid reordered Warehouse marker'
chmod 000 "$marker"
[ "$(ferramentas_channel "$parser_plugins")" = invalid ] || fail 'unreadable marker authorized'
chmod 600 "$marker"
rm "$marker";ln -s "$ROOT/no-such-file" "$marker"
[ "$(ferramentas_channel "$parser_plugins")" = invalid ] || fail 'dangling marker symlink authorized'
rm "$marker"

# An old Library journal must never roll back over newly installed Warehouse.
plugins="$ROOT/pending/SketchUp/Plugins";stage="$ROOT/pending-stage"
mkdir -p "$plugins/cura_ferramentas" "$stage/cura_ferramentas"
printf 'old' > "$plugins/cura_ferramentas/core.rbe";printf 'old loader' > "$plugins/cura_ferramentas.rb"
printf '{"schema":1,"product":"cura-ferramentas","channel":"biblioteca"}' > "$plugins/cura_ferramentas/distribution.json"
printf 'new' > "$stage/cura_ferramentas/core.rbe";printf 'new loader' > "$stage/cura_ferramentas.rb"
cp "$plugins/cura_ferramentas/distribution.json" "$stage/cura_ferramentas/distribution.json"
install_plugin_transaction "$stage" "$plugins" 'cura_ferramentas,cura_ferramentas.rb'
printf '{"schema":1,"product":"cura-ferramentas","channel":"warehouse"}' > "$plugins/cura_ferramentas/distribution.json"
reject rollback_plugin_transactions
[ "$(cat "$plugins/cura_ferramentas/core.rbe")" = new ] || fail 'rollback changed Warehouse'
txn="${PLUGIN_TRANSACTIONS[0]}"
recover_pending_plugin_transactions "$plugins"
[ -d "$txn" ] || fail 'protected backup was discarded'
printf 'cura_other_product.rb\n' >> "$txn/roots"
reject recover_pending_plugin_transactions "$plugins"
[ "$(cat "$plugins/cura_ferramentas/core.rbe")" = new ] || fail 'mixed pending journal changed Warehouse'
# A channel switch during staging must be revalidated before any replacement.
race_plugins="$ROOT/race/SketchUp/Plugins";mkdir -p "$race_plugins/cura_ferramentas"
printf 'old race code' > "$race_plugins/cura_ferramentas/core.rbe"
printf 'old race loader' > "$race_plugins/cura_ferramentas.rb"
printf '{"schema":1,"product":"cura-ferramentas","channel":"biblioteca"}' > "$race_plugins/cura_ferramentas/distribution.json"
PLUGIN_TRANSACTIONS=()
cp() {
  command cp "$@" || return
  local arg
  for arg in "$@"; do
    if [ "$arg" = "$stage/cura_ferramentas" ]; then
      printf '{"schema":1,"product":"cura-ferramentas","channel":"warehouse"}' > "$race_plugins/cura_ferramentas/distribution.json"
    fi
  done
}
reject install_plugin_transaction "$stage" "$race_plugins" 'cura_ferramentas,cura_ferramentas.rb'
unset -f cp
[ "$(cat "$race_plugins/cura_ferramentas/core.rbe")" = 'old race code' ] || fail 'staging race overwrote Warehouse'
[ "$(cat "$race_plugins/cura_ferramentas.rb")" = 'old race loader' ] || fail 'staging race overwrote Warehouse loader'
is_ferramentas_root cura_FERRAMENTAS.RB || fail 'case alias bypassed ownership'
ferramentas_path_directory "$race_plugins/cura_FERRAMENTAS/core.rbe" || fail 'case alias receipt bypassed ownership'
[ "$FERRAMENTAS_PATH_DIR" = "$race_plugins" ] || fail 'case alias resolved wrong Plugins'
printf 'PASS macOS channel: strict parser, unreadable metadata, pending rollback/recovery, staging race, case aliases\n'
