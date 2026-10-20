#!/usr/bin/env python3
"""Preserve Apple's WidgetKit entry point and Swift's extension bootstrap."""
import os
import sys
from pathlib import Path

arguments = sys.argv[1:]
package = None
for index, argument in enumerate(arguments[:-1]):
    if argument == "--package-path":
        package = Path(arguments[index + 1]).resolve()

if (package is not None and package.name == ".xtool-tmp"
        and package.parent.name == "xtool" and "build" in arguments):
    manifest = package / "Package.swift"
    sections = manifest.read_text().split(".executableTarget(")
    for index, section in enumerate(sections):
        if 'name: "HavitWidget-Extension"' not in section:
            continue
        entry = '"-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",'
        root = '"-Xlinker", "-u", "-Xlinker", "_main",'
        if root not in section:
            sections[index] = section.replace(entry, entry + "\n        " + root)
    manifest.write_text(".executableTarget(".join(sections))

compiler = os.environ.get("HAVIT_REAL_SWIFT")
if not compiler or Path(compiler).resolve() == Path(sys.argv[0]).resolve():
    sys.exit("HAVIT_REAL_SWIFT debe apuntar al compilador Swift original.")
os.execv(compiler, [compiler, *arguments])
