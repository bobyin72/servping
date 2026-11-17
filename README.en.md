# ServPing

[![CI](https://github.com/bobyin72/servping/actions/workflows/ci.yml/badge.svg)](https://github.com/bobyin72/servping/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> A user-friendly, generalized `tcpping` — probe services over TCP/HTTP instead of ICMP, with `ping`-style output.

A single bash script. No build step, no dependencies beyond `curl`. Supports probing **many services across many hosts**.

English · [中文](README.md)

---

## Why not `ping` / `tcpping`

| Tool | Tells you | Doesn't tell you |
|---|---|---|
| `ping` | host is up | ICMP is often blocked; nothing about ports or services |
| `tcpping` | TCP port accepts a handshake | whether the service actually **works** (HTTP status, response body); no multi-service management |
| **ServPing** | port is open **and** the service is right (status code / body); named multi-host config; ping-like stats | — |

## Features

- **ping-like output**: `PING ... bytes from ... time=x ms`, plus `min/avg/max/stddev` and a verdict line
- **Two liveness semantics**: `proto=http` checks HTTP 200 (optionally a body keyword); `proto=tcp` checks the three-way handshake only
- **Named host address book**: `ServPing nas git` — host first, then service; the two tables are orthogonal
- **Loud on bad config**: malformed lines fail with an **exit code 2 and a line number**, plus a copy-pasteable fix
- **Portable**: works on macOS's stock bash 3.2 and on Linux (no associative arrays, no `date +%N`)
- **Self-test suite**: 40 assertions, all on loopback, no network required

## Quick start

```bash
git clone https://github.com/bobyin72/servping.git
cd servping
sudo install -m 755 ServPing /usr/local/bin/ServPing
```

Minimal config (or generate it entirely from the CLI):

```bash
ServPing -a Host "NAS"   192.168.1.10
ServPing -a Host "Local" 127.0.0.1
ServPing -a ServPort "Web" 80   "NAS web UI"
ServPing -a ServPort "Git" 3000 "Gitea" http "Gitea"
ServPing -a ServPort "SSH" 22   "SSH"   tcp

ServPing nas git        # Gitea on the NAS
ServPing local ssh      # SSH on localhost (handshake only)
```

```
$ ServPing nas git
PING Gitea (NAS 192.168.1.10:3000) [http]: 4 probes
# config: /usr/local/etc/servping.conf
15834 bytes from 192.168.1.10:3000: tcp_seq=0 time=12.41 ms (HTTP 200)
15834 bytes from 192.168.1.10:3000: tcp_seq=1 time=11.98 ms (HTTP 200)
...
--- 192.168.1.10:3000 ServPing statistics ---
4 probes transmitted, 4 received, 0.0% packet loss
round-trip min/avg/max/stddev = 11.98/12.17/12.41/0.17 ms
Gitea: OK
```

## Configuration

Record-oriented, one entry per line, default path `/usr/local/etc/servping.conf`.

```
Host "NAS"   192.168.1.10
Host "Local" 127.0.0.1

ServPort "Web" 80   "NAS web UI" http
ServPort "Git" 3000 "Gitea"      http "Gitea"
ServPort "SSH" 22   "SSH"        tcp
```

### Two independent tables

| Table | Meaning | CLI position |
|---|---|---|
| `Host` | address book: name → address | 1st positional argument |
| `ServPort` | service table: name → port / proto / check rule | 2nd positional argument |

They are orthogonal: the same service can be probed against **any** host. `ServPing local git` probes `127.0.0.1:3000` with the Git service definition.

### `Host` forms

```
Host "NAS" 192.168.1.10     # named (recommended)
Host 192.168.1.10           # legacy: name defaults to the address itself
```

### `ServPort` fields

| Position | Field | Notes |
|---|---|---|
| 2 | name | case-insensitive |
| 3 | port | numeric |
| 4 | description | optional, defaults to name |
| 5 | `proto` | optional, `http` (default) or `tcp` |
| 6 | body keyword | optional, `http` only |

Config lookup order: `-f` > `$SERVPING_CONFIG` > `/usr/local/etc/servping.conf`

### The single rule: **always the first one**

| Object | Rule |
|---|---|
| Default host | the **first** `Host` |
| Default service | the **first** `ServPort` |
| Duplicate host / service names | **first wins**; later duplicates stay in the file but are inert |

A malformed line **fails loudly instead of falling through**. Falling through would let the default silently drift to another entry — which is a false negative by construction: you think you're testing A, but you're testing B.

## Usage

```bash
ServPing                     # default host × default service
ServPing nas                 # NAS × default service
ServPing nas git             # NAS × Git
ServPing NAS GIT             # case-insensitive
ServPing git                 # compat: 1st word isn't a host name => treat as service
ServPing -H Local -s Web     # explicit, no ambiguity
ServPing -l                  # list hosts and services
ServPing -h                  # full help
```

### Argument disambiguation

The first positional argument is resolved as a **host name first**, and only falls back to a service name if no such host exists.

If a name is **both** a host and a service, it is treated as a host. Two ways out:

```bash
ServPing -s Git              # force it to be a service
ServPing -H Git -s Web       # make both explicit
```

### Options

| Option | Description |
|---|---|
| `-H HOST` | host by registered name or literal address |
| `-s SERVICE` | service name |
| `-c N` | probe count (default 4) |
| `-i SEC` | interval (default 1) |
| `-W SEC` | per-probe timeout (default 5) |
| `-p PORT` | override port for this run (not persisted) |
| `-f FILE` | config file |
| `-t` | force tcp mode for this run |
| `-a TYPE ...` | append config: `Host` / `ServPort` |
| `-rm` | delete the config file |
| `-l` | list hosts and services |
| `-V` / `-h` | version / help |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | all probes succeeded |
| 1 | at least one failed (including all failed) |
| 2 | bad arguments or bad config |

## Two different `time=` semantics — don't compare them

| proto | `time=` measures | Comparable to |
|---|---|---|
| `http` | TCP connect + request round trip + response transfer | end-to-end latency |
| `tcp` | TCP three-way handshake only | `ping` / `tcpping` |

The mode is printed in brackets: `[http]` or `[tcp]`.

### How `tcp` decides success

Success means: **curl exit code 0, or `%{time_connect}` is non-zero** (non-zero implies `connect()` returned successfully).

So when a service accepts the connection but never speaks HTTP (SSH, MySQL, Redis), curl reports 52 / 56 / 28 — **but the handshake succeeded, so it counts as up.** That's exactly what tcp mode is for. Conversely:

- `Connection refused` → down
- `Could not resolve host` → down
- connect timeout (`time_connect` is 0) → down

## Self-test

```bash
tests/selftest.sh
```

40 assertions in two groups:

- **Group 1** config and CLI semantics (no network): malformed-line handling, default selection, duplicate rules, `-a` write formats, error exit codes
- **Group 2** real probing (needs `python3` to spin up local HTTP / silent TCP servers): HTTP 200, body match/mismatch, tcp handshake, closed port

Without `python3`, group 2 is skipped and group 1 still runs. Exit code 0 means no failures.

## Known limitations

- `tcp` mode does **not** validate the protocol: an open port serving the wrong thing looks healthy. Use `http` + a body keyword when that matters.
- No concurrency: one service per invocation (deliberate — this is a per-probe, ping-like tool).
- `-p` / `-H` affect the current run only, never the config file.
- Relies on curl's `%{time_connect}`; very old curl (< 7.19) may not support it.

## License

[MIT](LICENSE)
