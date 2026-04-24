#!/usr/bin/env bash
set -euo pipefail

# Supported: Debian 11+ / Ubuntu 22.04+
# Requires: systemd as PID 1, apt-get, root

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_root() {
  local uid
  uid=$(id -u) || die "The 'id' command failed."
  [[ "$uid" -eq 0 ]] || die "This script must be run as root (e.g. sudo \"${0#-}\")."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_systemd() {
  [[ -d /run/systemd/system ]] || die "systemd is not running (PID 1 is not systemd). This script requires systemd."
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found. Install systemd and re-run."
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found. This script supports Debian/Ubuntu only."
}

# ---------------------------------------------------------------------------
# print_url_ascii_box URL
# ---------------------------------------------------------------------------
print_url_ascii_box() {
  local url=$1
  local w=72
  local top
  top="$(printf '%*s' "$w" '' | tr ' ' '-')"
  echo ""
  echo "  +${top}+"
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    printf '  | %-*s |\n' "$w" "$line"
  done < <(printf '%s' "$url" | fold -w "$w" 2>/dev/null || printf '%s\n' "$url")
  echo "  +${top}+"
  echo "  (ASCII box - not a QR; use the link or install qrencode for a scannable terminal QR.)"
}

# ---------------------------------------------------------------------------
# prompt_install_yes MSG  →  0 = yes, 1 = no
# ---------------------------------------------------------------------------
prompt_install_yes() {
  local _msg=$1
  if [[ ! -t 0 ]]; then
    echo "$_msg" >&2
    echo "Not running on a TTY - install packages manually, then re-run this script." >&2
    return 1
  fi
  printf '%s [Y/n]: ' "$_msg"
  read -r _reply
  case "${_reply:-y}" in
    [nN] | [nN][oO]) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# offer_install_dependencies
# Installs missing required packages via apt-get (Debian/Ubuntu only).
# ---------------------------------------------------------------------------
offer_install_dependencies() {
  local pkgs=""

  command -v curl  >/dev/null 2>&1 || pkgs+=" curl ca-certificates"
  command -v xz    >/dev/null 2>&1 || pkgs+=" xz-utils"
  command -v awk   >/dev/null 2>&1 || pkgs+=" gawk"
  command -v tar   >/dev/null 2>&1 || pkgs+=" tar"
  command -v getent >/dev/null 2>&1 || pkgs+=" libc-bin"
  { command -v base64 >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1; } \
    || pkgs+=" openssl"

  # Deduplicate
  pkgs=$(echo "$pkgs" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')

  if [[ -n "$pkgs" ]]; then
    echo "The following packages are missing: $pkgs" >&2
    if prompt_install_yes "Install them now with: apt-get install -y $pkgs"; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      # shellcheck disable=SC2086
      apt-get install -y $pkgs
    fi
  fi

  # Optional: qrencode for terminal QR
  if ! command -v qrencode >/dev/null 2>&1 && [[ -t 0 ]]; then
    printf 'Optional: install qrencode for a scannable QR in the terminal. Install now? [y/N]: '
    read -r _qr
    case "${_qr:-n}" in
      [yY] | [yY][eE][sS])
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y qrencode
        ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# fetch_public_ip
# ---------------------------------------------------------------------------
fetch_public_ip() {
  curl --connect-timeout 10 --max-time 30 -fsSL "https://whatismyip.akamai.com/" | tr -d '\r\n'
}

# ---------------------------------------------------------------------------
# download_to URL DEST
# ---------------------------------------------------------------------------
download_to() {
  local url=$1 dest=$2
  curl --connect-timeout 10 --max-time 120 -fsSL "$url" -o "$dest"
}

# ---------------------------------------------------------------------------
# lookup_domain_ipv4 DOMAIN
# ---------------------------------------------------------------------------
lookup_domain_ipv4() {
  local domain=$1 ips=""

  if command -v getent >/dev/null 2>&1; then
    ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9.]+$' | sort -u || true)
    if [[ -z "$ips" ]]; then
      ips=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9.]+$' | sort -u || true)
    fi
  fi

  if [[ -z "$ips" ]] && command -v dig >/dev/null 2>&1; then
    ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' || true)
  fi

  printf '%s' "$ips"
}

