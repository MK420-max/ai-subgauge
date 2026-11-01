#!/usr/bin/env python3
"""Resolve native bundle UI strings from the shared catalogs during packaging."""
import json
import plistlib
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1])
with (root / "Resources/Info.plist").open("rb") as source:
    template = plistlib.load(source)
keys = ["CFBundleName", "CFBundleDisplayName", "NSCalendarsFullAccessUsageDescription",
        "NSAppleEventsUsageDescription", "NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"]
for language in ("en", "zh-Hans"):
    catalog = json.loads((root.parent / f"shared/i18n/{language}.json").read_text(encoding="utf-8"))
    strings = {key: catalog[template[key]] for key in keys}
    if language == "en":
        info = dict(template, **strings)
        with (app / "Contents/Info.plist").open("wb") as destination:
            plistlib.dump(info, destination)
    folder = app / f"Contents/Resources/{language}.lproj"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "InfoPlist.strings").write_text("\n".join(
        f"{json.dumps(key)} = {json.dumps(value, ensure_ascii=False)};" for key, value in strings.items()
    ) + "\n", encoding="utf-8")
