"""Package only public files and explicitly selected static Linux binaries."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
TARGETS = [
    ("aarch64", "nezha-agent-lite_aarch64-linux-musl_cortex-a53", 183, "cortex_a53"),
    ("x86_64", "nezha-agent-lite_x86_64-linux-musl", 62, "baseline"),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="v0.1.0")
    parser.add_argument("--build-dir", type=Path, default=ROOT / "zig-out")
    parser.add_argument("--output", type=Path, default=ROOT / "release")
    args = parser.parse_args()
    if not re.fullmatch(r"v?\d+\.\d+\.\d+(?:[-.][A-Za-z0-9.-]+)?", args.version):
        raise SystemExit("Expected a release version such as v0.1.0")
    args.output.mkdir(parents=True, exist_ok=True)
    git = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    commit = git.stdout.strip() if git.returncode == 0 else None
    info = {"version": args.version, "protocol": "Nezha Agent v0.20.5",
            "zig": "0.15.2", "optimize": "ReleaseSmall", "source_commit": commit, "artifacts": []}
    sums = []
    common = [ROOT / "README.md", ROOT / "LICENSE", ROOT / "NOTICE"]
    common += [p for p in (ROOT / "licenses").iterdir() if p.is_file()]
    common += [p for p in (ROOT / "openwrt").iterdir() if p.is_file()]
    for target, name, machine, cpu in TARGETS:
        data = (args.build_dir / target / "bin/nezha-agent-lite").read_bytes()
        if data[:6] != b"\x7fELF\x02\x01":
            raise SystemExit("Expected little-endian ELF64 for " + target)
        header = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
        segments = [struct.unpack_from("<I", data, header[4] + i * header[8])[0] for i in range(header[9])]
        if header[1] != machine or 2 in segments or 3 in segments:
            raise SystemExit("Expected a static executable for " + target)
        digest = hashlib.sha256(data).hexdigest()
        (args.output / name).write_bytes(data)
        info["artifacts"].append({"file": name, "target": target + "-linux-musl",
                                  "cpu": cpu, "bytes": len(data), "sha256": digest})
        sums.append((digest, name))
        archive_name = name + "_" + args.version + ".tar.gz"
        with tarfile.open(args.output / archive_name, "w:gz") as archive:
            entry = tarfile.TarInfo("nezha-agent-lite")
            entry.size = len(data)
            entry.mode = 0o755
            entry.mtime = 0
            archive.addfile(entry, io.BytesIO(data))
            for path in common:
                entry = tarfile.TarInfo(path.relative_to(ROOT).as_posix())
                content = path.read_bytes()
                entry.size = len(content)
                entry.mode = 0o755 if path.suffix == ".init" else 0o644
                entry.mtime = 0
                archive.addfile(entry, io.BytesIO(content))
        sums.append((hashlib.sha256((args.output / archive_name).read_bytes()).hexdigest(), archive_name))
    metadata = args.output / "build-info.json"
    metadata.write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    sums.append((hashlib.sha256(metadata.read_bytes()).hexdigest(), metadata.name))
    (args.output / "SHA256SUMS").write_text(
        "".join(digest + "  " + name + "\n" for digest, name in sums), encoding="utf-8"
    )
    print(json.dumps(info, indent=2))


if __name__ == "__main__":
    main()
