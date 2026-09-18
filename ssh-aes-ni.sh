#!/bin/sh
# ssh-aesni.sh — benchmark the SSH AES ciphers that are AES-NI accelerated.
#   * kernel modes : enumerated from `sysctl -a` (BSD/macOS) or /proc/crypto (Linux)
#   * candidates   : `ssh -Q cipher` FILTERED THROUGH the kernel probe (no static list)
#   * benchmark    : OpenSSL WITH vs WITHOUT AES-NI, throughput in Mbps, fastest->slowest
#   * accuracy     : pinned to one core; the CPU clock read is that same core's clock
#
# Usage:  [PIN=N] [sudo] sh ssh-aesni.sh
#   PIN=N  pin the benchmark to core N (default: last core). sudo needed on Apple
#          Silicon for live frequency via powermetrics.

THRESHOLD=130      # WITH must be >= 1.30x WITHOUT to call the toggle "working"
SW_TIER=500000     # internal units (1000s of bytes/sec) = 500 MB/s
command -v ssh >/dev/null 2>&1 || { echo "ssh not found" >&2; exit 1; }

# --- small helpers ---------------------------------------------------------
# Kernel names counter mode ICM; ssh/openssl call it CTR. Naming bridge only.
norm_mode() { echo "$1" | tr 'a-z' 'A-Z' | sed 's/^ICM$/CTR/'; }
ssh_mode()  { echo "${1%@*}" | sed -E 's/^aes[0-9]+-?([a-z0-9]+)$/\1/; s/^rijndael-(cbc)$/\1/'; }
evp_name()  {
    c=${1%@*}; [ "$c" = rijndael-cbc ] && { echo aes-256-cbc; return; }
    echo "$c" | sed -E 's/^aes([0-9]+)-?([a-z0-9]+)$/aes-\1-\2/'
}

max_core_mhz() {   # highest current freq across all cores (no-pin / fallback)
    case "$(uname -s)" in
        FreeBSD|*BSD)
            i=0; while [ "$i" -lt "$ncpu" ]; do sysctl -n dev.cpu.$i.freq 2>/dev/null; i=$((i+1)); done \
                | sort -rn | head -n1 ;;
        Linux)
            cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null \
                | sort -rn | head -n1 | awk '{printf "%.0f",$1/1000}' ;;
    esac
}

cpu_mhz() {        # current clock of the PINNED core (fallback: max core/cluster)
    m=""
    case "$(uname -s)" in
        FreeBSD|*BSD)
            [ -n "$PINCMD" ] && m=$(sysctl -n dev.cpu.$PIN.freq 2>/dev/null)
            [ -z "$m" ] && m=$(max_core_mhz) ;;
        Linux)
            if [ -n "$PINCMD" ] && [ -r /sys/devices/system/cpu/cpu$PIN/cpufreq/scaling_cur_freq ]; then
                m=$(awk '{printf "%.0f",$1/1000}' /sys/devices/system/cpu/cpu$PIN/cpufreq/scaling_cur_freq)
            fi
            [ -z "$m" ] && m=$(max_core_mhz) ;;
        Darwin)
            if [ "$(uname -m)" = arm64 ]; then
                # Apple Silicon: live freq via powermetrics (root). Highest active cluster.
                [ "$(id -u)" -eq 0 ] && m=$(powermetrics --samplers cpu_power -i1000 -n1 2>/dev/null \
                    | awk '/[Ff]requency:/ && /MHz/ {for(i=1;i<=NF;i++) if($i=="MHz"){v=$(i-1)+0; if(v>mx)mx=v}} END{if(mx)printf "%.0f",mx}')
            else
                f=$(sysctl -n hw.cpufrequency 2>/dev/null)   # Intel: Hz
                [ -n "$f" ] && m=$(awk -v f="$f" 'BEGIN{printf "%.0f",f/1000000}')
            fi ;;
    esac
    [ -n "$m" ] && echo "$m" || echo "n/a"
}

