#!/usr/bin/env bash

# netbrief: Comprehensive network diagnostic summary with Gum integration
# Requires: bash, gum, and preferably ip, ss, curl, dig/resolvectl/nmcli

netbrief() {
  # -------------------------
  # Options / defaults
  # -------------------------
  local verbose=0
  local interactive=0
  local do_ping=1
  local do_public_ip=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        verbose=1
        ;;
      -i|--interactive)
        interactive=1
        ;;
      --no-ping)
        do_ping=0
        ;;
      --no-public-ip)
        do_public_ip=0
        ;;
      -h|--help)
        cat <<'EOF'
netbrief - concise but rich network diagnostic overview

Output is automatically paged through bat when available.

Usage:
  netbrief [OPTIONS]

Options:
  -v, --verbose        Show more detailed information (routes, more connections, etc.)
  -i, --interactive    Use an interactive Gum menu to choose which sections to display
      --no-ping        Skip connectivity tests via ping
      --no-public-ip   Skip querying external/public IP address
  -h, --help           Show this help

Examples:
  netbrief
  netbrief --verbose
  netbrief --interactive --verbose
  netbrief --no-ping --no-public-ip
EOF
        return 0
        ;;
      *)
        printf 'netbrief: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
    shift
  done

  # -------------------------
  # Dependency checks
  # -------------------------

  if ! command -v bash >/dev/null 2>&1; then
    printf 'netbrief: this function requires bash.\n' >&2
    return 1
  fi

  if ! command -v gum >/dev/null 2>&1; then
    printf 'netbrief: gum is required for styled output and integration.\n' >&2
    printf 'Install gum (e.g. pacman -S gum, yay -S gum, or see https://github.com/charmbracelet/gum).\n' >&2
    return 1
  fi

  # Soft dependencies (we just detect them)
  local has_ip=0 has_ifconfig=0 has_ss=0 has_netstat=0 has_nmcli=0 has_resolvectl=0 has_dig=0 has_curl=0 has_iw=0 has_bat=0

  command -v ip          >/dev/null 2>&1 && has_ip=1
  command -v ifconfig    >/dev/null 2>&1 && has_ifconfig=1
  command -v ss          >/dev/null 2>&1 && has_ss=1
  command -v netstat     >/dev/null 2>&1 && has_netstat=1
  command -v nmcli       >/dev/null 2>&1 && has_nmcli=1
  command -v resolvectl  >/dev/null 2>&1 && has_resolvectl=1
  command -v dig         >/dev/null 2>&1 && has_dig=1
  command -v curl        >/dev/null 2>&1 && has_curl=1
  command -v iw          >/dev/null 2>&1 && has_iw=1
  command -v bat         >/dev/null 2>&1 && has_bat=1

  # -------------------------
  # Helper: styled headers
  # -------------------------
  _nb_header() {
    local title="$1"
    gum style \
      --border normal \
      --margin "1 0" \
      --padding "0 1" \
      --border-foreground "#89b4fa" \
      --bold \
      "$title"
  }

  # -------------------------
  # Helper: section wrapper
  # -------------------------
  _nb_section() {
    local title="$1"
    shift
    _nb_header "$title"
    # Title printed above; run the provided command(s)
    "$@"
  }

  # -------------------------
  # Section: System summary
  # -------------------------
  _nb_system_summary() {
    if command -v hostnamectl >/dev/null 2>&1; then
      hostnamectl
    else
      printf 'Hostname: %s\n' "$(hostname 2>/dev/null || echo 'n/a')"
      printf 'Kernel:  %s\n' "$(uname -srmo 2>/dev/null || echo 'n/a')"
    fi
  }

  # -------------------------
  # Section: Interface summary
  # -------------------------
  _nb_interfaces() {
    if (( has_ip )); then
      printf 'Interface summary (ip -brief addr show):\n\n'
      ip -brief addr show
      printf '\nLink status (ip -brief link):\n\n'
      ip -brief link
    elif (( has_ifconfig )); then
      printf 'Interface summary (ifconfig -a):\n\n'
      ifconfig -a
    else
      printf 'No suitable tool found for interface listing (ip/ifconfig).\n'
    fi
  }

  # -------------------------
  # Section: Routing / default gateway
  # -------------------------
  _nb_routes() {
    if (( has_ip )); then
      printf 'Routing table (ip route):\n\n'
      ip route
    else
      printf 'Routing table (netstat -rn):\n\n'
      if (( has_netstat )); then
        netstat -rn
      else
        printf 'No suitable tool found for route listing (ip/netstat).\n'
      fi
    fi
  }

  # -------------------------
  # Section: DNS configuration
  # -------------------------
  _nb_dns() {
    if (( has_resolvectl )); then
      printf 'DNS status (resolvectl status):\n\n'
      resolvectl status
    else
      printf '/etc/resolv.conf:\n\n'
      if [[ -r /etc/resolv.conf ]]; then
        cat /etc/resolv.conf
      else
        printf 'Could not read /etc/resolv.conf.\n'
      fi
    fi

    if (( has_dig )); then
      printf '\nDNS lookup test for example.com (dig +short example.com):\n\n'
      dig +short example.com || printf 'DNS lookup failed or dig error.\n'
    else
      printf '\nNote: dig not available, skipping example.com DNS lookup.\n'
    fi
  }

  # -------------------------
  # Section: Active connections / listeners
  # -------------------------
  _nb_connections() {
    if (( has_ss )); then
      printf 'Listening sockets (ss -tulpn):\n\n'
      if (( verbose )); then
        ss -tulpn
      else
        ss -tulpn | head -n 40
        printf '\n(Use --verbose to see full list.)\n'
      fi

      printf '\nRecent TCP connections (ss -tan):\n\n'
      if (( verbose )); then
        ss -tan
      else
        ss -tan | head -n 40
        printf '\n(Use --verbose to see full list.)\n'
      fi
    elif (( has_netstat )); then
      printf 'Listening sockets (netstat -tulpn):\n\n'
      netstat -tulpn
    else
      printf 'No ss/netstat available for connections overview.\n'
    fi
  }

  # -------------------------
  # Section: Wireless (if applicable)
  # -------------------------
  _nb_wireless() {
    if (( has_nmcli )); then
      printf 'NetworkManager devices:\n\n'
      nmcli device status

      printf '\nActive Wi-Fi connections:\n\n'
      nmcli -f NAME,UUID,TYPE,DEVICE,STATE connection show --active

      printf '\nWi-Fi details (nmcli device wifi show if available):\n\n'
      nmcli device wifi list 2>/dev/null || printf 'Could not list Wi-Fi networks.\n'
    elif (( has_iw )); then
      printf 'Wireless devices (iw dev):\n\n'
      iw dev
      printf '\nStation info (iw dev <iface> link) – replace <iface> manually.\n'
    else
      printf 'No nmcli/iw found; skipping wireless diagnostics.\n'
    fi
  }

  # -------------------------
  # Section: Connectivity tests (ping)
  # -------------------------
  _nb_ping_tests() {
    if (( ! do_ping )); then
      printf 'Ping tests disabled via --no-ping.\n'
      return 0
    fi

    local default_gw=""
    if (( has_ip )); then
      default_gw="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
    fi

    if [[ -n "$default_gw" ]]; then
      gum spin --title "Pinging default gateway ($default_gw)" -- \
        ping -c 1 -W 1 "$default_gw" >/dev/null 2>&1

      if [[ $? -eq 0 ]]; then
        printf 'Default gateway (%s) is reachable.\n' "$default_gw"
      else
        printf 'Default gateway (%s) is NOT reachable.\n' "$default_gw"
      fi
    else
      printf 'No default gateway detected.\n'
    fi

    gum spin --title "Pinging public IP 1.1.1.1" -- \
      ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1

    if [[ $? -eq 0 ]]; then
      printf 'Basic external IP connectivity (1.1.1.1) appears OK.\n'
    else
      printf 'Failed to reach 1.1.1.1 – possible upstream connectivity issue.\n'
    fi

    gum spin --title "Pinging example.com (DNS + connectivity)" -- \
      ping -c 1 -W 2 example.com >/dev/null 2>&1

    if [[ $? -eq 0 ]]; then
      printf 'DNS + external connectivity (example.com) appears OK.\n'
    else
      printf 'Failed to ping example.com – check DNS and upstream connectivity.\n'
    fi
  }

  # -------------------------
  # Section: Public IP / external info
  # -------------------------
  _nb_public_ip() {
    if (( ! do_public_ip )); then
      printf 'Public IP lookup disabled via --no-public-ip.\n'
      return 0
    fi

    if (( ! has_curl )); then
      printf 'curl not available; cannot query external IP.\n'
      return 0
    fi

    local v4 v6
    v4="$(gum spin --title "Querying IPv4 public address" -- curl -4s https://ifconfig.me || true)"
    v6="$(gum spin --title "Querying IPv6 public address" -- curl -6s https://ifconfig.me || true)"

    printf 'Public IPv4: %s\n' "${v4:-unavailable}"
    printf 'Public IPv6: %s\n' "${v6:-unavailable}"
  }

  # -------------------------
  # Section: DHCP / IP config details (via nmcli if possible)
  # -------------------------
  _nb_ip_details() {
    if (( has_nmcli )); then
      printf 'IP configuration for active connections (nmcli):\n\n'
      nmcli -f NAME,DEVICE,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS,IP6.GATEWAY,IP6.DNS connection show --active
    elif (( has_ip )); then
      printf 'IP addresses (ip addr show):\n\n'
      ip addr show
    else
      printf 'No nmcli/ip available for detailed IP configuration.\n'
    fi
  }

  # -------------------------
  # Section: ARP / neighbor table
  # -------------------------
  _nb_neighbors() {
    if (( has_ip )); then
      printf 'Neighbor table (ip neigh):\n\n'
      ip neigh
    else
      printf 'No ip tool available; skipping neighbor table.\n'
    fi
  }

  # -------------------------
  # Determine which sections to run
  # -------------------------
  local sections
  sections=("System summary" "Interfaces" "IP details" "Routes" "DNS" "Connections" "Wireless" "Ping tests" "Public IP" "Neighbors")

  local selected_sections=("${sections[@]}")

  if (( interactive )); then
    # Interactive multi-select via gum
    local chosen
    chosen="$(printf '%s\n' "${sections[@]}" | gum choose --no-limit --cursor.foreground "#89b4fa" --header "Select sections to display (SPACE to toggle, ENTER to confirm):")" || return 1

    # If user chose nothing, abort
    if [[ -z "$chosen" ]]; then
      printf 'No sections selected. Exiting.\n'
      return 0
    fi

    # Parse into array
    mapfile -t selected_sections <<< "$chosen"
  fi

  # -------------------------
  # Optional paging via bat
  # -------------------------
  local nb_tmpfile="" nb_restore_fd=""
  if (( has_bat )); then
    nb_tmpfile="$(mktemp -t netbrief.XXXXXX)"
    exec 3>&1
    nb_restore_fd=3
    exec >"$nb_tmpfile"
  else
    printf 'netbrief: bat not found; output will not be paged.\n' >&2
  fi

  # -------------------------
  # Run selected sections
  # -------------------------
  local section
  for section in "${selected_sections[@]}"; do
    case "$section" in
      "System summary")
        _nb_section "System summary" _nb_system_summary
        ;;
      "Interfaces")
        _nb_section "Network interfaces" _nb_interfaces
        ;;
      "IP details")
        _nb_section "IP configuration details" _nb_ip_details
        ;;
      "Routes")
        _nb_section "Routing table / default gateway" _nb_routes
        ;;
      "DNS")
        _nb_section "DNS configuration and resolution" _nb_dns
        ;;
      "Connections")
        _nb_section "Active connections / listeners" _nb_connections
        ;;
      "Wireless")
        _nb_section "Wireless / Wi-Fi details" _nb_wireless
        ;;
      "Ping tests")
        _nb_section "Connectivity tests (ping)" _nb_ping_tests
        ;;
      "Public IP")
        _nb_section "External / public IP information" _nb_public_ip
        ;;
      "Neighbors")
        _nb_section "Neighbor / ARP table" _nb_neighbors
        ;;
    esac
  done

  printf '\n'
  gum style --foreground "#a6e3a1" --bold "netbrief complete."

  if [[ -n "$nb_tmpfile" ]]; then
    exec 1>&"$nb_restore_fd"
    exec "$nb_restore_fd>&-"
    bat --paging=always --plain --theme=ansi "$nb_tmpfile"
    rm -f "$nb_tmpfile"
  fi
}

