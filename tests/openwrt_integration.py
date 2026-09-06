"""Run the actual ARM64 agent in an isolated, disposable OpenWrt QEMU guest.

Requires the existing QEMU executable, an ARM64 virt initramfs, and hyper-h2.
Only a loopback HTTP file server and loopback mock dashboard are started.
No real router or dashboard credentials are used.
"""
import argparse
import contextlib
import hashlib
import http.server
import json
import os
import queue
import re
import shutil
import socket
import struct
import subprocess
import threading
import time
from pathlib import Path

import h2.config
import h2.connection
import h2.events


def varint(value):
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


def task_message(task_id, typ, target=""):
    data = target.encode()
    payload = b"\x08" + varint(task_id) + b"\x10" + varint(typ)
    if data:
        payload += b"\x1a" + varint(len(data)) + data
    return envelope(payload)


def envelope(payload):
    return b"\0" + struct.pack(">I", len(payload)) + payload


def fields(data):
    result = {}
    offset = 0

    def integer():
        nonlocal offset
        value = shift = 0
        while offset < len(data):
            byte = data[offset]
            offset += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value
            shift += 7
        raise ValueError("truncated varint")

    while offset < len(data):
        tag = integer()
        number, wire = tag >> 3, tag & 7
        if wire == 0:
            value = integer()
        elif wire == 2:
            length = integer()
            value = data[offset:offset + length]
            assert len(value) == length
            offset += length
        elif wire == 1:
            value = struct.unpack_from("<d", data, offset)[0]
            offset += 8
        elif wire == 5:
            value = struct.unpack_from("<f", data, offset)[0]
            offset += 4
        else:
            raise ValueError(wire)
        result[number] = value
    return result