# --- 1. Enumerate accelerated AES modes from the kernel (no static OID) -----
kernel_modes() {
    { if [ -r /proc/crypto ]; then
        awk '/^name[ \t]*:/{n=$3}/^driver[ \t]*:/{if($3~/aesni/)print n}' /proc/crypto \
            | grep -oiE '[a-z0-9_]+\(aes\)' | sed -E 's/\(aes\)//; s/^_+//'
      else
        sysctl -a 2>/dev/null | grep -i aes | grep -oiE 'AES-[A-Za-z]+' | sed -E 's/^[Aa][Ee][Ss]-//'
      fi
    } | while IFS= read -r m; do norm_mode "$m"; done | sort -u
}
kmodes=$(kernel_modes)
[ -n "$kmodes" ] && have_kernel=yes || have_kernel=no

ssh_ciphers=$(ssh -Q cipher 2>/dev/null | grep -i aes)
[ -z "$ssh_ciphers" ] && { echo "ssh reports no AES ciphers."; exit 0; }
ssh_modes=$(for c in $ssh_ciphers; do norm_mode "$(ssh_mode "$c")"; done | sort -u)

# --- 2. Filter ssh -Q cipher THROUGH the kernel probe -----------------------
accel_ciphers=""
for c in $ssh_ciphers; do
    m=$(norm_mode "$(ssh_mode "$c")")
    if [ "$have_kernel" = yes ]; then echo "$kmodes" | grep -qx "$m" || continue; fi
    accel_ciphers="$accel_ciphers $c"
done
accel_modes=$(for c in $accel_ciphers; do norm_mode "$(ssh_mode "$c")"; done | sort -u)
candidates=$(for c in $accel_ciphers; do evp_name "$c"; done | sort -u)

echo "SSH AES modes (ssh -Q cipher):        $(echo $ssh_modes | tr '\n' ' ')"
if [ "$have_kernel" = yes ]; then
    echo "Kernel accelerated modes (sysctl):    $(echo $kmodes | tr '\n' ' ')"
    echo "Accelerated (ssh filtered by kernel): $(echo $accel_modes | tr '\n' ' ')"
else
    if sysctl -a 2>/dev/null | grep -qiE 'features.*AES|FEAT_AES'; then f=present; else f="not detected"; fi
    echo "No per-mode kernel crypto enumeration on $(uname -s) (CPU AES: $f); using all SSH AES ciphers."
fi
[ -z "$candidates" ] && { echo; echo "No SSH AES ciphers pass the kernel filter."; exit 0; }

# --- pin the benchmark to one core so the clock we read == the core that ran -
PIN=${PIN:-}
ncpu=$( sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1 )
[ -z "$PIN" ] && PIN=$((ncpu-1))     # default last core (cpu0 tends to service IRQs)
PINCMD=""
case "$(uname -s)" in
    FreeBSD|*BSD) command -v cpuset  >/dev/null 2>&1 && PINCMD="cpuset -l $PIN" ;;
    Linux)        command -v taskset >/dev/null 2>&1 && PINCMD="taskset -c $PIN" ;;
esac
[ -n "$PINCMD" ] \
    && echo "Pinned to CPU $PIN ($PINCMD) — reading that core's clock." \
    || echo "No CPU pinning here — reading the max core/cluster clock."
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] && [ "$(id -u)" -ne 0 ] && \
    echo "  (Apple Silicon: run with sudo for live frequency via powermetrics.)"
echo "Idle CPU clock: $(cpu_mhz) MHz"; echo

# --- 3. Pick a toggle-capable openssl (real OpenSSL, not LibreSSL) ----------
is_libre() { "$1" version 2>/dev/null | grep -qi libressl; }
pick_openssl() {
    p0=$(command -v openssl 2>/dev/null)
    [ -n "$p0" ] && ! is_libre "$p0" && { echo "$p0"; return; }
    for p in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl \
             /opt/homebrew/bin/openssl /usr/local/bin/openssl /usr/bin/openssl; do
        [ -x "$p" ] && ! is_libre "$p" && { echo "$p"; return; }
    done
    echo "$p0"
}
OSSL=$(pick_openssl)
[ -n "$OSSL" ] || { echo "openssl not found" >&2; exit 1; }
echo "Using openssl: $OSSL — $("$OSSL" version 2>/dev/null)"; echo

