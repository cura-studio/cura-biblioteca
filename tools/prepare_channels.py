#!/usr/bin/env python3
"""Prepara uploads privados dos dois canais; não assina, envia ou publica."""

import argparse
import hashlib
import io
import json
import re
import shutil
import stat
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

PRODUCT = "cura-ferramentas"
METADATA = "cura_ferramentas/distribution.json"
UPDATER = "cura_ferramentas/core/updater.rb"
REPO = Path(__file__).resolve().parents[1]


def read_package(path, channel):
    with zipfile.ZipFile(io.BytesIO(path) if isinstance(path, bytes) else path) as archive:
        files = {}
        seen = set()
        for info in archive.infolist():
            name = info.filename
            parts = PurePosixPath(name).parts
            key = name.rstrip("/").casefold()
            if (not parts or "\\" in name or name.startswith("/") or
                    ".." in parts or parts[0] not in ("cura_ferramentas.rb", "cura_ferramentas") or
                    (parts[0] == "cura_ferramentas.rb" and len(parts) != 1) or
                    key in seen or stat.S_ISLNK(info.external_attr >> 16)):
                raise ValueError("Entrada inválida ou duplicada no RBZ: " + name)
            seen.add(key)
            if not info.is_dir():
                files[name] = archive.read(info)
        if archive.testzip() is not None:
            raise ValueError("RBZ corrompido")
    if any(name.endswith((".rbe", ".rbs", ".susig")) for name in files):
        raise ValueError("Preparação exige uploads abertos, anteriores à assinatura")
    metadata = json.loads(files[METADATA].decode("utf-8"))
    if metadata != {"schema": 1, "product": PRODUCT, "channel": channel}:
        raise ValueError("Metadados do canal divergentes: " + channel)
    ruby = files["cura_ferramentas.rb"].decode("utf-8")
    html = files["cura_ferramentas/core/shell.html"].decode("utf-8")
    version = re.search(r"\bVERSION\s*=\s*'([^']+)'", ruby).group(1)
    ui_version = re.search(r"\bCURA_UI_VERSION\s*=\s*'([^']+)'", html).group(1)
    if version != ui_version:
        raise ValueError("Versão Ruby/UI divergente")
    if channel == "biblioteca" and UPDATER not in files:
        raise ValueError("Build Biblioteca sem updater")
    if channel == "warehouse" and any(
            PurePosixPath(name).stem == "updater" for name in files):
        raise ValueError("Build Warehouse contém updater próprio")
    return version, files


def prepare(biblioteca, warehouse, source_commit, output):
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("Informe o commit completo da fonte")
    output = Path(output).resolve()
    if output == REPO or REPO in output.parents:
        raise ValueError("Uploads abertos devem ficar fora do repositório público da Biblioteca")
    if output.exists():
        raise FileExistsError("Destino já existe; preserve o pacote e suas evidências: " + str(output))
    # Cada canal é lido uma vez; build concorrente não troca bytes após a conferência.
    library_payload = Path(biblioteca).read_bytes()
    warehouse_payload = Path(warehouse).read_bytes()
    version, library_files = read_package(library_payload, "biblioteca")
    other_version, warehouse_files = read_package(warehouse_payload, "warehouse")
    if version != other_version:
        raise ValueError("Canais têm versões diferentes")
    common_library = {name: data for name, data in library_files.items()
                      if name not in (METADATA, UPDATER)}
    common_warehouse = {name: data for name, data in warehouse_files.items()
                        if name != METADATA}
    if common_library != common_warehouse:
        raise ValueError("Motores ou recursos diferem entre os canais")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".cura-channels-", dir=output.parent))
    try:
        packages = {}
        for channel, payload in (("biblioteca", library_payload), ("warehouse", warehouse_payload)):
            filename = f"{PRODUCT}-v{version}-{channel}-upload.rbz"
            target = staging / filename
            target.write_bytes(payload)
            target.chmod(0o600)
            # Lê a cópia efetiva para vincular o plano aos bytes entregues.
            read_package(target, channel)
            packages[channel] = {
                "file": filename,
                "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                "public_asset_allowed": False,
            }
        plan = {
            "schema": 1,
            "product": PRODUCT,
            "version": version,
            "source_commit": source_commit,
            "packages": packages,
            "github": {"state": "prepared", "published_url": None},
            "warehouse": {
                "state": "prepared", "extension_id": None,
                "submission_url": None, "published_url": None,
                "published_download_sha256": None,
            },
            "complete": False,
            "next_steps": [
                "Assinar build Biblioteca pelo portal oficial e validar o artefato retornado",
                "Publicar apenas pacote protegido e manifest correspondente no canal de distribuição",
                "Enviar upload Warehouse aberto pelo portal; registrar versão e comprovante",
                "Aguardar revisão; aprovação ainda não significa publicação",
                "Publicar após aprovação e verificar versão na página pública",
            ],
            "privacy": "Uploads abertos são privados; nunca anexar à release pública ou Actions públicos",
            "activation": "Integração e-mail/código adiada para o backend CURA; nenhuma ativação simulada",
        }
        (staging / "release-plan.json").write_text(
            json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        staging.rename(output)
        return plan
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--biblioteca", type=Path, required=True)
    parser.add_argument("--warehouse", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.biblioteca, args.warehouse, args.source_commit, args.output)
    except (ValueError, KeyError, AttributeError, OSError, zipfile.BadZipFile) as error:
        parser.exit(2, "Preparação recusada: " + str(error) + "\n")
    print(f"Uploads privados preparados: {result['version']}; publicação pendente nos dois canais")


if __name__ == "__main__":
    main()
