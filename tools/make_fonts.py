#!/usr/bin/env python3
"""Monta os zips de fontes a partir das pastas de fontes soltas.

O que faz:
  1. cura por FAMILIA TIPOGRAFICA declarada dentro do arquivo (name table),
     nao pelo nome do arquivo — nome de arquivo mente, name table nao;
  2. junta cada familia num unico .ttc (108 faces viraram 5 arquivos), com a
     face Regular/Roman em primeiro — a face 0 e a cara da colecao no Font
     Book, na lista de fontes do Windows e nos previewers;
  3. gera names.json com o nome de registro do Windows de cada arquivo — o
     Windows exige TODAS as faces da colecao separadas por " & ", senao so a
     primeira aparece no Photoshop/InDesign/Illustrator;
  4. empacota tudo (classicas + familias LIVRES do Google/OFL) num zip so, em
     payload/fonts.zip, junto das licencas OFL — e o DEFAULT, decidido com o
     Joao em 06/08/2026: o aluno recebe um pacote de fontes, nao dois;
  5. so quando --out-classicas e passado, separa: --out fica so com as livres e
     as CLASSICAS (Adobe/Linotype, licenca comprada) vao pro zip de
     --out-classicas, que NAO sobe pro GitHub (o repo e publico e o asset de
     release baixa sem autenticacao) — entrega pelo canal privado das
     texturas/HDRIs. Modo pendente da decisao de licenciamento do Joao.

Uso:
    # default: pacote completo num zip so
    python3 tools/make_fonts.py <pasta-classicas> --google <pasta-google> \
        [--out payload/fonts.zip]

    # opcional: split publico (livres) / privado (classicas)
    python3 tools/make_fonts.py <pasta-classicas> --google <pasta-google> \
        --out payload/fonts-livres.zip --out-classicas ~/entrega/fontes-classicas.zip

Precisa de fontTools (dependencia SO de build, nunca de instalacao):
    pip install fonttools

ponytail: a curadoria e uma allowlist fixa aqui embaixo em vez de config
externa — sao 5 familias que mudam uma vez por ano. Se virar dezenas, ai sim
vira um .json ao lado.
"""
import argparse, collections, json, os, re, sys, tempfile, zipfile

try:
    from fontTools.ttLib import TTFont, TTCollection
except ImportError:
    sys.exit("falta fontTools: pip install fonttools")

# familia tipografica (nameID 16, com fallback pro 1) -> nome do .ttc de saida.
# fora dessa lista nada entra. decisoes tomadas com o Joao em 06/08/2026:
#   - "Futura * BT" fica FORA: fundicao Bitstream/Corel, fora da licenca Adobe;
#   - "Helvetica" pura fica FORA: a pasta so tem knockoff ALLTYPE, sem Regular;
#   - Frutiger nao existe na pasta.
ALLOWLIST = {
    "Helvetica Neue LT Std": "helvetica-neue",
    "Futura Std": "futura",
    "ITC Avant Garde Gothic Std": "avant-garde",
    "Minion Pro": "minion",
    "Minion Std": "minion",
    "Adobe Garamond Pro": "garamond",
}


def names(path):
    """nameID -> str, preferindo o registro Windows/en-US."""
    f = TTFont(path, fontNumber=0, lazy=True)
    out = {}
    for r in f["name"].names:
        try:
            v = r.toUnicode()
        except Exception:
            continue
        if r.nameID not in out or (r.platformID == 3 and r.langID == 0x409):
            out[r.nameID] = v
    f.close()
    return out


def copiar(origem, destino):
    with open(origem, "rb") as fi, open(destino, "wb") as fo:
        fo.write(fi.read())


def truetype(f):
    """True se as outlines sao glyf (TrueType); False se CFF (OpenType).

    O sufixo do nome de registro do Windows sai DAQUI, nao da extensao: as 5
    classicas Adobe sao .otf/CFF, mas as colecoes do Google (Poppins) sao glyf
    e o Windows registra colecao glyf como "(TrueType)".
    """
    return "glyf" in f


def curar(src, so_allowlist):
    """Agrupa os arquivos de src por slug de saida. Devolve (grupos, descartes)."""
    grupos = collections.defaultdict(list)
    descartes = []
    for nome in sorted(os.listdir(src)):
        if nome.lower().endswith(".ttc"):
            # names() so leria a face 0 — colecao na origem entraria capada.
            descartes.append((nome, "colecao .ttc na origem — descompacte em faces soltas antes"))
            continue
        if not nome.lower().endswith((".ttf", ".otf")):
            continue
        caminho = os.path.join(src, nome)
        # "_0" e renomeio de colisao do Windows: mesma face, charset menor.
        if os.path.splitext(nome)[0].endswith("_0"):
            descartes.append((nome, "duplicata de colisao (_0)"))
            continue
        try:
            n = names(caminho)
        except Exception as e:
            descartes.append((nome, f"ilegivel: {e}"))
            continue
        familia = n.get(16) or n.get(1) or ""
        slug = ALLOWLIST.get(familia)
        if not slug:
            if so_allowlist:
                descartes.append((nome, f"fora da allowlist: {familia!r}"))
                continue
            slug = "".join(c if c.isalnum() else "-" for c in familia.lower()).strip("-")
        # NAO usar nameID 4 aqui: nesses OTF da Adobe o registro Windows do
        # nameID 4 guarda o nome PostScript ("AGaramondPro-Bold"), enquanto o
        # registro Mac guarda o nome de verdade ("Adobe Garamond Pro Bold").
        # nameID 16+17 (familia/subfamilia tipografica) batem nos dois.
        estilo = n.get(17) or n.get(2) or ""
        cheio = familia if estilo.lower() == "regular" else f"{familia} {estilo}".strip()
        avisar_default_vf(caminho, nome, cheio)
        grupos[slug].append((caminho, cheio))
    return grupos, descartes


