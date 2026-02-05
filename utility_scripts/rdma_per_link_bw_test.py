#!/usr/bin/env python3
"""
rdma_per_link_bw_test.py

Controller-orchestrated per-RDMA-interface bandwidth test using perftest `ib_write_bw`.

Per rdmaX:
- Discover mlx5 device mapping via ibdev2netdev on server + peer
- Use server rdmaX IP to force traffic on the intended interface
- Start ib_write_bw server bound to mlx5 device
- Run client bound to peer mlx5 device
- Robustly parse BW average[Gb/sec]
- Print results in a table
"""

import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

# ---------------------------
# Regex / constants
# ---------------------------

IBDEV_LINE_RE = re.compile(
    r"^(?P<dev>mlx5_\d+)\s+port\s+(?P<port>\d+)\s+==>\s+(?P<netdev>\S+)\s+\((?P<state>Up|Down)\)$",
    re.IGNORECASE,
)

SERVER_LOG_DIR = "/tmp"

# ---------------------------
# Data structures
# ---------------------------

@dataclass
class MapEntry:
    dev: str
    port: int
    netdev: str
    state: str

# ---------------------------
# Utility helpers
# ---------------------------

def run(cmd: List[str], timeout: int = 60) -> Tuple[int, str, str]:
    p = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

def ssh(host: str, remote_cmd: str, timeout: int = 60) -> Tuple[int, str, str]:
    return run(
        ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", host, remote_cmd],
        timeout=timeout,
    )

def must(rc: int, out: str, err: str, msg: str) -> str:
    if rc != 0:
        raise RuntimeError(f"{msg} failed (rc={rc})\nSTDOUT:\n{out}\nSTDERR:\n{err}")
    return out

def expand_nodelist(nodelist: str) -> List[str]:
    rc, out, err = run(["scontrol", "show", "hostnames", nodelist], timeout=10)
    if rc != 0:
        raise RuntimeError(f"scontrol show hostnames failed for {nodelist}\nSTDOUT:\n{out}\nSTDERR:\n{err}")
    return [line.strip() for line in out.splitlines() if line.strip()]

def get_idle_nodes(partition: Optional[str], exclude: Optional[str] = None) -> List[str]:
    cmd = ["sinfo", "-h", "-o", "%N %t"]
    if partition:
        cmd += ["-p", partition]
    rc, out, err = run(cmd, timeout=15)
    if rc != 0:
        raise RuntimeError(f"sinfo failed\nSTDOUT:\n{out}\nSTDERR:\n{err}")

    idle_nodes: List[str] = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        nodelist, state = parts[0], parts[1].lower()
        if not state.startswith("idle"):
            continue
        idle_nodes.extend(expand_nodelist(nodelist))
    nodes = sorted(set(idle_nodes))
    if exclude:
        nodes = [n for n in nodes if n != exclude]
    return nodes

# ---------------------------
# RDMA discovery
# ---------------------------

def parse_ibdev2netdev(text: str) -> List[MapEntry]:
    entries: List[MapEntry] = []
    for line in text.splitlines():
        line = line.strip()
        m = IBDEV_LINE_RE.match(line)
        if not m:
            continue
        entries.append(
            MapEntry(
                dev=m.group("dev"),
                port=int(m.group("port")),
                netdev=m.group("netdev"),
                state=m.group("state"),
            )
        )
    return entries

def is_rdma_netdev(netdev: str) -> bool:
    return netdev.lower().startswith(("rdma", "ib"))

def get_ipv4(host: str, netdev: str) -> Optional[str]:
    rc, out, _ = ssh(
        host,
        f"ip -4 -o addr show dev {shlex.quote(netdev)} | awk '{{print $4}}' | cut -d/ -f1 | head -n1",
        timeout=15,
    )
    if rc != 0:
        return None
    return out.strip() if out.strip() else None

# ---------------------------
# Perftest helpers
# ---------------------------

def parse_bw_average_gbits(text: str) -> Optional[float]:
    lines = text.splitlines()
    header_idx = None

    for i, line in enumerate(lines):
        if "BW average[Gb/sec]" in line:
            header_idx = i
            break

    if header_idx is None:
        return None

    for j in range(header_idx + 1, min(header_idx + 10, len(lines))):
        row = lines[j].strip()
        if not row or set(row) <= {"-", " "}:
            continue
        parts = row.split()
        if len(parts) >= 4:
            try:
                return float(parts[3])
            except ValueError:
                pass
    return None

def start_server(host: str, dev: str, port: int, tcp_port: int) -> Tuple[int, str]:
    log_path = f"{SERVER_LOG_DIR}/ib_write_bw_{dev}_p{port}_{tcp_port}.log"
    cmd = (
        "bash -lc " + shlex.quote(
            f"sudo -n ib_write_bw -d {dev} -i {port} -p {tcp_port} "
            f"--report_gbits --run_infinitely > {log_path} 2>&1 & echo $!"
        )
    )
    rc, out, err = ssh(host, cmd, timeout=20)
    must(rc, out, err, "Starting server")
    return int(out.strip()), log_path

