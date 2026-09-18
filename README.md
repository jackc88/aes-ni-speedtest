# aes-ni-speedtest

A POSIX `sh` script that benchmarks the SSH AES ciphers your machine can hardware-accelerate via **AES-NI**, then compares OpenSSL throughput **with** vs **without** the acceleration engaged.

It doesn't rely on a hardcoded cipher list. It enumerates the AES modes your kernel actually accelerates, filters `ssh -Q cipher` through that probe, and benchmarks only the survivors — so the results reflect your specific CPU, kernel, and OpenSSL build.

> Written with AI assistance.

## What it does

- **Enumerates kernel-accelerated AES modes** from `/proc/crypto` (Linux) or `sysctl` (macOS/BSD).
- **Filters `ssh -Q cipher`** through that probe — no static cipher list.
- **Benchmarks with OpenSSL** (`openssl speed -evp`), measuring each cipher WITH and WITHOUT AES-NI by toggling the `OPENSSL_ia32cap` capability bit.
- **Pins to a single core** so the CPU clock it reports is the same core that ran the benchmark.
- **Reports throughput in Mbps**, fastest → slowest, with a per-cipher clock stamp and a peak speedup factor.

## Requirements

- `ssh` (for `ssh -Q cipher`)
- **Real OpenSSL 3.x** — *not* LibreSSL. The AES-NI toggle relies on `OPENSSL_ia32cap`, which LibreSSL doesn't support. On macOS, install via Homebrew (`brew install openssl@3`); the script auto-detects common Homebrew paths.
- Optional, for accurate core pinning: `taskset` (Linux) or `cpuset` (FreeBSD/BSD). Without them the script falls back to reading the max core/cluster clock.
- On **Apple Silicon**, `sudo` is needed to read live frequency via `powermetrics`.

## Usage

```sh
[PIN=N] [sudo] sh ssh-aes-ni.sh
```

| Variable | Description |
|----------|-------------|
| `PIN=N`  | Pin the benchmark to core `N`. Defaults to the last core (`cpu0` tends to service interrupts). |

Examples:

```sh
# Default run
sh ssh-aes-ni.sh

# Pin to core 3
PIN=3 sh ssh-aes-ni.sh

# Apple Silicon, with live frequency readings
sudo sh ssh-aes-ni.sh
```

## Sample output

```
SSH AES modes (ssh -Q cipher):        cbc ctr gcm
Kernel accelerated modes (sysctl):    cbc ctr gcm
Accelerated (ssh filtered by kernel): cbc ctr gcm
Pinned to CPU 7 (taskset -c 7) — reading that core's clock.
Idle CPU clock: 3800 MHz

Using openssl: /usr/bin/openssl — OpenSSL 3.0.13 30 Jan 2024

OpenSSL AES-NI toggle: working — real WITH vs WITHOUT below.

Benchmarking (live):
  aes-128-gcm      peak  58210 Mbps   @ CPU  4600 MHz
  aes-256-gcm      peak  49760 Mbps   @ CPU  4600 MHz
  aes-128-ctr      peak  55840 Mbps   @ CPU  4600 MHz
  aes-256-ctr      peak  47120 Mbps   @ CPU  4600 MHz
  aes-128-cbc      peak  52310 Mbps   @ CPU  4600 MHz
  aes-256-cbc      peak  44580 Mbps   @ CPU  4600 MHz

=== AES-NI ciphers: WITH vs WITHOUT (fastest -> slowest) ===
Throughput in Mbps (megabits/sec); for MB/s divide by 8. CPU clock sampled per cipher.
    block size              16 B          64 B         256 B         1 KiB         8 KiB        16 KiB
  aes-128-gcm   [CPU 4600 MHz]
    with AES-NI          4210.3        14980.6       38220.1       51330.4       57890.2       58210.7
    without               980.1         2410.5        4980.3        6120.7        6540.2        6580.9
    peak speedup            8.84x
  aes-128-ctr   [CPU 4600 MHz]
    with AES-NI          4020.6        14310.2       36980.5       49870.1       55210.8       55840.3
    without               940.3         2330.1        4820.6        5990.4        6410.7        6450.2
    peak speedup            8.66x
Final CPU clock: 3800 MHz
```

## Reading the output

- **Throughput is in Mbps** (megabits/sec). Divide by 8 for MB/s.
- **`peak speedup`** is the WITH-AES-NI throughput divided by WITHOUT. A working toggle typically shows several-x speedup; the script treats ≥1.30x as "working."
- If OpenSSL can't toggle AES-NI (e.g. LibreSSL), the WITHOUT column shows `(toggle unavailable)` and matches WITH.
- A `NOTE:` line appears if native peak throughput is under ~500 MB/s, suggesting AES-NI may not be engaging.

## Accuracy notes

CPU frequency stepping/boost can skew results. For a clean run, disable frequency scaling and lock the CPU to its highest frequency where your OS allows it. The script samples the clock at the start and per-cipher so you can spot drift.

## Platform support

Linux, macOS (Intel & Apple Silicon), and FreeBSD/BSD. Frequency detection and core pinning adapt per platform; the benchmark itself runs anywhere real OpenSSL is available.

## License

Released under the [MIT License](LICENSE).
