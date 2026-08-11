#!/usr/bin/env python3
"""Monta payload/photoshop.zip: o Cura Upscaler + o atalho F2 pro Photoshop.

O que vai no zip:
  1. CuraUpscaler.jsx — copia byte a byte do .jsx de origem (o original NUNCA e
     tocado; este script so le);
  2. instalar-cura-upscaler.jsx — o bootstrap que o aluno roda uma vez em
     Arquivo > Scripts > Procurar (fonte em tools/instalar-cura-upscaler.jsx);
  3. cura-upscaler.atn — o action set "cura" com a action "Cura Upscaler" na
     tecla F2. UM SO arquivo, mac e Windows.

Alem do zip, grava tambem o CuraUpscaler.jsx SOLTO ao lado dele: ele vai como
asset separado da release, pro link de resgate manual da pagina do curso (aluno
que so quer o .jsx, sem instalador).

Uso:
    python3 tools/make_photoshop.py <caminho-da-fonte-jsx> [--out payload/photoshop.zip]

Stdlib puro. Depois de rodar, rode tools/make_manifest.py.

ponytail: o gerador de .atn vive aqui dentro em vez de virar modulo — e um
formato so, escrito num lugar so, e ler o layout binario junto de quem o
escreve vale mais do que a separacao.
"""
import argparse, os, struct, sys, zipfile

# ---------------------------------------------------------------------------
# Destino final dos arquivos em cada plataforma (e pra la que o instalador
# extrai). Tem que bater com PHOTOSHOP_DIR do install.sh e $script:PhotoshopDir
# do install.ps1 — se um mudar, o outro e este arquivo mudam junto.
#
# Sao as duas pastas "de todo mundo" do sistema: existem em qualquer maquina,
# sao gravaveis sem admin e sao IGUAIS pra todo aluno — por isso um .atn
# estatico com caminho cravado serve pro parque inteiro.
#
# Barra normal no caminho do Windows de proposito: dentro da string JS do .atn
# a contrabarra seria escape, e o File() do ExtendScript aceita "C:/..." no
# Windows sem ressalva.
# ---------------------------------------------------------------------------
MAC_DIR = "/Users/Shared/CURA-Biblioteca/photoshop"
WIN_DIR = "C:/Users/Public/CURA-Biblioteca/photoshop"

SCRIPT_NAME = "CuraUpscaler.jsx"
ATN_NAME = "cura-upscaler.atn"
SET_NAME = "cura"
ACTION_NAME = "Cura Upscaler"
FUNCTION_KEY_F2 = 2   # int16: 0 = nenhuma, N = FN

BOOTSTRAP_NAME = "instalar-cura-upscaler.jsx"
BOOTSTRAP_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             BOOTSTRAP_NAME)

# data fixa no zip: rodar de novo sem mudar conteudo tem que dar o MESMO
# sha256, senao todo build sujaria o manifest.json a toa.
ZIP_DATE = (2026, 1, 1, 0, 0, 0)


# ---------------------------------------------------------------------------
# Primitivas do .atn (tudo big-endian)
#   ustr  : int32 n_unidades_utf16 (CONTA o NUL final) + UTF-16BE
#   bstr  : int32 n_bytes + ASCII, sem NUL          (evento e rotulo)
#   idstr : int32 len; len 0 => charID de 4 bytes; senao stringID de len bytes
#
# bstr e idstr NAO sao a mesma coisa: um rotulo de 4 letras em idstr viraria
# len=0, que no lugar de bstr significa string vazia.
# ---------------------------------------------------------------------------
def i32(v):
    return struct.pack(">i", v)


def ustr(s):
    return i32(len(s) + 1) + (s + "\0").encode("utf-16-be")


def bstr(s):
    b = s.encode("latin-1")
    return i32(len(b)) + b


def idstr(s):
    b = s.encode("latin-1")
    return i32(0) + b if len(b) == 4 else i32(len(b)) + b


