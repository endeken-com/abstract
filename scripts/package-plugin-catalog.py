#!/usr/bin/env python3
"""Sign bundled plugin hashes and prepare the first-party release catalog."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


def package_hash(folder: Path) -> str:
    files = sorted(path for path in folder.rglob("*")
                   if path.is_file() and path.relative_to(folder).as_posix() != "signature.json")
    digest = hashlib.sha256()
    digest.update((folder / "manifest.json").read_bytes())
    for path in files:
        digest.update(path.relative_to(folder).as_posix().encode())
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def sign_hash(value: str, signer: Path) -> str:
    with tempfile.NamedTemporaryFile() as message:
        message.write(value.encode("ascii"))
        message.flush()
        result = subprocess.run(
            [str(signer), "--ed-key-file", "-", message.name],
            input=os.environ["SPARKLE_KEY"], text=True, capture_output=True, check=True,
        )
    match = re.search(r'edSignature="([^"]+)"', result.stdout)
    if not match or len(base64.b64decode(match.group(1))) != 64:
        raise RuntimeError("sign_update did not return an Ed25519 signature")
    return match.group(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--signer", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    entries = []
    for folder in sorted(Path("Abstract/Resources/Plugins").glob("*.abstractplugin")):
        manifest = json.loads((folder / "manifest.json").read_text())
        digest = package_hash(folder)
        signature = sign_hash(digest, args.signer)
        (folder / "signature.json").write_text(json.dumps({
            "publisher": "Abstract", "signature": signature,
        }, separators=(",", ":")))
        asset = f"{manifest['id']}-{manifest['version']}.zip"
        with zipfile.ZipFile(args.output / asset, "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(folder.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(folder))
        archive_hash = hashlib.sha256((args.output / asset).read_bytes()).hexdigest()
        entries.append({
            "id": manifest["id"], "name": manifest["name"], "version": manifest["version"],
            "url": f"https://github.com/endeken-com/abstract/releases/download/{args.tag}/{asset}",
            "hash": digest,
            "archiveHash": archive_hash, "archiveSignature": sign_hash(archive_hash, args.signer),
        })
    (args.output / "plugins.json").write_text(json.dumps({"plugins": entries}, indent=2) + "\n")


if __name__ == "__main__":
    main()
