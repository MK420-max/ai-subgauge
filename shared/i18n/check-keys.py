#!/usr/bin/env python3
"""Validate shared catalogs and literal localization references. No dependencies.

Usage: python3 shared/i18n/check-keys.py [source-directory ...]
With no sources, checks both Mac and Windows applications.
Supported calls: L10n.text, I18n.T, I18n.Get, L10n.Get.
"""
import json
import re
import sys
from pathlib import Path


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError(f"Duplicate key: {key}")
        result[key] = value
    return result


def check(sources):
    folder = Path(__file__).resolve().parent
    catalogs = {lang: json.loads((folder / f"{lang}.json").read_text(encoding="utf-8"), object_pairs_hook=pairs)
                for lang in ("en", "zh-Hans")}
    keys = set(catalogs["en"])
    if not keys or keys != set(catalogs["zh-Hans"]):
        raise ValueError(f"Language key sets differ: {keys ^ set(catalogs['zh-Hans'])}")
    for lang, entries in catalogs.items():
        for key, value in entries.items():
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"Empty or non-string value: {lang}/{key}")
            if set(re.findall(r"\{\d+\}", value)) != set(re.findall(r"\{\d+\}", catalogs["en"][key])):
                raise ValueError(f"Placeholder mismatch: {lang}/{key}")
    references = set()
    pattern = re.compile(r'\b(?:L10n\.text|I18n\.(?:T|Get)|L10n\.Get)\(\s*"([^"\n]+)"')
    for source in sources:
        if not source.exists():
            raise ValueError(f"Source does not exist: {source}")
        files = [source] if source.is_file() else list(source.rglob("*.swift")) + list(source.rglob("*.cs"))
        for file in files:
            references.update(pattern.findall(file.read_text(encoding="utf-8")))
    missing = references - keys
    if missing:
        raise ValueError(f"Missing referenced keys: {sorted(missing)}")
    print(f"OK: {len(keys)} shared keys; {len(references)} referenced keys checked")


if __name__ == "__main__":
    try:
        root = Path(__file__).resolve().parents[2]
        check([Path(value) for value in sys.argv[1:]] or [root / "mac" / "Sources", root / "windows" / "src"])
    except (ValueError, OSError) as error:
        sys.exit(str(error))
