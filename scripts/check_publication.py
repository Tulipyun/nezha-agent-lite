"""Check public source and release assets without printing matched secrets."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {".git", ".zig-cache", "zig-out", "release", "dist", "test-results", "__pycache__"}
PATTERNS = {
    "private-key material": re.compile(rb"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"),
    "GitHub credential": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
    "personal Windows path": re.compile(rb"[A-Za-z]:[\\/]+Users[\\/]+[A-Za-z0-9_.-]+", re.I),
    "personal home path": re.compile(rb"/(?:home|Users)/[A-Za-z0-9_.-]+/"),
    "private deployment IP": re.compile(rb"192\.168\.[0-9]{1,3}\.[0-9]{1,3}"),
    "shared conversation": re.compile(rb"chatgpt\.com/(?:s|share)/", re.I),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--extra-terms-file", type=Path)
    parser.add_argument("--release-dir", type=Path, default=ROOT / "release")
    args = parser.parse_args()
    terms = []
    if args.extra_terms_file:
        terms = [v.encode().lower() for v in json.loads(args.extra_terms_file.read_text()) if v]
    failures = []
    checked = 0

    def check(label, data):
        nonlocal checked
        checked += 1
        for category, pattern in PATTERNS.items():
            if pattern.search(data):
                failures.append((label, category))
        lowered = data.lower()
        if any(term in lowered for term in terms):
            failures.append((label, "private extra term"))

    git = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True)
    if git.returncode == 0 and git.stdout:
        files = [ROOT / p.decode() for p in git.stdout.split(b"\0") if p]
    else:
        files = [p for p in ROOT.rglob("*") if p.is_file()
                 and not any(part in EXCLUDED for part in p.relative_to(ROOT).parts)]
    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        if any(part in EXCLUDED for part in path.relative_to(ROOT).parts):
            failures.append((relative, "private/generated path tracked by Git"))
        if path.suffix.lower() in {".tlp", ".bscp", ".pem", ".key", ".log"} or path.name.startswith(".env"):
            failures.append((relative, "local credential/configuration file"))
        check(relative, path.read_bytes())
    if args.release_dir.exists():
        for path in args.release_dir.iterdir():
            if not path.is_file():
                continue
            if path.name.endswith(".tar.gz"):
                with tarfile.open(path, "r:gz") as archive:
                    for item in archive.getmembers():
                        if item.isfile():
                            check(path.name + ":" + item.name, archive.extractfile(item).read())
            elif path.suffix == ".zip":
                with zipfile.ZipFile(path) as archive:
                    for item in archive.infolist():
                        if not item.is_dir():
                            check(path.name + ":" + item.filename, archive.read(item))
            else:
                check(path.name, path.read_bytes())
    for label, category in failures:
        print(category + ": " + label)
    print(json.dumps({"checked_items": checked, "findings": len(failures)}))
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
