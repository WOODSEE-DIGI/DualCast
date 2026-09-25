#!/usr/bin/env python3
#
# fix-camera-extension-embed.py
#
# xcodegen 2.45.4 embeds ExtensionKit camera extensions in Contents/Extensions,
# which produces a build warning (and may fail to load). CoreMediaIO camera
# extensions must be embedded in the parent app's PlugIns directory.
# Run this after `xcodegen generate`.
#

import pathlib
import sys

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
PBXPROJ = PROJECT_ROOT / "DualCast.xcodeproj" / "project.pbxproj"


def main() -> int:
    text = PBXPROJ.read_text(encoding="utf-8")

    marker = "/* Embed ExtensionKit Extensions */ = {"
    start = text.find(marker)
    if start == -1:
        print("No Embed ExtensionKit Extensions phase found.")
        return 0

    end = text.find("};", start)
    if end == -1:
        print("Could not find end of Embed ExtensionKit Extensions phase.")
        return 1

    block = text[start:end]
    if 'dstPath = "$(EXTENSIONS_FOLDER_PATH)";' not in block:
        print("Embed phase is already patched or does not target Extensions folder.")
        return 0

    block = block.replace('dstPath = "$(EXTENSIONS_FOLDER_PATH)";', 'dstPath = "";')
    block = block.replace("dstSubfolderSpec = 16;", "dstSubfolderSpec = 13;")

    new_text = text[:start] + block + text[end:]
    PBXPROJ.write_text(new_text, encoding="utf-8")
    print("Patched Embed ExtensionKit Extensions phase to use PlugIns directory.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
