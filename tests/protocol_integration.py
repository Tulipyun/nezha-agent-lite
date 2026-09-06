"""Interop tests against hyper-h2; all connections stay on loopback.

Install tests/requirements.txt and run after zig build probe.
"""
import argparse
import json
import os
import socket
import struct
import subprocess
import threading
import time
from pathlib import Path

import h2.config
import h2.connection
import h2.events
import h2.settings


class Peer:
    def __init__(self, mode="ok", window=65535):
        self.mode = mode
        self.window = window
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.stop = threading.Event()
        self.requests = 0
        self.bytes = 0
        self.errors = []
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        try:
            while not self.stop.is_set():
                try:
                    conn, _ = self.listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                with conn:
                    conn.settimeout(0.1)
                    self.serve(conn)
        except Exception as exc:
            if not self.stop.is_set():
                self.errors.append(repr(exc))

    def serve(self, conn):
        if self.mode == "handshake_stall":
            self.stop.wait(5)
            return
        peer = h2.connection.H2Connection(
            config=h2.config.H2Configuration(client_side=False, header_encoding="utf-8")
        )
        if self.window != 65535:
            peer.local_settings = h2.settings.Settings(
                client=False, initial_values={h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: self.window}
            )
        peer.initiate_connection()
        conn.sendall(peer.data_to_send())
        sizes = {}
        while not self.stop.is_set():
            try:
                data = conn.recv(65536)
            except socket.timeout:
                continue
            except (ConnectionResetError, ConnectionAbortedError):
                return
            if not data:
                return
            events = peer.receive_data(data)
            for event in events:
                if isinstance(event, h2.events.RequestReceived):
                    sizes[event.stream_id] = 0
                    headers = dict(event.headers)
                    assert headers.get("client_secret") == "local-test"
                    assert headers.get("grpc-timeout")
                    if self.mode == "reset":
                        peer.reset_stream(event.stream_id, error_code=2)
                elif isinstance(event, h2.events.DataReceived):
                    sizes[event.stream_id] += len(event.data)
                    self.bytes += len(event.data)
                    peer.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                elif isinstance(event, h2.events.StreamEnded):
                    if self.mode == "reset":
                        continue
                    self.requests += 1
                    self.respond(peer, event.stream_id)
            pending = peer.data_to_send()
            if pending:
                conn.sendall(pending)
            if self.mode == "partial_frame" and self.requests:
                conn.sendall(b"\x00")
                self.stop.wait(5)
                return

    def respond(self, peer, stream):
        if self.mode in ("rpc_stall", "partial_frame"):
            return
        if self.mode == "goaway":
            peer.close_connection(error_code=0)
            return
        status = "503" if self.mode == "http_error" else "200"
        peer.send_headers(stream, [(":status", status), ("content-type", "application/grpc")])
        body = b"\x08\x01"
        if self.mode == "reject":
            body = b"\x08\x00"
        elif self.mode == "malformed_receipt":
            body = b"\x08"
        envelope = b"\0" + struct.pack(">I", len(body)) + body
        if self.mode == "truncated_message":
            envelope = b"\0\0\0\0\x08x"
        peer.send_data(stream, envelope, end_stream=self.mode == "no_trailer")
        if self.mode != "no_trailer":
            trailers = [("grpc-status", "13" if self.mode == "grpc_error" else "0")]
            if self.mode == "grpc_error":
                trailers.append(("grpc-message", "test rejection"))
            peer.send_headers(stream, trailers, end_stream=True)

    def close(self):
        self.stop.set()
        self.listener.close()
        self.thread.join(timeout=2)


def run_case(probe, name, *, mode="ok", count=1, size=128, window=65535, error=None):
    peer = Peer(mode, window)
    started = time.monotonic()
    try:
        completed = subprocess.run(
            [str(probe), "127.0.0.1", str(peer.port), str(count), str(size), "700"],
            text=True, capture_output=True, timeout=35,
        )
        duration = time.monotonic() - started
        output = completed.stdout + completed.stderr
        assert "leaked" not in output.lower(), output
        if error is None:
            assert completed.returncode == 0, (peer.errors, output)
            assert peer.requests == count, (peer.requests, count, output)
            assert peer.bytes == count * (size + 5), peer.bytes
        else:
            assert completed.returncode != 0 and error in output, output
        if mode != "reset":
            assert not peer.errors, peer.errors
        if "stall" in mode or mode == "partial_frame":
            assert duration < 3, duration
        return {"case": name, "passed": True, "elapsed_s": round(duration, 3),
                "requests": peer.requests, "request_bytes": peer.bytes}
    finally:
        peer.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", type=Path, default=Path("zig-out/bin/protocol-probe" + (".exe" if os.name == "nt" else "")))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    cases = [
        ("persistent_connection_over_64k", dict(count=160, size=1024)),
        ("tiny_stream_window", dict(count=3, size=4096, window=32)),
        ("receipt_rejection", dict(mode="reject", error="ServerRejected")),
        ("malformed_receipt", dict(mode="malformed_receipt", error="InvalidVarint")),
        ("grpc_error_after_response", dict(mode="grpc_error", error="GrpcFailure")),
        ("missing_grpc_trailer", dict(mode="no_trailer", error="GrpcFailure")),
        ("truncated_grpc_message", dict(mode="truncated_message", error="InvalidFrame")),
        ("http_error", dict(mode="http_error", error="HeaderFailure")),
        ("stream_reset", dict(mode="reset", error="ServerReset")),
        ("server_goaway", dict(mode="goaway", error="ServerGoAway")),
        ("zero_send_window_deadline", dict(window=0, error="Timeout")),
        ("handshake_deadline", dict(mode="handshake_stall", error="Timeout")),
        ("rpc_deadline", dict(mode="rpc_stall", error="Timeout")),
        ("partial_frame_deadline", dict(mode="partial_frame", error="Timeout")),
    ]
    results = []
    for name, options in cases:
        result = run_case(args.probe.resolve(), name, **options)
        results.append(result)
        print(json.dumps(result), flush=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
