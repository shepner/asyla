#!/usr/bin/python3 -u
"""netconsole receiver on vmh03 (asyla-hosts vmh/setup.sh, part netconsole-rx).

Usage: asyla-netconsole-rx PORT LOGDIR NAME=IP...
Appends each UDP datagram from a known sender to LOGDIR/NAME.log, one line per kernel line, each
prefixed with the receive time (UTC, ms). Datagrams from other addresses are dropped (nft drops
them first). The file is opened per datagram, so logrotate needs no signal.
"""
import socket
import sys
import time


def main():
    port, logdir = int(sys.argv[1]), sys.argv[2]
    senders = {ip: name for name, ip in (a.split("=", 1) for a in sys.argv[3:])}
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", port))
    print(f"listening on UDP {port} for {', '.join(f'{n}={ip}' for ip, n in senders.items())}")
    while True:
        data, (ip, _) = s.recvfrom(65535)
        name = senders.get(ip)
        if name is None:
            continue
        now = time.time()
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + f".{int(now * 1000) % 1000:03d}Z"
        lines = data.decode("utf-8", "replace").splitlines() or [""]
        with open(f"{logdir}/{name}.log", "a", encoding="utf-8") as f:
            f.writelines(f"{stamp} {line}\n" for line in lines)


if __name__ == "__main__":
    main()
