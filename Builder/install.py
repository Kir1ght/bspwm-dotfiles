#!/usr/bin/env python3
"""
Interactive wrapper around ../install.sh.

The single source of truth is install.sh: it is easier to audit, works on an
already installed system, and can be re-run safely.

Usage:
    python3 Builder/install.py
    python3 Builder/install.py --yes
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = os.path.join(ROOT, "install.sh")


def ask(question: str, default: bool = True) -> bool:
    suffix = "[Y/n]" if default else "[y/N]"
    try:
        answer = input(f"{question} {suffix}: ").strip().lower()
    except EOFError:
        return default
    if not answer:
        return default
    return answer in {"y", "yes", "д", "да"}


def main() -> int:
    parser = argparse.ArgumentParser(description="Kir1ght bspwm-dotfiles installer")
    parser.add_argument("--yes", action="store_true", help="accept all defaults")
    args = parser.parse_args()

    print()
    print("  Kir1ght bspwm-dotfiles — Builder")
    print("  ================================")
    print()

    if not os.path.isfile(INSTALL):
        print(f"install.sh not found: {INSTALL}", file=sys.stderr)
        return 1

    if args.yes:
        flags: list[str] = []
    else:
        flags = []
        if not ask("Install pacman/AUR packages?", True):
            flags.append("--no-packages")
        if not ask("Copy dotfiles to ~/.config and ~/.local/bin?", True):
            flags.append("--no-config")
        if not ask("Configure NVIDIA runtime power management?", True):
            flags.append("--no-gpu")
        if not ask("Install Firefox user.js + chrome?", True):
            flags.append("--no-firefox")
        if ask("Download whisper.cpp models (~1 GB)?", False):
            flags.append("--with-whisper")
        if ask("Install optional desktop applications?", False):
            flags.append("--with-apps")
        if ask("Install optional AUR tools/themes (ly, Dracula)?", False):
            flags.append("--with-extra")

    cmd = ["bash", INSTALL, *flags]
    print()
    print("Running:", " ".join(cmd))
    print()
    return subprocess.call(cmd)


if __name__ == "__main__":
    raise SystemExit(main())