def stop_pid(host: str, pid: int) -> None:
    ssh(host, f"sudo -n kill -9 {pid} >/dev/null 2>&1 || true", timeout=10)

def run_client(
    host: str,
    dev: str,
    port: int,
    server_ip: str,
    tcp_port: int,
    duration: int,
) -> Tuple[Optional[float], str]:

    cmd = (
        "bash -lc " + shlex.quote(
            f"sudo -n ib_write_bw -d {dev} -i {port} -p {tcp_port} "
            f"{server_ip} --report_gbits -D {duration} 2>&1"
        )
    )
    rc, out, err = ssh(host, cmd, timeout=duration + 30)
    output = (out + "\n" + err).strip()

    bw = parse_bw_average_gbits(output)
    return bw, output

def run_client_with_spinner(
    host: str,
    dev: str,
    port: int,
    server_ip: str,
    tcp_port: int,
    duration: int,
) -> Tuple[Optional[float], str]:
    stop = threading.Event()

    def spinner() -> None:
        while not stop.is_set():
            print(".", end="", flush=True)
            time.sleep(1)

    t = threading.Thread(target=spinner, daemon=True)
    t.start()
    try:
        return run_client(host, dev, port, server_ip, tcp_port, duration)
    finally:
        stop.set()
        t.join(timeout=2)
        print("", flush=True)

# ---------------------------
# Display helpers
# ---------------------------

def print_table(rows: List[Dict[str, str]]) -> None:
    cols = list(rows[0].keys())
    widths = {c: max(len(c), max(len(str(r[c])) for r in rows)) for c in cols}

    print(" | ".join(c.ljust(widths[c]) for c in cols))
    print("-+-".join("-" * widths[c] for c in cols))

    for r in rows:
        print(" | ".join(str(r[c]).ljust(widths[c]) for c in cols))

# ---------------------------
# Main
# ---------------------------

def main() -> int:
    server = input("server_host (runs server): ").strip()
    peer = input("peer_host   (runs client) [or 'idle']: ").strip()
    if not peer or peer.lower() == "idle":
        partition = input("partition for idle lookup (optional): ").strip()
        idle_nodes = get_idle_nodes(partition or None, exclude=server)
        if not idle_nodes:
            raise RuntimeError("No idle nodes found")
        print("\nIdle nodes:")
        for i, node in enumerate(idle_nodes, start=1):
            print(f"{i}. {node}")
        sel = input("select peer by number or hostname: ").strip()
        if sel.isdigit():
            idx = int(sel) - 1
            if idx < 0 or idx >= len(idle_nodes):
                raise RuntimeError("Invalid selection index")
            peer = idle_nodes[idx]
        else:
            if sel not in idle_nodes:
                raise RuntimeError("Selection not in idle node list")
            peer = sel

    rc, out, err = ssh(server, "ibdev2netdev")
    server_map = must(rc, out, err, "ibdev2netdev server")
    rc, out, err = ssh(peer, "ibdev2netdev")
    peer_map = must(rc, out, err, "ibdev2netdev peer")

    server_entries = [e for e in parse_ibdev2netdev(server_map) if e.state == "Up" and is_rdma_netdev(e.netdev)]
    peer_entries = [e for e in parse_ibdev2netdev(peer_map) if e.state == "Up" and is_rdma_netdev(e.netdev)]

    srv_by_netdev = {e.netdev: e for e in server_entries}
    peer_by_netdev = {e.netdev: e for e in peer_entries}

    common_netdevs = sorted(set(srv_by_netdev) & set(peer_by_netdev))

    if not common_netdevs:
        raise RuntimeError("No common RDMA netdevs between server and peer")

    results = []
    pids = []

    def cleanup(*_):
        for pid in pids:
            stop_pid(server, pid)
        ssh(server, "sudo -n pkill -f ib_write_bw >/dev/null 2>&1 || true")

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    base_port = 18515
    duration = 10

    total = len(common_netdevs)
    for idx, netdev in enumerate(common_netdevs):
        srv = srv_by_netdev[netdev]
        cli = peer_by_netdev[netdev]
        ip = get_ipv4(server, netdev)

        if not ip:
            continue

        tcp_port = base_port + idx
        print(f"[{idx + 1}/{total}] testing {netdev} (server {server} -> peer {peer})...", flush=True)
        pid, _ = start_server(server, srv.dev, srv.port, tcp_port)
        pids.append(pid)
        time.sleep(0.5)

        bw, output = run_client_with_spinner(peer, cli.dev, cli.port, ip, tcp_port, duration)
        stop_pid(server, pid)

        results.append({
            "netdev": netdev,
            "server_dev": f"{srv.dev}:{srv.port}",
            "server_ip": ip,
            "peer_dev": f"{cli.dev}:{cli.port}",
            "bw_avg_gbps": f"{bw:.2f}" if bw is not None else "FAIL",
        })

        if bw is None:
            print(f"\nFAIL {netdev} – client output tail:\n")
            print("\n".join(output.splitlines()[-30:]))

    cleanup()

    print("\nResults:\n")
    print_table(results)
    return 0

# ---------------------------

if __name__ == "__main__":
    sys.exit(main())