def avisar_default_vf(caminho, nome, cheio):
    """Aviso de build quando uma variavel tem default fora do Regular.

    O Archivo v2.001 do upstream sai com fvar wght default=600: em app sem
    suporte a eixo variavel (GDI — SketchUp e Photoshop no Windows) o aluno
    recebe SemiBold achando que e Regular, e o nome de registro vira
    "Archivo SemiBold". Nao da pra consertar so no fvar.defaultValue (as
    deltas gvar continuam com o master no peso errado) — tem que reinterpolar.
    """
    f = TTFont(caminho, fontNumber=0, lazy=True)
    eixos = {a.axisTag: (a.minValue, a.defaultValue, a.maxValue) for a in f["fvar"].axes} \
        if "fvar" in f else {}
    f.close()
    if "wght" not in eixos or eixos["wght"][1] == 400:
        return
    lo, default, hi = eixos["wght"]
    print(f"  AVISO {nome}: fvar wght default={default:g} (esperado 400) — vai registrar "
          f"como {cheio!r} e renderizar nesse peso em app sem VF. Conserte a fonte antes:\n"
          f"    python3 -m fontTools.varLib.instancer '{nome}' wght={lo:g}:400:{hi:g} "
          f"--update-name-table -o fix.ttf")


def natural(s):
    """Chave de ordenacao que le digito como numero.

    Na Helvetica Neue LT Std o estilo comeca com o numero do grid Linotype, e
    ordenacao pura de string poe "107 Extra Black Condensed" antes de "55 Roman".
    """
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


def ordenar_faces(fontes):
    """Ordena as faces da colecao: Regular/Roman primeiro, depois peso crescente.

    A face 0 e a que o Font Book, a lista de fontes do Windows e os previewers
    usam como cara da colecao. "Regular" aqui e a face de pe, largura normal e
    peso mais perto de 400 — nao da pra ir pelo nome porque a familia chama de
    "55 Roman" (Helvetica Neue), "Book" (Futura, Avant Garde) ou nada
    (Minion Pro, Adobe Garamond Pro).
    """
    dados = []
    for f, cheio in fontes:
        os2 = f["OS/2"] if "OS/2" in f else None
        peso = os2.usWeightClass if os2 else 400
        largura = os2.usWidthClass if os2 else 5
        italico = bool(f["head"].macStyle & 2 or (os2 and os2.fsSelection & 1))
        dados.append((f, cheio, peso, largura, italico))
    normais = [d for d in dados if not d[4] and d[3] == 5]
    regular = min(normais, key=lambda d: (abs(d[2] - 400), d[2])) if normais else None
    dados.sort(key=lambda d: (0 if d is regular else 1, d[2], d[4], natural(d[1])))
    return [(d[0], d[1]) for d in dados]


