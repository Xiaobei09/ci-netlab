#!/usr/bin/env python3
"""Local TCP forwarder: 127.0.0.1:443 -> relay_ip:relay_port (raw TLS passthrough)."""
import socket
import sys
import threading


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


def handle(client, ip, port):
    try:
        upstream = socket.create_connection((ip, port), timeout=15)
    except OSError as exc:
        print(f"connect-fail {ip}:{port} {exc}", flush=True)
        client.close()
        return
    print(f"connect {ip}:{port}", flush=True)
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    pipe(upstream, client)


def main():
    ip = sys.argv[1]
    port = int(sys.argv[2])
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 443))
    srv.listen(200)
    print(f"forward 127.0.0.1:443 -> {ip}:{port}", flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client, ip, port), daemon=True).start()


if __name__ == "__main__":
    main()
