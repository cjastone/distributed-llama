#!/usr/bin/env bash
# Reversible, per-boot OS tuning bundles for Raspberry Pi 4 cluster nodes.
# Apply ONE bundle at a time and benchmark before applying the next.
# Nothing persists across reboot. Run as root on every node.
#
# Derived from the hellomatik pi5-cluster deployment, re-checked for Pi 4:
# values that regressed or were hazardous there (threaded NAPI, IRQ pinning,
# MTU changes) are intentionally absent. The NIC bundle queries bcmgenet's
# actual limits instead of assuming Pi 5 values.
set -u

IFACE="${IFACE:-eth0}"

require_root() { [ "$(id -u)" = "0" ] || { echo "Run as root."; exit 1; }; }

case "${1:-}" in
governor)
    require_root
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        echo performance > "$c"
    done
    echo "governor: performance"
    ;;
governor-reset)
    require_root
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        echo ondemand > "$c"
    done
    echo "governor: ondemand"
    ;;
sysctls)
    require_root
    sysctl -w net.core.rmem_max=8388608
    sysctl -w net.core.wmem_max=8388608
    sysctl -w net.ipv4.tcp_rmem="4096 262144 8388608"
    sysctl -w net.ipv4.tcp_wmem="4096 262144 8388608"
    sysctl -w net.core.netdev_max_backlog=5000
    sysctl -w vm.swappiness=1
    ;;
sysctls-reset)
    require_root
    sysctl -w net.core.rmem_max=212992
    sysctl -w net.core.wmem_max=212992
    sysctl -w net.ipv4.tcp_rmem="4096 131072 6291456"
    sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304"
    sysctl -w net.core.netdev_max_backlog=1000
    sysctl -w vm.swappiness=60
    ;;
busy-poll)
    require_root
    sysctl -w net.core.busy_poll=50
    sysctl -w net.core.busy_read=50
    ;;
busy-poll-reset)
    require_root
    sysctl -w net.core.busy_poll=0
    sysctl -w net.core.busy_read=0
    ;;
gro-off)
    require_root
    ethtool -K "$IFACE" gro off && echo "gro: off"
    ;;
gro-on)
    require_root
    ethtool -K "$IFACE" gro on && echo "gro: on"
    ;;
nic)
    require_root
    echo "bcmgenet limits:"
    ethtool -g "$IFACE" || echo "(ring info not supported by this driver)"
    ethtool -c "$IFACE" || echo "(coalescing info not supported by this driver)"
    echo
    echo "Apply manually within the printed limits, e.g.:"
    echo "  ethtool -G $IFACE rx <n>"
    echo "  ethtool -C $IFACE rx-usecs 10 tx-usecs 10"
    echo "(bcmgenet supports less than Pi 5's NIC; do not assume values transfer.)"
    ;;
status)
    echo "governor:   $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
    echo "rmem_max:   $(sysctl -n net.core.rmem_max)"
    echo "wmem_max:   $(sysctl -n net.core.wmem_max)"
    echo "busy_poll:  $(sysctl -n net.core.busy_poll)"
    echo "swappiness: $(sysctl -n vm.swappiness)"
    echo "gro:        $(ethtool -k "$IFACE" 2>/dev/null | awk '/generic-receive-offload/{print $2}')"
    echo "memlock:    $(ulimit -l)"
    echo "throttled:  $(command -v vcgencmd > /dev/null && vcgencmd get_throttled || echo NA)"
    echo "temp:       $(command -v vcgencmd > /dev/null && vcgencmd measure_temp || echo NA)"
    ;;
*)
    echo "Usage: $0 {governor|governor-reset|sysctls|sysctls-reset|busy-poll|busy-poll-reset|gro-off|gro-on|nic|status}"
    echo "IFACE=eth0 by default; override with IFACE=<iface>."
    exit 1
    ;;
esac