class Dashboard:
    def __init__(self, bind_host="127.0.0.1"):
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.listener = socket.socket()
        self.listener.bind((bind_host, 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.sockets = set()
        self.task_queue = None
        self.task_connections = 0
        self.states = []
        self.hosts = []
        self.results = {}
        self.sent = {}
        self.errors = []
        self.result_delay = 0
        self.accept_receipt = True
        self.next_id = 1
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self.lock:
                self.sockets.add(conn)
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        outbox = queue.Queue()
        try:
            conn.settimeout(0.05)
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            peer = h2.connection.H2Connection(
                config=h2.config.H2Configuration(client_side=False, header_encoding="utf-8")
            )
            peer.initiate_connection()
            conn.sendall(peer.data_to_send())
            paths, bodies = {}, {}
            task_stream = None
            delayed = []
            while not self.stop.is_set():
                try:
                    data = conn.recv(65536)
                    if not data:
                        return
                except socket.timeout:
                    data = b""
                for event in peer.receive_data(data) if data else []:
                    if isinstance(event, h2.events.RequestReceived):
                        headers = dict(event.headers)
                        assert headers.get("client_secret") == "local-test"
                        paths[event.stream_id] = headers[":path"]
                        bodies[event.stream_id] = bytearray()
                    elif isinstance(event, h2.events.DataReceived):
                        bodies[event.stream_id].extend(event.data)
                        peer.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif isinstance(event, h2.events.StreamEnded):
                        raw = bodies.pop(event.stream_id)
                        path = paths.pop(event.stream_id)
                        assert raw[0] == 0 and len(raw) == 5 + struct.unpack(">I", raw[1:5])[0]
                        decoded = fields(raw[5:])
                        now = time.monotonic()
                        with self.lock:
                            if path.endswith("/RequestTask"):
                                self.task_connections += 1
                                self.task_queue = outbox
                                task_stream = event.stream_id
                            elif path.endswith("/ReportSystemInfo"):
                                self.hosts.append((now, decoded))
                            elif path.endswith("/ReportSystemState"):
                                self.states.append((now, decoded))
                            elif path.endswith("/ReportTask"):
                                self.results.setdefault(decoded.get(1, 0), []).append((now, decoded))
                            else:
                                raise AssertionError(path)
                        if task_stream == event.stream_id:
                            peer.send_headers(task_stream, [(":status", "200"), ("content-type", "application/grpc")])
                        else:
                            delay = self.result_delay if path.endswith("/ReportTask") else 0
                            delayed.append((now + delay, event.stream_id, self.accept_receipt))
                if task_stream is not None:
                    while True:
                        try:
                            message = outbox.get_nowait()
                        except queue.Empty:
                            break
                        peer.send_data(task_stream, message)
                pending = []
                for when, stream, accepted in delayed:
                    if time.monotonic() < when:
                        pending.append((when, stream, accepted))
                        continue
                    peer.send_headers(stream, [(":status", "200"), ("content-type", "application/grpc")])
                    peer.send_data(stream, envelope(b"\x08\x01" if accepted else b"\x08\x00"))
                    peer.send_headers(stream, [("grpc-status", "0")], end_stream=True)
                delayed = pending
                data = peer.data_to_send()
                if data:
                    conn.sendall(data)
        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, OSError):
            pass
        except Exception as exc:
            with self.lock:
                self.errors.append(repr(exc))
        finally:
            with self.lock:
                self.sockets.discard(conn)
                if self.task_queue is outbox:
                    self.task_queue = None
            conn.close()

    def wait(self, condition, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                assert not self.errors, self.errors
                if condition():
                    return
            time.sleep(0.05)
        raise AssertionError("dashboard condition timed out")

    def burst(self, count, target="127.0.0.1"):
        self.wait(lambda: self.task_queue is not None)
        with self.lock:
            ids = list(range(self.next_id, self.next_id + count))
            self.next_id += count
            now = time.monotonic()
            for task_id in ids:
                self.sent[task_id] = now
            self.task_queue.put(b"".join(task_message(i, 2, target) for i in ids))
            return ids

    def check_results(self, ids, *, successful=None, timeout=25):
        self.wait(lambda: all(i in self.results for i in ids), timeout)
        with self.lock:
            durations = []
            failures = []
            for task_id in ids:
                reports = self.results[task_id]
                assert len(reports) == 1, ("duplicate result", task_id, reports)
                arrived, result = reports[0]
                assert result.get(2) == 2
                ok = bool(result.get(5, 0))
                if successful is not None:
                    assert ok == successful, (task_id, result)
                if not ok:
                    failures.append(result.get(4, b"").decode(errors="replace"))
                durations.append(arrived - self.sent[task_id])
            return {"tasks": len(ids), "max_result_s": round(max(durations), 3),
                    "failed": len(failures), "failure_messages": sorted(set(failures))}

    def disconnect(self):
        with self.lock:
            sockets = list(self.sockets)
        for conn in sockets:
            with contextlib.suppress(OSError):
                conn.shutdown(socket.SHUT_RDWR)

    def close(self):
        self.stop.set()
        self.disconnect()
        self.listener.close()
        self.thread.join(timeout=2)


class Guest:
    def __init__(self, qemu, image, log, arch="aarch64"):
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        if arch == "aarch64":
            machine = ["-machine", "virt", "-cpu", "cortex-a53", "-kernel", str(image),
                       "-append", "console=ttyAMA0", "-device", "virtio-net-device,netdev=n0"]
        else:
            machine = ["-machine", "q35", "-cpu", "qemu64",
                       "-drive", "file=" + str(image) + ",format=raw,if=virtio,snapshot=on",
                       "-device", "virtio-net-pci,netdev=n0"]
        self.process = subprocess.Popen(
            [str(qemu), *machine, "-smp", "4", "-m", "256",
             "-display", "none", "-monitor", "none", "-serial", "stdio",
             "-netdev", "user,id=n0", "-no-reboot"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            bufsize=0, creationflags=flags,
        )
        self.condition = threading.Condition()
        self.output = bytearray()
        self.log = log.open("wb")
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        self.serial_id = 0
        try:
            self.wait_for(lambda data: b"Please press Enter to activate this console" in data, 60)
            self.process.stdin.write(b"\n")
            self.wait_for(lambda data: re.search(rb"root@[^\r\n]*#", data), 15)
        except Exception:
            self.close()
            raise

    def read(self):
        while chunk := self.process.stdout.read(4096):
            self.log.write(chunk)
            self.log.flush()
            with self.condition:
                self.output.extend(chunk)
                self.condition.notify_all()

    def wait_for(self, predicate, timeout, start=0):
        deadline = time.monotonic() + timeout
        with self.condition:
            while time.monotonic() < deadline:
                data = bytes(self.output[start:])
                if predicate(data):
                    return data
                if self.process.poll() is not None:
                    break
                self.condition.wait(0.1)
        raise RuntimeError("guest timeout/exit:\n" + bytes(self.output[-4000:]).decode(errors="replace"))

    def run(self, command, timeout=20, check=True):
        self.serial_id += 1
        marker = f"__NEZHA_DONE_{self.serial_id}"
        with self.condition:
            start = len(self.output)
        text = (command + "\nprintf '\\n" + marker + ":%s\\n' \"$?\"\n").encode()
        # The emulated PL011 FIFO can drop a large write from a Windows pipe.
        # Pace serial input independently of the agent/network timings.
        for offset in range(0, len(text), 4):
            self.process.stdin.write(text[offset:offset + 4])
            time.sleep(0.005)
        pattern = re.compile(re.escape(marker.encode()) + rb":(\d+)")
        data = self.wait_for(lambda output: pattern.search(output), timeout, start)
        code = int(pattern.search(data).group(1))
        output = data.decode(errors="replace")
        if check:
            assert code == 0, output
        return code, output

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.reader.join(timeout=2)
        self.log.close()


class QuietFiles(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--arch", choices=["aarch64", "x86_64"], default="aarch64")
    parser.add_argument("--binary", type=Path, default=Path("zig-out/aarch64/bin/nezha-agent-lite"))
    parser.add_argument("--period", type=float, default=30)
    parser.add_argument("--output", type=Path, default=Path("test-results/openwrt-integration.json"))
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    stage = args.output.parent / (args.output.stem + "-stage")
    stage.mkdir(exist_ok=True)
    shutil.copy2(args.binary, stage / "nezha-agent-lite")
    shutil.copy2("openwrt/nezha-agent.init", stage / "nezha-agent.init")
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), lambda *a, **kw: QuietFiles(*a, directory=str(stage.resolve()), **kw)
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    dashboard = Dashboard()
    guest = None
    evidence = {"platform": "QEMU OpenWrt " + args.arch, "period_s": args.period, "checks": [],
                "binary_sha256": hashlib.sha256((stage / "nezha-agent-lite").read_bytes()).hexdigest()}

    def record(name, **values):
        entry = {"case": name, "passed": True, **values}
        evidence["checks"].append(entry)
        args.output.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(entry), flush=True)

    try:
        print("booting isolated OpenWrt guest " + args.arch, flush=True)
        guest = Guest(args.qemu.resolve(), args.image.resolve(), args.output.with_suffix(".console.log"), args.arch)
        guest.wait_for(lambda data: b"kmodloader: done loading kernel modules from /etc/modules.d/" in data, 30)
        # First boot generates UCI defaults well after the interactive console
        # appears. Wait for netifd so its later startup cannot replace our route.
        guest.run("ubus -t 90 wait_for network.interface.lan", timeout=95)
        _, network_before = guest.run("ip -o link show; ubus list; cat /etc/config/network", check=False)
        evidence["guest_network_before_setup"] = network_before
        guest.run("uci set network.lan.proto='static'; uci set network.lan.ipaddr='10.0.2.15'; "
                  "uci set network.lan.netmask='255.255.255.0'; uci set network.lan.gateway='10.0.2.2'; "
                  "uci set network.lan.dns='10.0.2.3'; uci commit network; /etc/init.d/network restart")
        guest.run("ubus -t 20 wait_for network.interface.lan", timeout=25)
        guest.run("ip link set lo up; ip addr add 127.0.0.1/8 dev lo 2>/dev/null; "
                  "ip -6 addr add ::1/128 dev lo 2>/dev/null; ping -c 1 -W 1 127.0.0.1")
        file_port = server.server_address[1]
        guest.run(f"wget -T 10 -q -O /usr/bin/nezha-agent-lite http://10.0.2.2:{file_port}/nezha-agent-lite "
                  "&& chmod +x /usr/bin/nezha-agent-lite", timeout=15)
        guest.run(f"wget -T 10 -q -O /etc/init.d/nezha-agent http://10.0.2.2:{file_port}/nezha-agent.init "
                  "&& chmod +x /etc/init.d/nezha-agent")
        command = f"/usr/bin/nezha-agent-lite -s 10.0.2.2:{dashboard.port} -p local-test --once --rpc-timeout 2"
        guest.run(command)
        dashboard.accept_receipt = False
        code, output = guest.run(command, check=False)
        assert code != 0 and "ServerRejected" in output
        dashboard.accept_receipt = True
        record("once_success_and_rejected_receipt_exit")
        config = (
            "config agent 'main'\n"
            f"option server '10.0.2.2:{dashboard.port}'\n"
            "option secret 'local-test'\noption workers '32'\noption report_workers '2'\n"
            "option queue_capacity '128'\noption report_delay '1'\noption debug '1'\n"
        )
        guest.run("cat > /etc/config/nezha-agent <<'NEZHA_CONFIG'\n" + config + "NEZHA_CONFIG")
        guest.run("echo '0 2147483647' > /proc/sys/net/ipv4/ping_group_range; /etc/init.d/nezha-agent start")
        dashboard.wait(lambda: dashboard.task_queue is not None and len(dashboard.states) >= 3)
        record("procd_reads_main_section_and_starts_agent")
        with dashboard.lock:
            assert dashboard.hosts[-1][1].get(7) == args.arch.encode(), dashboard.hosts[-1]
            assert dashboard.hosts[-1][1].get(4, 0) > 0
            assert dashboard.states[-1][1].get(3, 0) > 0
            assert dashboard.states[-1][1].get(10, 0) > 0
        record("actual_linux_host_and_state_metrics")
        base = time.monotonic()
        for index, count in enumerate((8, 16, 32)):
            while time.monotonic() < base + index * args.period:
                time.sleep(0.1)
            ids = dashboard.burst(count)
            record(f"periodic_{count}_icmp_tasks", **dashboard.check_results(ids, successful=True))
        ids = dashboard.burst(16, "::1")
        record("ipv6_ping_sockets", **dashboard.check_results(ids, successful=True))
        guest.run("echo '1 0' > /proc/sys/net/ipv4/ping_group_range")
        ids = dashboard.burst(32)
        record("raw_socket_concurrent_same_target", **dashboard.check_results(ids, successful=True))
        guest.run("echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_all")
        with dashboard.lock:
            state_start = len(dashboard.states)
        ids = dashboard.burst(32)
        timeout_result = dashboard.check_results(ids, successful=False, timeout=27)
        assert 19 <= timeout_result["max_result_s"] < 27, timeout_result
        with dashboard.lock:
            state_times = [t for t, _ in dashboard.states[state_start:]]
        assert len(state_times) >= 10, len(state_times)
        max_gap = max(b - a for a, b in zip(state_times, state_times[1:]))
        assert max_gap < 4, max_gap
        record("32_timeouts_do_not_block_state_reports", **timeout_result,
               state_reports_during_batch=len(state_times), max_state_gap_s=round(max_gap, 3))
        guest.run("echo 0 > /proc/sys/net/ipv4/icmp_echo_ignore_all")
        dashboard.result_delay = 0.15
        ids = dashboard.burst(32)
        record("slow_result_receipts", **dashboard.check_results(ids, successful=True))
        dashboard.result_delay = 0
        with dashboard.lock:
            old_connections = dashboard.task_connections
        dashboard.disconnect()
        dashboard.wait(lambda: dashboard.task_connections > old_connections and dashboard.task_queue is not None, 15)
        ids = dashboard.burst(8)
        record("reconnect_after_all_sockets_closed", **dashboard.check_results(ids, successful=True))
        with dashboard.lock:
            host_count = len(dashboard.hosts)
            dashboard.task_queue.put(task_message(0, 7) + task_message(0, 10))
        dashboard.wait(lambda: len(dashboard.hosts) > host_count, 6)
        assert 0 not in dashboard.results
        record("keepalive_and_report_host_control_tasks")
        _, metrics = guest.run("pid=$(pidof nezha-agent-lite); "
                               "sed -n '/^VmRSS:/p; /^VmSize:/p; /^Threads:/p' /proc/$pid/status; "
                               "if [ -r /proc/$pid/smaps_rollup ]; then cat /proc/$pid/smaps_rollup; fi; "
                               "logread -e 'stats states='")
        evidence["guest_metrics_and_stats"] = metrics
        with dashboard.lock:
            old_connections = dashboard.task_connections
        guest.run("uci set nezha-agent.main.workers='8'; uci set nezha-agent.main.queue_capacity='4'; "
                  "uci set nezha-agent.main.task_max_age='3'; echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_all; "
                  "/etc/init.d/nezha-agent restart")
        dashboard.wait(lambda: dashboard.task_connections > old_connections and dashboard.task_queue is not None, 15)
        ids = dashboard.burst(64)
        overflow = dashboard.check_results(ids, successful=False, timeout=10)
        assert "ICMP queue full" in overflow["failure_messages"], overflow
        record("bounded_overload_returns_explicit_failures", **overflow)
        _, log = guest.run("logread -e 'result queue full'; logread -e 'stats states='; /etc/init.d/nezha-agent stop")
        evidence["final_guest_log"] = log
        with dashboard.lock:
            assert not dashboard.errors, dashboard.errors
            evidence["total_state_reports"] = len(dashboard.states)
            evidence["total_task_results"] = len(dashboard.results)
        evidence["complete"] = True
        args.output.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    except Exception as exc:
        evidence["complete"] = False
        evidence["error"] = repr(exc)
        with dashboard.lock:
            evidence["failure_dashboard"] = {
                "states": len(dashboard.states), "hosts": len(dashboard.hosts),
                "task_connections": dashboard.task_connections, "result_ids": sorted(dashboard.results),
                "sent_ids": sorted(dashboard.sent), "errors": list(dashboard.errors),
            }
        if guest is not None:
            with contextlib.suppress(Exception):
                _, log = guest.run("logread -e nezha-agent; ip -4 addr show; ip route show; "
                                   "pid=$(pidof nezha-agent-lite); [ -z \"$pid\" ] || cat /proc/$pid/status",
                                   timeout=15, check=False)
                evidence["failure_guest_log"] = log
        args.output.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        raise
    finally:
        if guest is not None:
            guest.close()
        dashboard.close()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