# $PINCMD is intentionally unquoted so it expands to nothing when empty.
speed_line() {
    if [ -n "$1" ]; then
        OPENSSL_ia32cap="$1" $PINCMD "$OSSL" speed -elapsed -seconds 1 -evp "$2" 2>/dev/null \
            | grep -i "^$2" | tail -n 1
    else
        ( unset OPENSSL_ia32cap; $PINCMD "$OSSL" speed -elapsed -seconds 1 -evp "$2" 2>/dev/null ) \
            | grep -i "^$2" | tail -n 1
    fi
}
peak() { echo "$1" | awk '{v=$NF; sub(/[kK]$/,"",v); print v+0}'; }   # internal units
NOAES="~0x200000000000000"          # clears the AES-NI capability bit (word 0, bit 57)

# --- 4. Confirm the userspace toggle actually works ------------------------
toggle_works=no
if ! is_libre "$OSSL"; then
    for a in $candidates; do
        w=$(speed_line "" "$a"); [ -z "$w" ] && continue
        o=$(speed_line "$NOAES" "$a")
        if awk -v w="$(peak "$w")" -v o="$(peak "$o")" -v t="$THRESHOLD" \
               'BEGIN{exit !(o>0 && w*100/o>=t)}'; then toggle_works=yes; break; fi
    done
fi
[ "$toggle_works" = yes ] \
    && echo "OpenSSL AES-NI toggle: working — real WITH vs WITHOUT below." \
    || echo "OpenSSL AES-NI toggle: unavailable — WITHOUT will match WITH."
echo

# --- 5. Benchmark (live progress + per-cipher clock stamp) -----------------
tmp=$(mktemp "${TMPDIR:-/tmp}/aesni.XXXXXX") || exit 1
maxpeak=0
echo "Benchmarking (live):"
for a in $candidates; do
    w=$(speed_line "" "$a")
    mhz=$(cpu_mhz)                                  # clock at moment of measurement
    if [ -z "$w" ]; then echo "  $a: unsupported by this openssl — skipped"; continue; fi
    wp=$(peak "$w")
    peak_mbps=$(awk -v v="$wp" 'BEGIN{printf "%.0f", v*0.008}')
    printf '  %-16s peak %6s Mbps   @ CPU %5s MHz\n' "$a" "$peak_mbps" "$mhz"
    awk -v m="$maxpeak" -v p="$wp" 'BEGIN{exit !(p>m)}' && maxpeak=$wp
    if [ "$toggle_works" = yes ]; then o=$(speed_line "$NOAES" "$a"); else o="-"; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$wp" "$a" "$w" "$o" "$mhz" >> "$tmp"
done
echo

# --- 6. WITH/WITHOUT comparison in Mbps, fastest -> slowest ----------------
echo "=== AES-NI ciphers: WITH vs WITHOUT (fastest -> slowest) ==="
echo "Throughput in Mbps (megabits/sec); for MB/s divide by 8. CPU clock sampled per cipher."
printf '    %-14s %13s %13s %13s %13s %13s %13s\n' \
       "block size" "16 B" "64 B" "256 B" "1 KiB" "8 KiB" "16 KiB"
TAB=$(printf '\t')
row='function mbps(x,  v){v=x; sub(/[kK]$/,"",v); return (v+0)*0.008}
     {printf "    %-14s %13.1f %13.1f %13.1f %13.1f %13.1f %13.1f\n", L,mbps($2),mbps($3),mbps($4),mbps($5),mbps($6),mbps($7)}'
sort -t "$TAB" -k1,1 -rn "$tmp" | while IFS="$TAB" read -r key cipher wline oline mhz; do
    printf '  %s   [CPU %s MHz]\n' "$cipher" "$mhz"
    echo "$wline" | awk -v L="with AES-NI" "$row"
    if [ "$oline" = "-" ]; then
        printf '    %-14s %13s\n' "without" "(toggle unavailable)"
    else
        echo "$oline" | awk -v L="without" "$row"
        sp=$(awk -v w="$(peak "$wline")" -v o="$(peak "$oline")" \
                 'BEGIN{ if(o>0) printf "%.2f", w/o; else printf "n/a" }')
        printf '    %-14s %12sx\n' "peak speedup" "$sp"
    fi
done
echo "Final CPU clock: $(cpu_mhz) MHz"
if awk -v m="$maxpeak" -v s="$SW_TIER" 'BEGIN{exit !(m<s)}'; then
    echo "NOTE: native peak is $(awk -v m=$maxpeak 'BEGIN{printf "%.0f",m*0.008}') Mbps — verify AES-NI is engaging."
fi
rm -f "$tmp"
