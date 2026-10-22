#!/usr/bin/env python3
"""Local HTTP CONNECT proxy with a hot-swappable upstream.

The client (OpenCode/Bun) only ever talks to 127.0.0.1:PORT. For each
CONNECT it reads /tmp/lab/upstream:

    direct          -> connect to the requested host:port (normal DNS)
    <ip>:<port>     -> connect to that relay instead (only for the relay target)

TLS is end-to-end: this process only forwards bytes, it never terminates TLS.

Control files:
    /tmp/lab/upstream   one line: "direct" or "ip:port"
    /tmp/lab/epoch      integer; when it changes, all live tunnels are closed
                        so the client has to open a new CONNECT (which then
                        picks up the new upstream)

Every accepted CONNECT is logged to stdout:
    connect <iso-time> target=<host:port> upstream=<direct|ip:port>
"""
import os
import socket
import sys
import threading
import time

PORT = int(os.environ.get("PROXY_PORT", "8080"))
UPSTREAM_FILE = os.environ.get("UPSTREAM_FILE", "/tmp/lab/upstream")
EPOCH_FILE = os.environ.get("EPOCH_FILE", "/tmp/lab/epoch")
RELAY_TARGET = os.environ.get("RELAY_TARGET", "opencode.ai:443")
RELAY_ALL = os.environ.get("RELAY_ALL", "0") == "1"

lock = threading.Lock()
active = []  # list of (client, upstream)
current_epoch = 0


def read_upstream():
    try:
        with open(UPSTREAM_FILE, encoding="utf-8") as f:
            return f.readline().strip() or "direct"
    except OSError:
        return "direct"


def read_epoch():
    try:
        with open(EPOCH_FILE, encoding="utf-8") as f:
            return int(f.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def close_all():
    with lock:
        socks = []
        for c, u in active:
            socks.extend([c, u])
        active.clear()
    for s in socks:
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            s.close()
        except OSError:
            pass


def watch_epoch():
    global current_epoch
    while True:
        e = read_epoch()
        if e != current_epoch:
            current_epoch = e
            print(f"epoch {e}: closing live tunnels", flush=True)
            close_all()
        time.sleep(0.4)


def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def read_headers(sock):
    data = b""
    while b"\r\n\r\n" not in data and len(data) < 65536:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    return data


def handle(client):
    upstream = None
    try:
        client.settimeout(20)
        head = read_headers(client)
        if not head:
            client.close()
            return
        first = head.split(b"\r\n", 1)[0].decode("latin1", "replace")
        if not first.upper().startswith("CONNECT "):
            client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            client.close()
            return
        target = first.split()[1]
        if ":" in target:
            host, port_s = target.rsplit(":", 1)
            port = int(port_s)
        else:
            host, port = target, 443

        up = read_upstream()
        use_relay = up != "direct" and (RELAY_ALL or target == RELAY_TARGET)
        if use_relay:
            ip, rport_s = up.rsplit(":", 1)
            upstream = socket.create_connection((ip, int(rport_s)), timeout=15)
            label = up
        else:
            upstream = socket.create_connection((host, port), timeout=15)
            label = "direct"

        print(
            f"connect {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} "
            f"target={target} upstream={label}",
            flush=True,
        )
        client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        client.settimeout(None)
        upstream.settimeout(None)
        with lock:
            active.append((client, upstream))
        threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
        pipe(upstream, client)
    except Exception as exc:  # noqa: BLE001
        print(f"error target={locals().get('target', '?')} {exc}", flush=True)
        try:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        except OSError:
            pass
    finally:
        for s in (client, upstream):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass
        with lock:
            active[:] = [(c, u) for (c, u) in active if c is not client]


def main():
    global current_epoch
    current_epoch = read_epoch()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(256)
    print(f"proxy listening 127.0.0.1:{PORT} relay_target={RELAY_TARGET} relay_all={RELAY_ALL}", flush=True)
    threading.Thread(target=watch_epoch, daemon=True).start()
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