# ---------------------------------------------------------------------------
# domain_resolves_to_ip DOMAIN EXPECTED_IP
# ---------------------------------------------------------------------------
domain_resolves_to_ip() {
  local domain=$1 expected_ip=$2 ips
  ips=$(lookup_domain_ipv4 "$domain")
  [[ -n "$ips" ]] || die "Could not resolve DNS for '$domain'. Check that getent/dig is available and DNS is configured."
  local OLDIFS=$IFS ip
  IFS=$'\n'
  for ip in $ips; do
    IFS=$OLDIFS
    [[ -z "$ip" ]] && continue
    [[ "$ip" == "$expected_ip" ]] && return 0
  done
  IFS=$OLDIFS
  return 1
}

# ---------------------------------------------------------------------------
# caddy_quote / write_caddyfile / exports_from_caddyfile
# ---------------------------------------------------------------------------
caddy_quote() {
  local _s=$1 _out
  _out=$(printf '%s' "$_s" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '"%s"' "$_out"
}

write_caddyfile() {
  local domain=$1 email=$2 user=$3 pass=$4 outfile=$5
  local qe qu qp
  qe=$(caddy_quote "$email")
  qu=$(caddy_quote "$user")
  qp=$(caddy_quote "$pass")
  cat >"$outfile" <<EOF
{
  order forward_proxy before file_server
}
:443, $domain {
  tls $qe
  forward_proxy {
    basic_auth $qu $qp
    hide_ip
    hide_via
    probe_resistance
  }
  file_server {
    root /var/www/html
  }
}
EOF
}

exports_from_caddyfile() {
  local path=$1
  local _awkf
  _awkf=$(mktemp "/tmp/naive-exports.XXXXXX")
  cat >"$_awkf" <<'AWK'
function unescape_caddy(q,    n, inner, i, c, c2, out) {
  n = length(q)
  if (n < 2 || substr(q, 1, 1) != "\"" || substr(q, n, 1) != "\"") return q
  inner = substr(q, 2, n - 2)
  out = ""
  i = 1
  while (i <= length(inner)) {
    c = substr(inner, i, 1)
    if (c == "\\" && i < length(inner)) {
      c2 = substr(inner, i + 1, 1)
      if (c2 == "\"") { out = out "\""; i += 2; continue }
      if (c2 == "\\") { out = out "\\"; i += 2; continue }
    }
    out = out c
    i++
  }
  return out
}
function shquote(s,    t) {
  t = s
  gsub(/\047/, "'\''", t)
  return "'" t "'"
}
function read_caddy_quoted(buf, pos,    n, i, c, c2, out) {
  n = length(buf)
  if (substr(buf, pos, 1) != "\"") return ""
  out = "\""
  i = pos + 1
  while (i <= n) {
    c = substr(buf, i, 1)
    out = out c
    if (c == "\\" && i < n) { c2 = substr(buf, i + 1, 1); out = out c2; i += 2; continue }
    if (c == "\"") return out
    i++
  }
  return ""
}
function read_caddy_unquoted(buf, pos,    n, i, c, out) {
  n = length(buf); out = ""; i = pos
  while (i <= n) {
    c = substr(buf, i, 1)
    if (c ~ /[[:space:]]/) break
    out = out c; i++
  }
  return out
}
function read_caddy_value(buf, pos) {
  if (substr(buf, pos, 1) == "\"") return read_caddy_quoted(buf, pos)
  return read_caddy_unquoted(buf, pos)
}
{ buf = buf $0 "\n" }
END {
  if (match(buf, /:443,[[:space:]]*[^[:space:]{#]+/)) {
    s = substr(buf, RSTART, RLENGTH)
    sub(/^:443,[[:space:]]*/, "", s)
    domain = s
  } else { print "Could not parse :443 host in Caddyfile." > "/dev/stderr"; exit 1 }
  if (!match(buf, /tls[[:space:]]+/)) { print "Could not find tls in Caddyfile." > "/dev/stderr"; exit 1 }
  rest = substr(buf, RSTART + RLENGTH)
  sub(/^[[:space:]]*/, "", rest)
  email_q = read_caddy_value(rest, 1)
  if (email_q == "") { print "Could not parse tls value in Caddyfile." > "/dev/stderr"; exit 1 }
  email = unescape_caddy(email_q)
  if (!match(buf, /basic_auth[[:space:]]+/)) { print "Could not find basic_auth in Caddyfile." > "/dev/stderr"; exit 1 }
  rest = substr(buf, RSTART + RLENGTH)
  sub(/^[[:space:]]*/, "", rest)
  uq = read_caddy_value(rest, 1)
  if (uq == "") { print "Could not parse basic_auth user in Caddyfile." > "/dev/stderr"; exit 1 }
  rest2 = substr(rest, length(uq) + 1)
  sub(/^[[:space:]]*/, "", rest2)
  pq = read_caddy_value(rest2, 1)
  if (pq == "") { print "Could not parse basic_auth password in Caddyfile." > "/dev/stderr"; exit 1 }
  user = unescape_caddy(uq)
  password = unescape_caddy(pq)
  print "export DOMAIN=" shquote(domain)
  print "export EMAIL=" shquote(email)
  print "export PROXY_USER=" shquote(user)
  print "export PROXY_PASS=" shquote(password)
}
AWK
  awk -f "$_awkf" "$path"
  local _ae=$?
  rm -f "$_awkf"
  return "$_ae"
}

# ---------------------------------------------------------------------------
# naive_share_url / show_share_link_and_qr
# ---------------------------------------------------------------------------
naive_share_url() {
  local u=$1 p=$2 d=$3 raw b64
  raw="${u}:${p}@${d}:443"
  if command -v base64 >/dev/null 2>&1; then
    b64=$(printf '%s' "$raw" | base64 | tr -d '\n')
  else
    b64=$(printf '%s' "$raw" | openssl base64 2>/dev/null | tr -d '\n') \
      || b64=$(printf '%s' "$raw" | openssl enc -base64 2>/dev/null | tr -d '\n')
  fi
  b64=$(printf '%s' "$b64" | tr -d '=')
  printf 'naive+quic://%s?method=auto\n' "$b64"
}

show_share_link_and_qr() {
  local share_url
  share_url=$(naive_share_url "$PROXY_USER" "$PROXY_PASS" "$DOMAIN")
  echo ""
  echo "================================================================================"
  echo "  Share link (import in naive client)"
  echo "================================================================================"
  echo "$share_url"
  echo ""
  echo "QR code:"
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$share_url" | qrencode -t ANSIUTF8 2>/dev/null \
      || printf '%s' "$share_url" | qrencode -t UTF8
  else
    print_url_ascii_box "$share_url"
    echo "  For a real QR: apt-get install qrencode"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# print_firewall_reminder
# ---------------------------------------------------------------------------
print_firewall_reminder() {
  echo ""
  echo "================================================================================"
  echo "  IMPORTANT: Firewall configuration"
  echo "================================================================================"
  echo "  Caddy needs ports 80 (ACME challenge) and 443 (proxy/QUIC) open."
  echo ""
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    echo "  [ufw detected and active]"
    echo ""
    echo "    ufw allow 80/tcp"
    echo "    ufw allow 443/tcp"
    echo "    ufw allow 443/udp"
    echo "    ufw reload"
  elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'table'; then
    echo "  [nftables detected]"
    echo ""
    echo "    nft add rule inet filter input tcp dport { 80, 443 } accept"
    echo "    nft add rule inet filter input udp dport 443 accept"
  elif command -v iptables >/dev/null 2>&1; then
    echo "  [iptables detected]"
    echo ""
    echo "    iptables -A INPUT -p tcp --dport 80  -j ACCEPT"
    echo "    iptables -A INPUT -p tcp --dport 443 -j ACCEPT"
    echo "    iptables -A INPUT -p udp --dport 443 -j ACCEPT"
    echo ""
    echo "  Persist: apt-get install iptables-persistent && netfilter-persistent save"
  else
    echo "  No known firewall detected. Open ports 80/tcp, 443/tcp, 443/udp manually."
  fi
  echo ""
  echo "================================================================================"
  echo ""
}

# ---------------------------------------------------------------------------
# mktemp helpers
# ---------------------------------------------------------------------------
mktemp_file() { mktemp "/tmp/naive-caddy.XXXXXX"; }
mktemp_tar()  { mktemp "/tmp/naive-tar.XXXXXX";   }

# ---------------------------------------------------------------------------
# read_secret PROMPT  →  sets $PROXY_PASS
# ---------------------------------------------------------------------------
read_secret() {
  local prompt=$1
  if [[ -t 0 ]]; then
    read -rs -p "$prompt" PROXY_PASS
    printf '\n'
  else
    printf '%s' "$prompt"
    read -r PROXY_PASS
  fi
}

# ---------------------------------------------------------------------------
# port_owner PORT
# ---------------------------------------------------------------------------
port_owner() {
  local port=$1 result=""

  if [[ -r /proc/net/tcp || -r /proc/net/tcp6 ]]; then
    local hex_port inode=""
    hex_port=$(printf '%04X' "$port")
    for f in /proc/net/tcp /proc/net/tcp6; do
      [[ -r "$f" ]] || continue
      inode=$(awk -v hp=":${hex_port}" '$4 == "0A" && $2 ~ hp"$" { print $10; exit }' "$f" 2>/dev/null || true)
      [[ -n "$inode" ]] && break
    done
    if [[ -n "$inode" ]]; then
      local pid=""
      for fd_dir in /proc/[0-9]*/fd; do
        [[ -d "$fd_dir" ]] || continue
        if ls -la "$fd_dir" 2>/dev/null | grep -q "socket:\[${inode}\]"; then
          pid=$(echo "$fd_dir" | cut -d/ -f3)
          break
        fi
      done
      if [[ -n "$pid" ]]; then
        local comm
        comm=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "?")
        result="${pid} (${comm})"
      else
        result="unknown PID (inode ${inode})"
      fi
    fi
  fi

  if [[ -z "$result" ]] && command -v ss >/dev/null 2>&1; then
    local ss_out pid comm
    ss_out=$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -v '^State' || true)
    if [[ -n "$ss_out" ]]; then
      pid=$(echo "$ss_out" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
      if [[ -n "$pid" ]]; then
        comm=$(ps -p "$pid" -o comm= 2>/dev/null || cat "/proc/${pid}/comm" 2>/dev/null || echo "?")
        result="${pid} (${comm})"
      else
        result=$(echo "$ss_out" | head -1)
      fi
    fi
  fi

  if [[ -n "$result" ]]; then
    printf '%s' "$result"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# check_ports
# ---------------------------------------------------------------------------
check_ports() {
  echo "Checking ports 80 and 443..." >&2
  local failed=0 owner80 owner443

  if owner80=$(port_owner 80); then
    echo "ERROR: Port 80 is already in use by: ${owner80}" >&2
    echo "       Stop that process before running this script." >&2
    failed=1
  else
    echo "  Port  80: free" >&2
  fi

  if owner443=$(port_owner 443); then
    echo "ERROR: Port 443 is already in use by: ${owner443}" >&2
    echo "       Stop that process before running this script." >&2
    failed=1
  else
    echo "  Port 443: free" >&2
  fi

  [[ "$failed" -eq 0 ]] || die "Occupied ports must be freed before Caddy can start."
}

# ---------------------------------------------------------------------------
# System user and state directory
# ---------------------------------------------------------------------------
CADDY_USER="caddy-naive"
CADDY_STATE_DIR="/var/lib/caddy-naive"

ensure_caddy_user() {
  mkdir -p "$CADDY_STATE_DIR"

  if id "$CADDY_USER" >/dev/null 2>&1; then
    chown "$CADDY_USER":"$CADDY_USER" "$CADDY_STATE_DIR"
    chmod 0700 "$CADDY_STATE_DIR"
    return 0
  fi

  echo "Creating system user '$CADDY_USER' with home $CADDY_STATE_DIR..." >&2
  useradd -r -s /bin/false -d "$CADDY_STATE_DIR" -M "$CADDY_USER" \
    || die "Failed to create system user '$CADDY_USER'."

  chown "$CADDY_USER":"$CADDY_USER" "$CADDY_STATE_DIR"
  chmod 0700 "$CADDY_STATE_DIR"
}

# ---------------------------------------------------------------------------
# install_systemd_unit UNIT_SRC
# ---------------------------------------------------------------------------
install_systemd_unit() {
  local unit_src=$1
  local unit_dst="/etc/systemd/system/caddy-naive.service"

  echo "Installing systemd unit -> $unit_dst" >&2
  cp "$unit_src" "$unit_dst"
  chmod 0644 "$unit_dst"
  systemctl daemon-reload
  systemctl enable caddy-naive
  echo "Unit caddy-naive.service installed and enabled." >&2
}

_script_dir() {
  local src="$0"
  while [[ -L "$src" ]]; do src="$(readlink "$src")"; done
  cd "$(dirname "$src")" && pwd
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  echo "Naive server setup (Caddy + forwardproxy)..." >&2

  require_systemd
  require_apt

  check_ports
  offer_install_dependencies

  require_cmd curl
  require_cmd xz
  require_cmd tar
  require_cmd awk
  { command -v base64 >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1; } \
    || die "Need base64 or openssl for the share link: apt-get install openssl"

  local caddyfile_path="/etc/caddy/Caddyfile"
  mkdir -p /etc/caddy /var/www/html

  if [[ -f "$caddyfile_path" && -s "$caddyfile_path" ]]; then
    echo "Found existing $caddyfile_path - skipping prompts."
    ensure_caddy_user
    chown root:"$CADDY_USER" "$caddyfile_path"
    chmod 0640 "$caddyfile_path"
    local _exports
    _exports=$(exports_from_caddyfile "$caddyfile_path") \
      || die "Could not parse $caddyfile_path (expected :443, tls, and basic_auth lines)."
    # shellcheck disable=SC1090
    eval "$_exports"
  else
    printf 'Domain name (e.g. example.com): '
    read -r DOMAIN
    local DOMAIN_TRIM
    DOMAIN_TRIM=$(printf '%s' "$DOMAIN" | tr -d ' ')
    [[ -n "$DOMAIN_TRIM" ]] || die "Domain name is required."

    echo "Fetching public IP..."
    local MY_IP
    MY_IP=$(fetch_public_ip)
    [[ -n "$MY_IP" ]] || die "Could not determine public IP."
    echo "This machine's public IP: $MY_IP"

    echo "Checking that $DOMAIN_TRIM resolves to $MY_IP ..."
    domain_resolves_to_ip "$DOMAIN_TRIM" "$MY_IP" \
      || die "DNS for '$DOMAIN_TRIM' does not resolve to $MY_IP. Fix the A record and try again."
    echo "DNS check passed."

    printf 'Email (for ACME / Lets Encrypt): '
    read -r EMAIL
    local EMAIL_TRIM
    EMAIL_TRIM=$(printf '%s' "$EMAIL" | tr -d ' ')
    [[ -n "$EMAIL_TRIM" ]] || die "Email is required."

    printf 'Proxy username: '
    read -r PROXY_USER
    local USER_TRIM
    USER_TRIM=$(printf '%s' "$PROXY_USER" | tr -d ' ')
    [[ -n "$USER_TRIM" ]] || die "Proxy username is required."

    read_secret "Proxy password: "
    [[ -n "${PROXY_PASS:-}" ]] || die "Proxy password is required."

    local TMP_CADDY
    TMP_CADDY=$(mktemp_file)
    trap 'rm -f "$TMP_CADDY"' EXIT
    write_caddyfile "$DOMAIN_TRIM" "$EMAIL_TRIM" "$USER_TRIM" "$PROXY_PASS" "$TMP_CADDY"
    mv "$TMP_CADDY" "$caddyfile_path"
    trap - EXIT

    ensure_caddy_user
    chown root:"$CADDY_USER" "$caddyfile_path"
    chmod 0640 "$caddyfile_path"
  fi

  echo "Downloading static index.html..."
  download_to \
    "https://raw.githubusercontent.com/nginx/nginx/5eaf45f11e85459b52c18f876e69320df420ae29/docs/html/index.html" \
    /var/www/html/index.html
  chown root:"$CADDY_USER" /var/www/html
  chmod 0750 /var/www/html
  chown root:"$CADDY_USER" /var/www/html/index.html
  chmod 0640 /var/www/html/index.html

  local CADDY_RELEASE_URL="https://github.com/klzgrad/forwardproxy/releases/download/v2.10.0-naive/caddy-forwardproxy-naive.tar.xz"
  local CADDY_DIR="/opt/caddy-forwardproxy-naive"
  mkdir -p "$CADDY_DIR"

  local TMP_TAR
  TMP_TAR=$(mktemp_tar)
  echo "Downloading Caddy (forwardproxy naive)..."
  download_to "$CADDY_RELEASE_URL" "$TMP_TAR"
  tar -xJf "$TMP_TAR" -C "$CADDY_DIR" \
    || die "Extracting Caddy archive failed. Ensure xz-utils is installed: apt-get install xz-utils"
  rm -f "$TMP_TAR"

  local CADDY_BIN
  CADDY_BIN=$(find "$CADDY_DIR" -type f -name caddy | head -n1)
  [[ -n "$CADDY_BIN" ]] || die "Could not find caddy binary after extracting archive."
  chmod +x "$CADDY_BIN"

  show_share_link_and_qr
  print_firewall_reminder

  local UNIT_SRC
  UNIT_SRC="$(_script_dir)/caddy-naive.service"
  [[ -f "$UNIT_SRC" ]] || die "Unit file not found: $UNIT_SRC. Ensure caddy-naive.service is in the same directory as this script."

  install_systemd_unit "$UNIT_SRC"

  echo "Starting caddy-naive via systemd..."
  systemctl start caddy-naive \
    || die "systemctl start caddy-naive failed. Check: journalctl -u caddy-naive -xe"

  echo ""
  echo "Caddy is running. Manage with:"
  echo "  systemctl status  caddy-naive"
  echo "  systemctl restart caddy-naive"
  echo "  systemctl stop    caddy-naive"
  echo "  journalctl -u caddy-naive -f"
}

require_root
main "$@"
