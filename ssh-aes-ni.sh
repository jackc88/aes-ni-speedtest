#!/usr/bin/env sh
# ssh-aesni.sh — accelerated SSH AES ciphers in Mbps, with per-cipher CPU clock.
#   * kernel modes: from `sysctl -a` (BSD/macOS) or /proc/crypto (Linux)
#   * candidates:   `ssh -Q cipher` FILTERED THROUGH the kernel probe
#   * confirmation: OpenSSL WITH/WITHOUT benchmark, each stamped with live MHz
#      Script by Gemni - Google AI
THRESHOLD=130
SW_TIER=500000
command -v ssh >/dev/null 2>&1 || { echo "ssh not found" >&2; exit 1; }

norm_mode() { echo "$1" | tr 'a-z' 'A-Z' | sed 's/^ICM$/CTR/'; }
ssh_mode()  { echo "${1%@*}" | sed -E 's/^aes[0-9]+-?([a-z0-9]+)$/\1/; s/^rijndael-(cbc)$/\1/'; }
evp_name()  {
    c=${1%@*}; [ "$c" = rijndael-cbc ] && { echo aes-256-cbc; return; }
    echo "$c" | sed -E 's/^aes([0-9]+)-?([a-z0-9]+)$/aes-\1-\2/'
}

# Live current CPU frequency in MHz (best effort per platform).
cpu_mhz() {
    m=""
    case "$(uname -s)" in
        FreeBSD|*BSD) m=$(sysctl -n dev.cpu.0.freq 2>/dev/null) ;;
        Linux)
            if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
                m=$(awk '{printf "%.0f",$1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
            else
                m=$(awk -F: 'tolower($1) ~ /mhz/ {gsub(/ /,"",$2); printf "%.0f",$2; exit}' /proc/cpuinfo 2>/dev/null)
            fi ;;
        Darwin)
            f=$(sysctl -n hw.cpufrequency 2>/dev/null)
            [ -n "$f" ] && m=$(awk -v f="$f" 'BEGIN{printf "%.0f",f/1000000}') ;;
    esac
    [ -n "$m" ] && echo "$m" || echo "n/a"
}

# --- 1. Enumerate accelerated AES modes from the kernel ---------------------
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

echo "SSH AES modes (ssh -Q cipher):     $(echo $ssh_modes | tr '\n' ' ')"
if [ "$have_kernel" = yes ]; then
    echo "Kernel accelerated modes (sysctl): $(echo $kmodes | tr '\n' ' ')"
    echo "Accelerated (ssh filtered by kernel): $(echo $accel_modes | tr '\n' ' ')"
else
    if sysctl -a 2>/dev/null | grep -qiE 'features.*AES|FEAT_AES'; then f=present; else f="not detected"; fi
    echo "No per-mode kernel crypto enumeration on $(uname -s) (CPU AES: $f); using all SSH AES ciphers."
fi
[ -z "$candidates" ] && { echo; echo "No SSH AES ciphers pass the kernel filter."; exit 0; }
echo "Idle CPU clock: $(cpu_mhz) MHz"; echo

# --- 3. Pick a toggle-capable openssl --------------------------------------
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

speed_line() {
    if [ -n "$1" ]; then
        OPENSSL_ia32cap="$1" "$OSSL" speed -elapsed -seconds 1 -evp "$2" 2>/dev/null \
            | grep -i "^$2" | tail -n 1
    else
        ( unset OPENSSL_ia32cap; "$OSSL" speed -elapsed -seconds 1 -evp "$2" 2>/dev/null ) \
            | grep -i "^$2" | tail -n 1
    fi
}
peak() { echo "$1" | awk '{v=$NF; sub(/[kK]$/,"",v); print v+0}'; }
NOAES="~0x200000000000000"

# --- 4. Confirm the userspace toggle works ---------------------------------
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
echo "Throughput in Mbps (megabits/sec). CPU clock sampled per cipher at test time."
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
