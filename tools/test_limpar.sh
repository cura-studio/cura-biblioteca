#!/bin/bash
# Checagem do "limpar sketchup" (install.sh --limpar) num HOME isolado.
# Roda: bash tools/test_limpar.sh
#
# Verifica as tres coisas que nao podem quebrar nunca:
#   1. tudo que comeca com cura_ FICA;
#   2. todo o resto SAI, em todas as versoes do SketchUp;
#   3. nada e apagado — vai pra Documentos/cura-plugins-removidos/<data>/.
# Mais duas, dos fixes de auditoria:
#   4. item que NAO conseguiu sair e reportado, e a saida e nao-zero;
#   5. com o SketchUp aberto a limpeza nao mexe em nada.
set -Eeuo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/install.sh"
command -v expect >/dev/null || { echo "precisa do expect (vem no macOS)"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cura-limpar-test.XXXXXX")"
T2="$(mktemp -d "${TMPDIR:-/tmp}/cura-limpar-test2.XXXXXX")"
T3="$(mktemp -d "${TMPDIR:-/tmp}/cura-limpar-test3.XXXXXX")"
SHIM="$(mktemp -d "${TMPDIR:-/tmp}/cura-limpar-shim.XXXXXX")"
trap 'chmod -R u+w "$T" "$T2" "$T3" 2>/dev/null || true; rm -rf "$T" "$T2" "$T3" "$SHIM"' EXIT

# o do_limpar agora espera o SketchUp fechar antes de mexer no Plugins/ (mover
# pasta de plugin com o app aberto quebra a sessao em curso). o pgrep e o da
# maquina REAL — HOME isolado nao isola processo —, entao simulamos os dois
# estados com um shim no PATH: assim o teste roda igual com o SketchUp aberto
# ou fechado na maquina de quem esta testando.
mkdir -p "$SHIM/fechado" "$SHIM/aberto"
cat > "$SHIM/fechado/pgrep" <<'SHIMEOF'
#!/bin/bash
for a in "$@"; do [ "$a" = "SketchUp" ] && exit 1; done
exec /usr/bin/pgrep "$@"
SHIMEOF
cat > "$SHIM/aberto/pgrep" <<'SHIMEOF'
#!/bin/bash
for a in "$@"; do [ "$a" = "SketchUp" ] && { echo 12345; exit 0; }; done
exec /usr/bin/pgrep "$@"
SHIMEOF
chmod +x "$SHIM/fechado/pgrep" "$SHIM/aberto/pgrep"

falhas=0
check() {
  if [ "$2" = "existe" ]; then
    [ -e "$1" ] || { echo "FALHOU: sumiu $1"; falhas=$((falhas + 1)); }
  else
    [ -e "$1" ] && { echo "FALHOU: continua la $1"; falhas=$((falhas + 1)); }
  fi
  return 0
}

# roda o --limpar (SketchUp fechado) respondendo "s"; imprime o exit code se != 0.
run_limpar() {
  local home="$1"
  HOME="$home" PATH="$SHIM/fechado:$PATH" expect -c "
    set timeout 60
    spawn bash $SCRIPT --limpar
    expect \"confirma?\"
    send \"s\r\"
    expect eof
    catch wait result
    exit [lindex \$result 3]
  " > /dev/null 2>&1 || printf '%s' "$?"
}

# ---------------------------------------------------------------------------
# cenario 1: limpeza normal
# ---------------------------------------------------------------------------
P23="$T/Library/Application Support/SketchUp 2023/SketchUp/Plugins"
P24="$T/Library/Application Support/SketchUp 2024/SketchUp/Plugins"
mkdir -p "$P23" "$P24" "$T/Documents"
mkdir -p "$P23/cura_ferramentas" "$P23/TT_Lib2" "$P23/SolidInspector2" "$P23/su_sandbox"
: > "$P23/tt_cleanup.rb"
: > "$P23/su_sandbox.rb"
mkdir -p "$P24/Skimp" "$P24/su_dynamiccomponents"
: > "$P24/cura_ferramentas.rb"

rc="$(run_limpar "$T")"
[ -z "$rc" ] || { echo "FALHOU: limpeza sem erro deveria sair 0, saiu $rc"; falhas=$((falhas + 1)); }

# 1. o cura fica, e os nativos da Trimble tambem
check "$P23/cura_ferramentas" existe
check "$P24/cura_ferramentas.rb" existe
check "$P23/su_sandbox" existe
check "$P23/su_sandbox.rb" existe
check "$P24/su_dynamiccomponents" existe
# 2. o resto sai, nas duas versoes
check "$P23/TT_Lib2" sumiu
check "$P23/SolidInspector2" sumiu
check "$P23/tt_cleanup.rb" sumiu
check "$P24/Skimp" sumiu
# 3. tudo que saiu esta recuperavel
for nome in "SketchUp 2023/TT_Lib2" "SketchUp 2023/SolidInspector2" \
            "SketchUp 2023/tt_cleanup.rb" "SketchUp 2024/Skimp"; do
  find "$T/Documents/cura-plugins-removidos" -path "*/$nome" | grep -q . \
    || { echo "FALHOU: nao foi pra recuperacao: $nome"; falhas=$((falhas + 1)); }
done

# ---------------------------------------------------------------------------
# cenario 4: mv que falha NAO pode virar "pronto"
# Plugins/ sem permissao de escrita = mv nao consegue tirar nada de la.
# ---------------------------------------------------------------------------
Q23="$T2/Library/Application Support/SketchUp 2023/SketchUp/Plugins"
mkdir -p "$Q23" "$T2/Documents"
mkdir -p "$Q23/TT_Lib2"
chmod 555 "$Q23"

rc2="$(run_limpar "$T2")"
[ -n "$rc2" ] && [ "$rc2" != "0" ] \
  || { echo "FALHOU: limpeza com item preso deveria sair nao-zero, saiu ${rc2:-0}"; falhas=$((falhas + 1)); }
check "$Q23/TT_Lib2" existe
chmod 755 "$Q23"

# ---------------------------------------------------------------------------
# cenario 5: SketchUp aberto — pede pra fechar e nao move nada
# (ctrl+D no prompt = "nao deu pra confirmar", aborta sem mexer)
# ---------------------------------------------------------------------------
R23="$T3/Library/Application Support/SketchUp 2023/SketchUp/Plugins"
mkdir -p "$R23" "$T3/Documents"
mkdir -p "$R23/TT_Lib2"

HOME="$T3" PATH="$SHIM/aberto:$PATH" expect -c "
  set timeout 30
  spawn bash $SCRIPT --limpar
  expect {
    \"SketchUp está aberto\" { send \"\004\" }
    timeout { exit 9 }
  }
  expect eof
" > /dev/null 2>&1 || true
check "$R23/TT_Lib2" existe
if [ -d "$T3/Documents/cura-plugins-removidos" ]; then
  echo "FALHOU: moveu algo com o SketchUp aberto"
  falhas=$((falhas + 1))
fi

if [ "$falhas" -eq 0 ]; then
  echo "limpar sketchup: OK (cura preservado, terceiros movidos, nada apagado, falha de mv reportada, respeita SketchUp aberto)"
else
  echo "limpar sketchup: $falhas falha(s)"
  exit 1
fi