# ---------------------------------------------------------------------------
# .atn versao 16 — layout, na ordem em que sai no arquivo:
#
#   int32 16 | ustr nome_do_set | u8 expandido | int32 n_actions
#   por action:
#     i16 tecla_de_funcao | u8 shift | u8 command | i16 cor
#     ustr nome | u8 expandida | int32 n_comandos
#     por comando:
#       u8 expandido | u8 habilitado | u8 com_dialogo | u8 modo_dialogo
#       'TEXT' + bstr stringID_do_evento   (ou 'long' + charID de 4 bytes)
#       bstr rotulo_no_painel
#       int32 0 = sem descriptor | -1 = descriptor logo a seguir
#       descriptor: ustr nome | idstr classe | int32 n |
#                   (idstr chave + OSType de 4 bytes + valor)*
#
# O descriptor aqui NAO leva o int32 de versao que ele leva em
# ActionDescriptor.toStream(). Layout conferido lendo os 9 sets que o proprio
# Photoshop 2026 instala em Presets/Actions (parser em tools/_atn-research/
# atnparse.py): os 9 fecham byte a byte, e o nosso tambem.
# ---------------------------------------------------------------------------
def comando_scripts(codigo_js):
    """O comando que roda JS: evento 'AdobeScriptAutomation Scripts'.

    O codigo vai INLINE, na chave 'jsTx' (stringID javaScriptText). A outra
    forma — 'jsCt' (javaScript) apontando pro ARQUIVO — exige um alias binario
    do sistema operacional: no Mac o Photoshop so aceita OSType 'alis' (o
    AliasRecord do macOS, que carrega nome de volume e ids de arquivo da
    maquina que gravou) e no Windows 'Pth ' (UTF-16LE). Sao dois blobs
    diferentes, nenhum dos dois legivel na outra plataforma, e o do Mac so
    resolve o caminho de verdade em alguns arranjos de flag — medido a fundo na
    pesquisa (tools/_atn-research/).

    Com 'jsTx' o binario e IDENTICO nas duas plataformas: um .atn so pro parque
    inteiro, e o codigo inline e um lancador de 3 linhas que abre o .jsx de
    verdade da pasta compartilhada. Assim atualizar o Upscaler = trocar o .jsx
    (o instalador ja faz), sem nunca mais mexer no atalho do aluno.

    modo_dialogo 2 = "None": roda sem dialogo e sem deixar o aluno ligar um.
    """
    desc = (
        ustr("")                                  # nome do descriptor
        + idstr("null")                           # classe
        + i32(1)                                  # 1 chave
        + idstr("jsTx") + b"TEXT" + ustr(codigo_js)
    )
    return (
        bytes([0, 1, 0, 2])                       # expandido, habilitado, sem dialogo, modo 2
        + b"TEXT" + bstr("AdobeScriptAutomation Scripts")
        + bstr(ACTION_NAME)                       # rotulo do passo no painel Ações
        + i32(-1)                                 # tem descriptor
        + desc
    )


def carregador():
    """O JS que vai dentro do .atn: abre o .jsx da pasta compartilhada.

    Tenta o caminho do Mac e depois o do Windows — o da outra plataforma
    simplesmente nao existe (no Mac, "C:/..." vira caminho relativo que nunca
    resolve; no Windows, "/Users/Shared/..." cai na raiz do drive atual), entao
    o mesmo binario serve nas duas. Com aviso em portugues quando o arquivo nao
    esta la: sem isso o aluno que apagou a pasta recebe um erro cru do
    ExtendScript.
    """
    return (
        'var f = new File("%s/%s"); '
        'if (!f.exists) { f = new File("%s/%s"); } '
        'if (f.exists) { $.evalFile(f); } '
        'else { alert("Cura Upscaler não encontrado. '
        'rode o instalador da biblioteca cura e ative de novo."); }'
    ) % (MAC_DIR, SCRIPT_NAME, WIN_DIR, SCRIPT_NAME)


def montar_atn():
    comando = comando_scripts(carregador())
    action = (
        struct.pack(">hBBh", FUNCTION_KEY_F2, 0, 0, 0)   # F2, sem shift, sem command, sem cor
        + ustr(ACTION_NAME)
        + bytes([0])                                     # nao expandida no painel
        + i32(1) + comando
    )
    return i32(16) + ustr(SET_NAME) + bytes([1]) + i32(1) + action


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fonte", help="caminho do .jsx de origem (so leitura)")
    ap.add_argument("--out", default="payload/photoshop.zip", help="zip de saida")
    args = ap.parse_args()

    if not os.path.isfile(args.fonte):
        sys.exit(f"fonte nao encontrada: {args.fonte}")
    if not os.path.isfile(BOOTSTRAP_SRC):
        sys.exit(f"bootstrap nao encontrado: {BOOTSTRAP_SRC}")

    with open(args.fonte, "rb") as fh:
        script = fh.read()
    # guarda barata: apontar pro .jsx errado geraria um zip que so quebra na
    # mao do aluno, meses depois.
    if b"#target photoshop" not in script[:2000]:
        sys.exit(f"{args.fonte} nao parece script de Photoshop (sem '#target photoshop')")
    with open(BOOTSTRAP_SRC, "rb") as fh:
        bootstrap = fh.read()

    arquivos = [
        (SCRIPT_NAME, script),
        (BOOTSTRAP_NAME, bootstrap),
        (ATN_NAME, montar_atn()),
    ]

    out_dir = os.path.dirname(args.out) or "."
    os.makedirs(out_dir, exist_ok=True)
    with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED) as z:
        for nome, dados in arquivos:
            info = zipfile.ZipInfo(nome, date_time=ZIP_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, dados)

    # copia solta do .jsx, ao lado do zip: e o asset avulso da release.
    solto = os.path.join(out_dir, SCRIPT_NAME)
    with open(solto, "wb") as fh:
        fh.write(script)

    print(f"\n== {args.out}")
    for nome, dados in arquivos:
        print(f"  {nome}: {len(dados)} bytes")
    print(f"{args.out}: {len(arquivos)} arquivos, {os.path.getsize(args.out)} bytes")
    print(f"{solto}: {len(script)} bytes (asset avulso da release)")
    print(f"  action set {SET_NAME!r} / action {ACTION_NAME!r} / tecla F{FUNCTION_KEY_F2}")
    print(f"  mac: {MAC_DIR}/{SCRIPT_NAME}")
    print(f"  win: {WIN_DIR}/{SCRIPT_NAME}")
    print("\nagora rode: python3 tools/make_manifest.py")


if __name__ == "__main__":
    main()
