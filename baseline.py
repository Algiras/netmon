"""
~/.netmon/baseline.py — Atomic read-modify-write for baseline.txt.
Uses fcntl exclusive locking so analyze.py and panel.py can't race.
"""

from __future__ import annotations

import fcntl
import os
from pathlib import Path


def _open_locked(path: Path):
    """Open-or-create the file and acquire an exclusive lock. Caller owns the fd."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_RDWR | os.O_CREAT, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return os.fdopen(fd, "r+")


def add_entry(path: Path, entry: str) -> str:
    """Add entry (sorted). Returns 'added to baseline' or 'already in baseline'."""
    with _open_locked(path) as f:
        existing = {l.strip() for l in f.read().splitlines() if l.strip()}
        if entry in existing:
            return "already in baseline"
        new_content = "\n".join(sorted(existing | {entry})) + "\n"
        f.seek(0)
        f.write(new_content)
        f.truncate()
    return "added to baseline"


def remove_entry(path: Path, entry: str) -> bool:
    """Remove entry. Returns True if something was actually removed."""
    if not path.exists():
        return False
    with _open_locked(path) as f:
        lines = [l.strip() for l in f.read().splitlines() if l.strip()]
        new_lines = [l for l in lines if l != entry]
        if len(new_lines) == len(lines):
            return False
        new_content = "\n".join(new_lines) + ("\n" if new_lines else "")
        f.seek(0)
        f.write(new_content)
        f.truncate()
    return True
