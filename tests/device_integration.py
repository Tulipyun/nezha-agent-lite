"""Temporary real-device validation via an existing Bitvise profile.

Does not replace the installed agent, modify UCI or change networking/firewall.
Uses a loopback-only SSH reverse forward and a private /tmp test directory.
"""
import argparse
import contextlib
import hashlib
import json
import os
import re
import secrets
import shlex
import subprocess
import time
from pathlib import Path

from openwrt_integration import Dashboard


class Bitvise:
    def __init__(self, directory, profile, host, port, user):
        self.directory = directory
        self.options = [
            "-profile=" + str(profile.resolve()), "-host=" + host,
            "-port=" + str(port), "-user=" + user, "-unat=y",
            "-initialKexTimeout=10",
        ]
        self.flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

    def run(self, command, *, data=None, timeout=30, check=True):
        completed = subprocess.run(
            [str(self.directory / "sexec.exe"), *self.options, "-exitZero",
             "-inputEOL=preserve", "-cmd=" + command],
            input=data, capture_output=True, timeout=timeout, creationflags=self.flags,
        )
        out = completed.stdout.decode("utf-8", errors="replace")
        err = completed.stderr.decode("utf-8", errors="replace")
        if check and completed.returncode:
            raise RuntimeError(f"SSH command failed ({completed.returncode}): {out}\n{err}")
        return completed.returncode, re.sub(r"Received exit code \d+\.\s*", "", out).strip()

    def forward(self, remote_port, local_port, log):
        return subprocess.Popen(
            [str(self.directory / "stnlc.exe"), *self.options,
             "-ftpBridge=n", "-proxyFwding=n", "-mapSftp=n", "-c2s=",
             f"-s2c=127.0.0.1,{remote_port},127.0.0.1,{local_port}"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            creationflags=self.flags,
        )

    def snapshot(self, pid):
        if not isinstance(pid, int) or pid < 2:
            raise ValueError("invalid PID")
        # Keep all process information numeric; never collect command lines.
        command = (
            "awk '/^VmRSS:/{print \"RSS_KIB=\" $2} /^VmSize:/{print \"VMS_KIB=\" $2} "
            f"/^Threads:/{{print \"THREADS=\" $2}}' /proc/{pid}/status; "
            f"awk '{{print \"PROC_TICKS=\" $14+$15}}' /proc/{pid}/stat; "
            "awk '/^cpu /{s=0; for(i=2;i<=9;i++) s+=$i; print \"SYSTEM_TICKS=\" s}' /proc/stat; "
            f"printf 'FD_COUNT='; ls /proc/{pid}/fd | wc -l; "
            f"if [ -r /proc/{pid}/smaps_rollup ]; then "
            f"awk '/^Pss:/{{print \"PSS_KIB=\" $2}}' /proc/{pid}/smaps_rollup; fi"
        )
        _, output = self.run(command)
        values = {m.group(1).lower(): int(m.group(2)) for m in re.finditer(r"(?m)^([A-Z_]+)=(\d+)", output)}
        values["time"] = time.monotonic()
        assert "rss_kib" in values and "threads" in values, output
        return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bitvise-dir", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--user", default="root")
    parser.add_argument("--bind-host", default="127.0.0.1",
                        help="Workstation LAN address for a direct test connection; default uses an SSH reverse forward")
    parser.add_argument("--binary", type=Path, default=Path("zig-out/aarch64/bin/nezha-agent-lite"))
    parser.add_argument("--rounds", type=int, default=61)
    parser.add_argument("--period", type=float, default=30)
    parser.add_argument("--output", type=Path, default=Path("test-results/device-integration.json"))
    args = parser.parse_args()
    assert args.rounds >= 2 and args.period >= 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    remote = Bitvise(args.bitvise_dir, args.profile, args.host, args.port, args.user)
    dashboard = Dashboard(args.bind_host)
    direct = args.bind_host != "127.0.0.1"
    remote_port = dashboard.port if direct else 40000 + secrets.randbelow(20000)
    server_host = args.bind_host if direct else "127.0.0.1"
    remote_dir = "/tmp/nezha-zig-test-" + secrets.token_hex(6)
    binary = remote_dir + "/nezha-agent-lite"
    agent_log = remote_dir + "/agent.log"
    pidfile = remote_dir + "/agent.pid"
    evidence = {
        "platform": "physical IPQ60xx", "period_s": args.period,
        "rounds": args.rounds, "checks": [], "samples": [],
        "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        "remote_test_directory": remote_dir, "remote_loopback_port": remote_port,
        "test_transport": "LAN" if direct else "SSH reverse forward",
        "complete": False, "running": True,
    }
    tunnel = None
    pid = None
    created = False
    original_pids = []
    tunnel_log = args.output.with_suffix(".tunnel.log").open("wb")
    cleanup_ok = True

    def save():
        tmp = args.output.with_suffix(".tmp")
        tmp.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        tmp.replace(args.output)

    def record(name, **values):
        entry = {"case": name, "passed": True, **values}
        evidence["checks"].append(entry)
        save()
        print(json.dumps(entry), flush=True)

    try:
        _, arch = remote.run("uname -m")
        assert arch == "aarch64", arch
        _, release = remote.run("cat /etc/openwrt_release; uname -r; head -n 3 /proc/meminfo")
        evidence["device_release"] = release
        assert "qualcommax/ipq60xx" in release, release
        _, group_range = remote.run("cat /proc/sys/net/ipv4/ping_group_range")
        evidence["ping_group_range"] = group_range
        _, old = remote.run("pidof nezha-agent", check=False)
        original_pids = [int(p) for p in old.split() if p.isdigit()]
        evidence["existing_agent_pids"] = original_pids
        evidence["existing_agent_before"] = [remote.snapshot(p) for p in original_pids]
        _, mem = remote.run("awk '/^MemAvailable:/{print $2}' /proc/meminfo")
        assert int(mem) > 32768, "less than 32 MiB available"
        record("device_identity_and_existing_agent_baseline")

        if direct:
            record("temporary_lan_test_server", bind_host=args.bind_host)
        else:
            tunnel = remote.forward(remote_port, dashboard.port, tunnel_log)
            ready = False
            for _ in range(10):
                if tunnel.poll() is not None:
                    raise RuntimeError("SSH reverse tunnel exited; see tunnel log")
                command = ("awk '$2==\"0100007F:" + f"{remote_port:04X}" +
                           "\" && $4==\"0A\" {f=1} END{exit !f}' /proc/net/tcp")
                code, _ = remote.run(command, check=False)
                if code == 0:
                    ready = True
                    break
                time.sleep(0.5)
            assert ready, "reverse forward is not listening on remote loopback"
            record("temporary_loopback_only_ssh_forward")

        remote.run("umask 077; mkdir " + shlex.quote(remote_dir))
        created = True
        remote.run("cat > " + shlex.quote(binary), data=args.binary.read_bytes())
        _, actual = remote.run("chmod 700 " + shlex.quote(binary) + "; sha256sum " + shlex.quote(binary))
        assert actual.split()[0] == evidence["binary_sha256"], actual
        record("uploaded_binary_sha256_verified")
        command = f"{shlex.quote(binary)} -s {server_host}:{remote_port} -p local-test --once --rpc-timeout 3"
        remote.run(command)
        dashboard.accept_receipt = False
        code, _ = remote.run(command, check=False)
        assert code != 0, "rejected receipt returned success"
        dashboard.accept_receipt = True
        record("real_device_once_and_rejected_receipt_exit")

        lifetime = max(300, int(args.rounds * args.period + 240))
        program = (
            "echo $$ > " + shlex.quote(pidfile) + "; exec " + shlex.quote(binary) +
            f" -s {server_host}:{remote_port} -p local-test --workers 32 --report-workers 2"
            " --queue-capacity 128 --report-delay 1 --rpc-timeout 5 --debug"
        )
        remote.run(
            f"nohup timeout {lifetime} sh -c " + shlex.quote(program) +
            " > " + shlex.quote(agent_log) + " 2>&1 < /dev/null &"
        )
        dashboard.wait(lambda: dashboard.task_queue is not None and len(dashboard.states) >= 3, 20)
        _, text = remote.run("cat " + shlex.quote(pidfile))
        pid = int(text)
        _, executable = remote.run(f"readlink /proc/{pid}/exe")
        assert executable == binary, executable
        evidence["test_agent_pid"] = pid
        with dashboard.lock:
            assert dashboard.hosts[-1][1].get(7) == b"aarch64"
            assert dashboard.hosts[-1][1].get(4, 0) > 0
            assert dashboard.states[-1][1].get(3, 0) > 0
        record("real_device_host_state_and_32_worker_startup", pid=pid)

        for target, count, label in [
            ("127.0.0.1", 8, "8_ipv4_tasks"),
            ("localhost", 16, "16_hostname_tasks"),
            ("::1", 16, "16_ipv6_tasks"),
            ("127.0.0.1", 32, "32_same_target_tasks"),
        ]:
            ids = dashboard.burst(count, target)
            record(label, **dashboard.check_results(ids, successful=True))

        dashboard.result_delay = 0.15
        with dashboard.lock:
            state_start = len(dashboard.states)
        ids = dashboard.burst(32)
        slow = dashboard.check_results(ids, successful=True)
        dashboard.result_delay = 0
        with dashboard.lock:
            assert len(dashboard.states) > state_start
        record("slow_result_receipts_keep_state_reporting", **slow)

        with dashboard.lock:
            old_connections = dashboard.task_connections
        dashboard.disconnect()
        dashboard.wait(lambda: dashboard.task_connections > old_connections and dashboard.task_queue is not None, 15)
        ids = dashboard.burst(8)
        record("test_connection_loss_and_recovery", **dashboard.check_results(ids, successful=True))

        with dashboard.lock:
            soak_state_start = len(dashboard.states)
        start = time.monotonic()
        evidence["soak_start_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        for index in range(args.rounds):
            deadline = start + index * args.period
            while time.monotonic() < deadline:
                if tunnel is not None and tunnel.poll() is not None:
                    raise RuntimeError("SSH test tunnel terminated")
                time.sleep(min(0.25, max(0, deadline - time.monotonic())))
            ids = dashboard.burst(32, "::1" if index % 4 == 3 else "127.0.0.1")
            batch = dashboard.check_results(ids, successful=True, timeout=25)
            assert batch["max_result_s"] < args.period, batch
            sample = remote.snapshot(pid)
            assert sample["threads"] == 36, sample
            evidence["samples"].append(sample)
            evidence["soak_rounds_completed"] = index + 1
            evidence["soak_elapsed_s"] = round(time.monotonic() - start, 3)
            record("periodic_32_task_batch", round=index + 1, **batch,
                   rss_kib=sample["rss_kib"], fd_count=sample.get("fd_count"))

        with dashboard.lock:
            times = [t for t, _ in dashboard.states[soak_state_start:]]
            evidence["total_state_reports"] = len(dashboard.states)
            evidence["total_task_results"] = len(dashboard.results)
        assert len(times) >= (args.rounds - 1) * args.period / 2, len(times)
        gaps = [b - a for a, b in zip(times, times[1:])]
        evidence["max_soak_state_gap_s"] = round(max(gaps), 3)
        assert max(gaps) < 5, max(gaps)
        rss = [s["rss_kib"] for s in evidence["samples"]]
        evidence["rss_min_kib"], evidence["rss_max_kib"] = min(rss), max(rss)
        assert max(rss) - min(rss) <= 1024, rss
        ticks = evidence["samples"][-1]["proc_ticks"] - evidence["samples"][0]["proc_ticks"]
        total = evidence["samples"][-1]["system_ticks"] - evidence["samples"][0]["system_ticks"]
        evidence["process_cpu_percent_of_one_core"] = round(ticks * 4 * 100 / total, 3) if total else None
        record("soak_state_continuity_and_bounded_resources", elapsed_s=evidence["soak_elapsed_s"],
               max_state_gap_s=evidence["max_soak_state_gap_s"], rss_min_kib=min(rss), rss_max_kib=max(rss))
        evidence["complete"] = True
    except Exception as exc:
        evidence["error"] = repr(exc)
        raise
    finally:
        if created:
            try:
                _, log = remote.run("cat " + shlex.quote(agent_log), check=False)
                args.output.with_suffix(".agent.log").write_text(log + "\n", encoding="utf-8")
                if pid is None:
                    _, text = remote.run("cat " + shlex.quote(pidfile), check=False)
                    if text.isdigit():
                        pid = int(text)
                if pid is not None:
                    _, executable = remote.run(f"readlink /proc/{pid}/exe", check=False)
                    if executable == binary:
                        remote.run(f"kill {pid}")
                # Only explicitly created files in our unique /tmp directory.
                remote.run("rm -f " + " ".join(shlex.quote(p) for p in (binary, agent_log, pidfile)) +
                           "; rmdir " + shlex.quote(remote_dir))
            except Exception as exc:
                cleanup_ok = False
                evidence["cleanup_error"] = repr(exc)
        if tunnel is not None and tunnel.poll() is None:
            tunnel.terminate()
            try:
                tunnel.wait(timeout=5)
            except subprocess.TimeoutExpired:
                tunnel.kill()
                tunnel.wait()
        tunnel_log.close()
        dashboard.close()
        try:
            _, old = remote.run("pidof nezha-agent", check=False)
            after = [int(p) for p in old.split() if p.isdigit()]
            evidence["existing_agent_pids_after"] = after
            evidence["existing_agent_unchanged"] = set(after) == set(original_pids)
            evidence["existing_agent_after"] = [remote.snapshot(p) for p in after]
            if not evidence["existing_agent_unchanged"]:
                cleanup_ok = False
        except Exception as exc:
            cleanup_ok = False
            evidence["baseline_verification_error"] = repr(exc)
        evidence["cleanup_complete"] = cleanup_ok
        evidence["running"] = False
        if not cleanup_ok:
            evidence["complete"] = False
        save()


if __name__ == "__main__":
    main()
