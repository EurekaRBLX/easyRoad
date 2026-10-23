#!/usr/bin/env python3
"""Check the license and notices in both Studio plugin distributions."""

import argparse
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent


def module_source(folder: ET.Element, name: str) -> str:
    for item in folder.findall("Item"):
        if item.findtext("Properties/string[@name='Name']") == name:
            source = item.findtext("Properties/ProtectedString[@name='Source']")
            if source is None:
                source = item.findtext("Properties/string[@name='Source']")
            if source is None:
                raise ValueError(f"{name} has no source")
            return source
    raise ValueError(f"Missing module: {name}")


def check(rojo_xml: Path | None = None) -> None:
    product = (ROOT / "src/ProductLicense.lua").read_text(encoding="utf-8")
    if not re.search(r'ProductLicense\.Mode\s*=\s*"OSS"', product):
        raise ValueError("The source must use OSS mode for Python and Rojo builds")
    if 'ProductLicense.OssLicenseName = "AGPL-3.0-only"' not in product:
        raise ValueError("The product must declare AGPL-3.0-only")

    notices = (ROOT / "src/LicenseNotices.lua").read_text(encoding="utf-8")
    license_paths = [
        ROOT / "LICENSE",
        ROOT / "legal/LICENSE-GapFill.txt",
        ROOT / "reference/roadcreator/LICENSE-roadcreator.md",
        ROOT / "reference/roadhelper/LICENSE-roadhelper",
        *sorted((ROOT / "Packages").rglob("LICENSE*")),
    ]
    for path in license_paths:
        if path.read_text(encoding="utf-8").strip() not in notices:
            raise ValueError(f"The bundled notices omit or alter {path.relative_to(ROOT)}")

    artifacts = [ROOT / "dist/EasyRoad.rbxmx", ROOT / "dist/EasyRoad-OSS.rbxmx"]
    for path in [*artifacts, *([rojo_xml] if rojo_xml else [])]:
        tree = ET.parse(path)
        root_item = tree.getroot().find("Item")
        if root_item is None:
            raise ValueError(f"{path.name} has no plugin root")
        src = next((item for item in root_item.findall("Item")
                    if item.findtext("Properties/string[@name='Name']") == "Src"), None)
        if src is None:
            raise ValueError(f"{path.name} has no Src folder")
        for name, expected in (("ProductLicense", product), ("LicenseNotices", notices)):
            if module_source(src, name) != expected:
                raise ValueError(f"{path.name} has stale or missing {name}")

    if artifacts[0].read_bytes() != artifacts[1].read_bytes():
        raise ValueError("The two distribution names must contain the same OSS build")
    print(f"Distribution checks passed: OSS mode, {len(license_paths)} license texts, both artifacts")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rojo-xml", type=Path, help="Also inspect a Rojo XML build.")
    args = parser.parse_args()
    try:
        check(args.rojo_xml)
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"Distribution check failed: {error}", file=sys.stderr)
        sys.exit(1)
