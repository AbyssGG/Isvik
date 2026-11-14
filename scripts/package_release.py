#!/usr/bin/env python3
"""Create a small, platform-native Isvik release archive."""

from pathlib import Path
import shutil
import sys
import zipfile

if len(sys.argv) != 3:
    raise SystemExit("usage: package_release.py VERSION PLATFORM")

version, platform = sys.argv[1:]
if platform not in {"windows-x64", "linux-x64"}:
    raise SystemExit(f"unsupported platform: {platform}")

root = Path.cwd()
executable = root / ("isvik.exe" if platform == "windows-x64" else "isvik")
if not executable.is_file():
    raise SystemExit(f"built executable not found: {executable}")

output_dir = root / "dist"
staging = output_dir / f"Isvik-{version}-{platform}"
archive = output_dir / f"Isvik-{version}-{platform}.zip"
if staging.exists():
    shutil.rmtree(staging)
staging.mkdir(parents=True)
shutil.copy2(executable, staging / executable.name)
shutil.copy2(root / "LICENSE", staging / "LICENSE")

readme = f"""Isvik {version} — {platform}

This archive contains the Isvik command-line application. No installer is needed.

First run

  Windows:  .\\isvik.exe version
            .\\isvik.exe doctor
  Linux:    ./isvik version
            ./isvik doctor

To start the interactive workbench, run the executable without arguments.

Runtime and models

OpenVINO Runtime is a separate dependency. Isvik can start without it, but
inference requires a compatible OpenVINO runtime and model files. The model
weights and tokenizer are not included in this archive.

On Windows, the repository's dependency helper is available at:
  https://github.com/AbyssGG/Isvik/blob/main/scripts/fetch-deps.ps1

On Linux, install a compatible OpenVINO runtime and ensure libopenvino_c.so
and its dependencies are visible to the dynamic loader. For tokenizer-based
generation, install libopenvino_tokenizers.so and set ISVIK_TOKENIZERS_DLL to
its full path if it is outside Isvik's standard search directories.

Linux package target: x86-64, built on Ubuntu 24.04.
Source and documentation: https://github.com/AbyssGG/Isvik
"""
(staging / "README.txt").write_text(readme, encoding="utf-8")

with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
    for item in sorted(staging.iterdir()):
        bundle.write(item, arcname=f"{staging.name}/{item.name}")

print(f"Created {archive} ({archive.stat().st_size} bytes)")