def empacotar(grupos, out, licencas=None):
    """Monta um zip a partir dos grupos. Devolve (arquivos, faces)."""
    print(f"\n== {out}")
    reg = {}
    with tempfile.TemporaryDirectory() as tmp:
        for slug, itens in sorted(grupos.items()):
            # familia com ate 2 arquivos fica como o fabricante entregou: e a
            # configuracao que os sistemas e os apps Adobe testam. .ttc so onde
            # ele realmente resolve dor (Poppins tem 18 estaticos).
            if len(itens) <= 2:
                for caminho, cheio in sorted(itens, key=lambda x: x[1]):
                    nome = os.path.basename(caminho)
                    copiar(caminho, os.path.join(tmp, nome))
                    f = TTFont(caminho, fontNumber=0, lazy=True)
                    sufixo = "(TrueType)" if truetype(f) else "(OpenType)"
                    f.close()
                    reg[nome] = f"{cheio} {sufixo}"
                print(f"{slug}: {len(itens)} arquivo(s) como vieram")
                continue
            fontes = ordenar_faces([(TTFont(p), cheio) for p, cheio in itens])
            destino = os.path.join(tmp, f"{slug}.ttc")
            coll = TTCollection()
            coll.fonts = [f for f, _n in fontes]
            coll.save(destino)
            sufixo = "(TrueType)" if all(truetype(f) for f, _n in fontes) else "(OpenType)"
            reg[f"{slug}.ttc"] = " & ".join(n for _f, n in fontes) + f" {sufixo}"
            print(f"{slug}.ttc: {len(fontes)} faces, {os.path.getsize(destino) // 1024} KB, "
                  f"face 0 = {fontes[0][1]!r}")

        # a OFL 1.1 condiciona a redistribuicao a "each copy contains the above
        # copyright notice and this license" — nameID 13/14 dentro do binario e
        # o minimo tecnico, mas o aluno nao abre name table. Os .txt nao sujam a
        # pasta de fontes: os dois instaladores filtram por .ttf/.otf/.ttc.
        if licencas:
            alvo = os.path.join(tmp, "licencas")
            os.makedirs(alvo)
            copiados = [n for n in sorted(os.listdir(licencas)) if n.lower().endswith(".txt")]
            for nome in copiados:
                copiar(os.path.join(licencas, nome), os.path.join(alvo, nome))
            print(f"licencas/: {len(copiados)} arquivo(s)")

        # names.json e POR ZIP: so as chaves dos arquivos que este zip carrega.
        with open(os.path.join(tmp, "names.json"), "w", encoding="utf-8") as fh:
            json.dump(reg, fh, ensure_ascii=False, indent=1, sort_keys=True)

        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for raiz, _dirs, arquivos in sorted(os.walk(tmp)):
                for nome in sorted(arquivos):
                    caminho = os.path.join(raiz, nome)
                    z.write(caminho, os.path.relpath(caminho, tmp))

    faces = sum(len(v) for v in grupos.values())
    # len(reg) conta arquivo de fonte de verdade; len(grupos) contaria familia.
    print(f"{out}: {len(reg)} arquivos, {faces} faces, {os.path.getsize(out) // 1024} KB")
    return len(reg), faces


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("legado", help="pasta das fontes classicas (passa pela allowlist)")
    ap.add_argument("--google", help="pasta das Google Fonts (passa tudo)")
    ap.add_argument("--licencas", help="pasta com os OFL.txt das familias Google "
                                       "(default: <google>/licencas)")
    ap.add_argument("--out", default="payload/fonts.zip",
                    help="zip do release. Sem --out-classicas leva o pacote "
                         "COMPLETO (classicas + livres); com ele, so as livres")
    ap.add_argument("--out-classicas",
                    help="separa as classicas licenciadas neste zip, pro canal "
                         "privado — e tira elas do zip de --out")
    args = ap.parse_args()

    classicas, descartes = curar(args.legado, so_allowlist=True)
    if not classicas:
        sys.exit(f"nenhuma fonte da allowlist encontrada em {args.legado}")
    livres = {}
    if args.google:
        livres, d = curar(args.google, so_allowlist=False)
        descartes += d

    # sem --out-classicas as classicas viajam JUNTO no zip de --out (pacote
    # completo, um so). payload/fonts.zip e asset de release de um repo PUBLICO
    # — qualquer um baixa com um curl, sem login e sem Hotmart —, entao esse
    # modo expoe fonte Adobe/Linotype com "all rights reserved" no binario: e
    # exatamente a decisao de licenciamento que ainda esta aberta com o Joao.
    saida = dict(livres)
    if not args.out_classicas:
        for slug, itens in classicas.items():
            if slug in saida:
                sys.exit(f"colisao de slug {slug!r} entre a pasta do Google e a allowlist "
                         f"das classicas — as duas familias virariam um arquivo so")
            saida[slug] = itens

    if saida:
        licencas = args.licencas or (os.path.join(args.google, "licencas") if args.google else None)
        if licencas and not os.path.isdir(licencas):
            licencas = None
        if not licencas:
            print("AVISO: sem pasta de licencas. A OFL 1.1 exige que a copia da licenca "
                  "acompanhe a fonte — baixe ofl/<familia>/OFL.txt do repo google/fonts "
                  "pra <google>/licencas/ e rode de novo.")
        if not args.out_classicas:
            print("AVISO: classicas licenciadas incluidas no zip publico — exposicao de "
                  "licenciamento, decisao pendente (use --out-classicas pra separar)")
        empacotar(saida, args.out, licencas)
    else:
        print(f"\nsem --google: nenhuma familia livre, {args.out} nao foi tocado")

    if args.out_classicas:
        empacotar(classicas, args.out_classicas)
        print("  ^ licenca Adobe/Linotype: NAO subir pro GitHub nem pro release; "
              "entregar pelo canal privado (o mesmo das texturas/HDRIs)")

    print(f"\ndescartados: {len(descartes)}")
    for nome, motivo in descartes[:5]:
        print(f"  {nome}: {motivo}")
    if len(descartes) > 5:
        print(f"  ... (+{len(descartes) - 5})")
    print("\nagora rode: python3 tools/make_manifest.py")


if __name__ == "__main__":
    main()
