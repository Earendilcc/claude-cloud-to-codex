#!/usr/bin/env python3
"""Verify downloaded cloud files and reconstruct their tree. Defaults to a dry run."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import unicodedata


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def key(name):
    return unicodedata.normalize("NFC", name).casefold()


def parts(value):
    require(isinstance(value, str), "Expected a relative path string")
    names = value.split("/")
    for name in names:
        require(name and name not in (".", "..") and name[-1] not in ". "
                and not re.search(r'[<>:"\\|?*\x00-\x1f]', name),
                f"Unsafe or unrepresentable path: {value!r}")
        require(not re.fullmatch(r"(con|prn|aux|nul|conin\$|conout\$|(?:com|lpt)[1-9¹²³])",
                                 name.split(".")[0].rstrip().casefold()),
                f"Reserved filename: {value!r}")
    return tuple(names)


def check_node(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    linked = stat.S_ISLNK(info.st_mode) or (
        getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)
    require(not linked, f"Refusing a symbolic link or reparse point: {path}")


def root_path(value):
    # Reject links before resolving the caller's selected local path.
    path = Path(os.path.abspath(value))
    for parent in reversed(path.parents):
        check_node(parent)
    check_node(path)
    return path


def member(root, names):
    path = root
    check_node(path)
    for name in names:
        if path.is_dir():
            aliases = [p.name for p in path.iterdir() if key(p.name) == key(name)]
            require(not aliases or aliases == [name],
                    f"Case or Unicode filename conflict: {path / name}")
        path = path / name
        check_node(path)
    return path


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_file(path, digest, size):
    require(path.is_file(), f"Missing or non-regular file: {path}")
    if size is not None:
        require(path.stat().st_size == size, f"File size mismatch: {path}")
    require(checksum(path) == digest, f"Different content or SHA-256 mismatch: {path}")


def restore(manifest, inbox, dest, apply):
    require(inbox.is_dir(), f"Download inbox is not a directory: {inbox}")
    require(inbox != dest and inbox not in dest.parents and dest not in inbox.parents,
            "The download inbox and destination must be separate directories")
    require(dest != Path(dest.anchor), "Choose a destination below the filesystem root")
    require(not dest.exists() or dest.is_dir(), f"Destination is not a directory: {dest}")
    require(manifest != dest and dest not in manifest.parents, "Keep the temporary manifest outside the destination")
    data = json.loads(manifest.read_text(encoding="utf-8-sig"))
    require(isinstance(data, dict) and set(data) == {"version", "directories", "files"}
            and type(data["version"]) is int and data["version"] == 1, "Expected version 1 manifest")
    require(isinstance(data["directories"], list) and isinstance(data["files"], list),
            "directories and files must both be lists")

    directories = set()
    entries = []
    catalog = {}
    def register(names, kind):
        for i in range(1, len(names) + 1):
            name = names[:i]
            item_kind = kind if name == names else "dir"
            identity = tuple(map(key, name))
            if identity in catalog:
                require(catalog[identity] == (name, item_kind) and item_kind == "dir",
                        f"Duplicate, alias or file/directory conflict: {'/'.join(name)}")
            else:
                catalog[identity] = name, item_kind
            if item_kind == "dir":
                directories.add(name)

    for directory in data["directories"]:
        register(parts(directory), "dir")
    for entry in data["files"]:
        require(isinstance(entry, dict) and {"path", "download", "sha256"} <= entry.keys()
                <= {"path", "download", "sha256", "bytes"}, "Invalid file entry")
        names = parts(entry["path"])
        register(names, "file")
        sha = entry["sha256"]
        require(isinstance(sha, str) and re.fullmatch("[0-9a-fA-F]{64}", sha),
                f"Expected SHA-256 for {entry['path']}")
        size = entry.get("bytes")
        require(size is None or type(size) is int and size >= 0, "Invalid byte count")
        entries.append((names, parts(entry["download"]), sha.lower(), size))

    # Validate *all* known conflicts and source files before creating anything.
    for names in sorted(directories):
        path = member(dest, names)
        require(not path.exists() or path.is_dir(), f"Expected directory: {path}")
    reused = 0
    pending = []
    for names, downloaded, sha, size in entries:
        src, dst = member(inbox, downloaded), member(dest, names)
        check_file(src, sha, size)
        if dst.exists():
            check_file(dst, sha, size)
            reused += 1
        else:
            pending.append((names, downloaded, sha, size))
    if apply:
        dest.mkdir(parents=True, exist_ok=True)
        for names in sorted(directories):
            member(dest, names).mkdir(exist_ok=True)
        for names, downloaded, sha, size in pending:
            src, dst = member(inbox, downloaded), member(dest, names)
            fd, raw_tmp = tempfile.mkstemp(prefix=".claude-restore-", dir=dst.parent)
            tmp = Path(raw_tmp)
            try:
                with os.fdopen(fd, "wb") as target, src.open("rb") as source:
                    shutil.copyfileobj(source, target, length=1024 * 1024)
                check_file(tmp, sha, size)
                try:
                    if os.name == "nt":
                        os.rename(tmp, dst)  # Windows refuses to replace an existing path.
                    else:
                        os.link(tmp, dst)  # Atomic, non-replacing install on POSIX.
                except FileExistsError:
                    pass  # A concurrent identical restore can win the race.
                check_file(member(dest, names), sha, size)
            finally:
                tmp.unlink(missing_ok=True)
        for names, _, sha, size in entries:
            check_file(member(dest, names), sha, size)
        require(all(member(dest, d).is_dir() for d in directories), "Directory verification failed")
    print(f"{'Verified restore' if apply else 'Dry run'}: {len(entries)} files, "
          f"{len(directories)} directories below root, {reused} already identical, "
          f"{len(pending)} initially missing.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("manifest", "inbox", "dest"):
        parser.add_argument("--" + arg, required=True, type=Path)
    parser.add_argument("--apply", action="store_true", help="Create missing directories and files")
    args = parser.parse_args()
    try:
        restore(root_path(args.manifest), root_path(args.inbox), root_path(args.dest), args.apply)
    except (OSError, ValueError) as err:
        parser.exit(1, f"Restore stopped: {err}\n")


if __name__ == "__main__":
    main()
