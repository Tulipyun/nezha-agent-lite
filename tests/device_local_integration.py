"""Drive the on-router fixture over Bitvise SSH; no cross-machine test port."""
import argparse
import contextlib
import hashlib
import json
import re
import secrets
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
    parser.add_argument("--user", default="root")
    parser.add_argument("--binary", type=Path, default=Path("zig-out/aarch64/bin/nezha-agent-lite"))
    parser.add_argument("--rounds", type=int, default=61)
    parser.add_argument("--period", type=int, default=30)
    parser.add_argument("--output", type=Path, default=Path("test-results/device-local.json"))
    args = parser.parse_args()
    assert args.rounds >= 8 and args.period >= 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    remote = Bitvise(args.bitvise_dir, args.profile, args.host, args.port, args.user)
    directory = "/tmp/nezha-zig-test-" + secrets.token_hex(6)
    port = 40000 + secrets.randbelow(20000)
    binary = directory + "/nezha-agent-lite"
    fixture = directory + "/fixture.lua"
    files = [binary, fixture, directory + "/fixture.pid", directory + "/agent.pid",
             directory + "/fixture.log", directory + "/agent.log",
             directory + "/status.json", directory + "/status.json.tmp", directory + "/reject"]
    evidence = {"platform": "physical IPQ60xx", "rounds": args.rounds, "period_s": args.period,
                "remote_test_directory": directory, "test_transport": "device loopback",
                "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                "running": True, "complete": False}
    original_pids = []
    created = False
    last_round = -1

    def save():
        temp = args.output.with_suffix(".tmp")
        temp.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        temp.replace(args.output)

    def upload(path, content, executable=False):
        remote.run("cat > " + shlex.quote(path), data=content)
        if executable:
            remote.run("chmod 700 " + shlex.quote(path))

    def launch(pidfile, command, log, lifetime):
        program = "echo $$ > " + shlex.quote(pidfile) + "; exec " + command
        remote.run(f"nohup timeout {lifetime} sh -c " + shlex.quote(program) +
                   " > " + shlex.quote(log) + " 2>&1 < /dev/null &")

    try:
        _, arch = remote.run("uname -m")
        assert arch == "aarch64", arch
        _, release = remote.run("cat /etc/openwrt_release; uname -r")
        assert "qualcommax/ipq60xx" in release, release
        evidence["device_release"] = release
        _, pids = remote.run("pidof nezha-agent", check=False)
        original_pids = [int(p) for p in pids.split() if p.isdigit()]
        evidence["existing_agent_pids"] = original_pids
        evidence["existing_agent_before"] = [remote.snapshot(p) for p in original_pids]
        remote.run("umask 077; mkdir " + shlex.quote(directory))
        created = True
        upload(binary, args.binary.read_bytes(), True)
        upload(fixture, Path("tests/device_fixture.lua").read_bytes())
        _, digest = remote.run("sha256sum " + shlex.quote(binary))
        assert digest.split()[0] == evidence["binary_sha256"]
        lifetime = args.rounds * args.period + 180
        launch(directory + "/fixture.pid",
               f"lua {shlex.quote(fixture)} {port} {shlex.quote(directory)} {args.rounds} {args.period}",
               directory + "/fixture.log", lifetime)
        for _ in range(10):
            _, text = remote.run("cat " + shlex.quote(directory + "/status.json"), check=False)
            try:
                ready = json.loads(text)
                assert ready["listening_port"] == port
                break
            except (ValueError, KeyError):
                time.sleep(0.5)
        else:
            _, log = remote.run("cat " + shlex.quote(directory + "/fixture.log"), check=False)
            raise RuntimeError("fixture did not start: " + log)
        once = f"{shlex.quote(binary)} -s 127.0.0.1:{port} -p local-test --once --rpc-timeout 3"
        remote.run(once)
        remote.run("touch " + shlex.quote(directory + "/reject"))
        code, _ = remote.run(once, check=False)
        assert code != 0, "rejected receipt returned success"
        remote.run("rm -f " + shlex.quote(directory + "/reject"))
        evidence["once_and_rejected_receipt_passed"] = True
        launch(directory + "/agent.pid",
               f"{shlex.quote(binary)} -s 127.0.0.1:{port} -p local-test "
               "--workers 32 --report-workers 2 --queue-capacity 128 --report-delay 1 --debug",
               directory + "/agent.log", lifetime)
        print("real-device fixture and 32-worker agent started", flush=True)
        save()
        deadline = time.monotonic() + lifetime
        while time.monotonic() < deadline:
            _, text = remote.run("cat " + shlex.quote(directory + "/status.json"))
            status = json.loads(text)
            evidence["fixture"] = status
            save()
            current_round = status.get("round", 0)
            if current_round != last_round:
                sample = (status.get("samples") or [{}])[-1]
                print(json.dumps({"round": current_round, "results": status.get("results"),
                                  "states": status.get("states"), "rss_kib": sample.get("rss_kib"),
                                  "running": status.get("running")}), flush=True)
                last_round = current_round
            if not status["running"]:
                assert status["complete"], status.get("error", status)
                _, log = remote.run("cat " + shlex.quote(directory + "/agent.log"))
                acknowledgements = re.findall(r"ReportTask id=(\d+).*receipt=true", log)
                assert len(acknowledgements) == status["results"], (
                    "not all result receipts confirmed", len(acknowledgements), status["results"])
                assert len(set(acknowledgements)) == status["results"]
                evidence["confirmed_receipts"] = len(acknowledgements)
                samples = status["samples"]
                ticks = samples[-1]["proc_ticks"] - samples[0]["proc_ticks"]
                total = samples[-1]["system_ticks"] - samples[0]["system_ticks"]
                evidence["process_cpu_percent_of_one_core"] = round(ticks * 400 / total, 3) if total else None
                evidence["complete"] = True
                break
            time.sleep(min(10, max(1, args.period / 3)))
        else:
            raise RuntimeError("device validation deadline exceeded")
    except Exception as exc:
        evidence["error"] = repr(exc)
        raise
    finally:
        cleanup = True
        if created:
            for name in ["agent", "fixture"]:
                try:
                    _, log = remote.run("cat " + shlex.quote(directory + "/" + name + ".log"), check=False)
                    args.output.with_suffix("." + name + ".log").write_text(log + "\n", encoding="utf-8")
                    _, raw = remote.run("cat " + shlex.quote(directory + "/" + name + ".pid"), check=False)
                    if raw.isdigit():
                        pid = int(raw)
                        if name == "agent":
                            _, exe = remote.run(f"readlink /proc/{pid}/exe", check=False)
                            ours = exe == binary
                        else:
                            # Verify the script path in this exact PID; never collect other command lines.
                            code, _ = remote.run(f"grep -Fq {shlex.quote(fixture)} /proc/{pid}/cmdline", check=False)
                            ours = code == 0
                        if ours:
                            remote.run(f"kill {pid}", check=False)
                except Exception as exc:
                    cleanup = False
                    evidence["cleanup_error"] = repr(exc)
            try:
                remote.run("rm -f " + " ".join(shlex.quote(p) for p in files) +
                           "; rmdir " + shlex.quote(directory))
            except Exception as exc:
                cleanup = False
                evidence["cleanup_error"] = repr(exc)
        try:
            _, pids = remote.run("pidof nezha-agent", check=False)
            after = [int(p) for p in pids.split() if p.isdigit()]
            evidence["existing_agent_pids_after"] = after
            evidence["existing_agent_unchanged"] = set(after) == set(original_pids)
            if not evidence["existing_agent_unchanged"]:
                cleanup = False
        except Exception as exc:
            cleanup = False
            evidence["baseline_error"] = repr(exc)
        evidence["running"] = False
        evidence["cleanup_complete"] = cleanup
        evidence["complete"] = evidence["complete"] and cleanup
        save()


if __name__ == "__main__":
    main()
