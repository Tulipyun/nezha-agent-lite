"""Contemporaneous /proc samples of the existing Go agent and live Zig agent."""
import argparse
import json
import statistics
import shlex
import time
from pathlib import Path
from device_integration import Bitvise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bitvise-dir", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--duration", type=int, default=180)
    parser.add_argument("--interval", type=int, default=10)
    parser.add_argument("--warmup", type=int, default=30)
    parser.add_argument("--session", type=Path, default=Path("test-results/live-session.json"))
    parser.add_argument("--output", type=Path, default=Path("test-results/resource-comparison.json"))
    args = parser.parse_args()
    assert args.interval > 0 and args.duration >= args.interval
    remote = Bitvise(args.bitvise_dir, args.profile, args.host, args.port, "root")
    live = json.loads(args.session.read_text())
    _, text = remote.run("pidof nezha-agent")
    go_pids = [int(p) for p in text.split() if p.isdigit()]
    assert len(go_pids) == 1, "expected one installed Go agent"
    pids = {"go": go_pids[0], "zig": live["pid"]}
    _, cpus = remote.run("grep -c '^processor' /proc/cpuinfo")
    cores = int(cpus)
    result = {
        "running": True, "complete": False, "duration_s": args.duration,
        "interval_s": args.interval, "cpu_cores": cores, "pids": pids,
        "zig_sha256": live["binary_sha256"],
        "conditions": "Both agents remain connected to their existing real dashboard accounts; Go is not restarted. Zig uses 32 ICMP workers and 2 result workers. Workloads are observed, not forced to be identical.",
        "samples": [], "binary_bytes": {},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        temp = args.output.with_suffix(".tmp")
        temp.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        temp.replace(args.output)

    try:
        for name, pid in pids.items():
            lua = 'local fs=require "nixio.fs"; print(assert(fs.stat("/proc/' + str(pid) + '/exe")).size)'
            code, size = remote.run("lua -e " + shlex.quote(lua), check=False)
            result["binary_bytes"][name] = int(size) if code == 0 and size.isdigit() else None
        time.sleep(args.warmup)
        started = time.monotonic()
        for index in range(args.duration // args.interval + 1):
            time.sleep(max(0, started + index * args.interval - time.monotonic()))
            pair = {name: remote.snapshot(pid) for name, pid in pids.items()}
            result["samples"].append(pair)
            save()
            print(json.dumps({"sample": index + 1, "go_rss_kib": pair["go"]["rss_kib"],
                              "zig_rss_kib": pair["zig"]["rss_kib"]}), flush=True)
        summary = {}
        for name in pids:
            values = [s[name] for s in result["samples"]]
            first, last = values[0], values[-1]
            proc_delta = last["proc_ticks"] - first["proc_ticks"]
            cpu_delta = last["system_ticks"] - first["system_ticks"]
            assert proc_delta >= 0 and cpu_delta > 0
            entry = {
                "cpu_percent_one_core": round(proc_delta * cores * 100 / cpu_delta, 4),
                "cpu_percent_whole_device": round(proc_delta * 100 / cpu_delta, 4),
                "rss_mean_kib": round(statistics.mean(v["rss_kib"] for v in values), 2),
                "rss_min_kib": min(v["rss_kib"] for v in values),
                "rss_max_kib": max(v["rss_kib"] for v in values),
                "threads_min": min(v["threads"] for v in values),
                "threads_max": max(v["threads"] for v in values),
                "fds_min": min(v["fd_count"] for v in values),
                "fds_max": max(v["fd_count"] for v in values),
                "elapsed_s": round(last["time"] - first["time"], 3),
            }
            if all("pss_kib" in v for v in values):
                entry["pss_mean_kib"] = round(statistics.mean(v["pss_kib"] for v in values), 2)
            summary[name] = entry
        summary["rss_reduction_percent"] = round(
            (1 - summary["zig"]["rss_mean_kib"] / summary["go"]["rss_mean_kib"]) * 100, 2
        )
        result["summary"] = summary
        result["complete"] = True
    except Exception as exc:
        result["error"] = repr(exc)
        raise
    finally:
        result["running"] = False
        save()


if __name__ == "__main__":
    main()
