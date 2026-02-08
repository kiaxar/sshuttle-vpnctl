#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="sshuttle-vpnctl"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! need_cmd sudo; then
  echo "ERROR: sudo is required."
  exit 1
fi

echo "== $PROJECT_NAME setup =="

# ---- packages ----
if ! need_cmd sshuttle; then
  echo "[+] Installing sshuttle..."
  sudo apt update
  sudo apt install -y sshuttle
else
  echo "[=] sshuttle is already installed."
fi

if ! dpkg -s bash-completion >/dev/null 2>&1; then
  echo "[+] Installing bash-completion..."
  sudo apt update
  sudo apt install -y bash-completion
else
  echo "[=] bash-completion is already installed."
fi

# ---- collect config ----
read -r -p "SSH server host (e.g. servers.europe): " REMOTE_HOST
REMOTE_HOST="${REMOTE_HOST:-}"

if [[ -z "$REMOTE_HOST" ]]; then
  echo "ERROR: host is required."
  exit 1
fi

read -r -p "SSH username (default: vpn): " REMOTE_USER
REMOTE_USER="${REMOTE_USER:-vpn}"

read -r -p "SSH port (default: 22): " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"

read -r -p "SSH identity file (optional, empty = default ssh keys): " SSH_IDENTITY
SSH_IDENTITY="${SSH_IDENTITY:-}"

read -r -p "Extra ssh options (optional, e.g. -o ServerAliveInterval=30 ...): " SSH_EXTRA_OPTS
SSH_EXTRA_OPTS="${SSH_EXTRA_OPTS:-}"

# Basic defaults
SUBNETS="0.0.0.0/0"
DNS_FLAG="--dns"
STATE_DIR="\$HOME/.local/state/vpn-sshuttle"

# ---- write config ----
CONF_PATH="/etc/sshuttle-vpnctl.conf"

echo "[+] Writing config to $CONF_PATH"
sudo tee "$CONF_PATH" >/dev/null <<EOF
# $PROJECT_NAME config
REMOTE_USER="$REMOTE_USER"
REMOTE_HOST="$REMOTE_HOST"
SSH_PORT="$SSH_PORT"
SSH_IDENTITY="$SSH_IDENTITY"
SSH_EXTRA_OPTS="$SSH_EXTRA_OPTS"

SUBNETS="$SUBNETS"
DNS_FLAG="$DNS_FLAG"

# runtime state/logs
STATE_DIR="$STATE_DIR"
EOF

sudo chmod 644 "$CONF_PATH"

# ---- install vpn command ----
VPN_BIN="/usr/local/bin/vpn"
echo "[+] Installing vpn command to $VPN_BIN"

sudo tee "$VPN_BIN" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ---- Load config (system + optional user override) ----
SYS_CONF="/etc/sshuttle-vpnctl.conf"
USR_CONF="$HOME/.config/sshuttle-vpnctl.conf"

if [[ -f "$SYS_CONF" ]]; then
  # shellcheck disable=SC1090
  source "$SYS_CONF"
fi

if [[ -f "$USR_CONF" ]]; then
  # shellcheck disable=SC1090
  source "$USR_CONF"
fi

: "${REMOTE_USER:?REMOTE_USER not set}"
: "${REMOTE_HOST:?REMOTE_HOST not set}"
: "${SUBNETS:=0.0.0.0/0}"
: "${DNS_FLAG:=--dns}"
: "${SSH_PORT:=22}"
: "${SSH_IDENTITY:=}"
: "${SSH_EXTRA_OPTS:=}"
: "${STATE_DIR:=$HOME/.local/state/vpn-sshuttle}"

PID_FILE="$STATE_DIR/sshuttle.pid"
LOG_FILE="$STATE_DIR/sshuttle.log"
CMD_FILE="$STATE_DIR/sshuttle.cmd"

mkdir -p "$STATE_DIR"

usage() {
  cat <<EOF
Usage:
  vpn start [--force-log]
  vpn stop
  vpn restart [--force-log]
  vpn status
  vpn log [-f]
  vpn help

Config:
  $SYS_CONF
  $USR_CONF (optional override)
EOF
}

resolve_ipv4_list() {
  # Print all unique STREAM IPv4s for host (one per line)
  getent ahosts "$REMOTE_HOST" \
    | awk '$2=="STREAM"{print $1}' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -u
}

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

build_ssh_cmd() {
  local cmd="ssh -T -p ${SSH_PORT}"
  if [[ -n "$SSH_IDENTITY" ]]; then
    cmd+=" -i ${SSH_IDENTITY}"
  fi
  if [[ -n "$SSH_EXTRA_OPTS" ]]; then
    cmd+=" ${SSH_EXTRA_OPTS}"
  fi
  echo "$cmd"
}

start_vpn() {
  local force_log="${1:-false}"

  if is_running; then
    echo "vpn: already running (pid $(cat "$PID_FILE"))"
    exit 0
  fi

  # Exclude server IP(s) to avoid redirecting SSH into itself
  mapfile -t ips < <(resolve_ipv4_list)
  if [[ "${#ips[@]}" -eq 0 ]]; then
    echo "ERROR: could not resolve IPv4 for $REMOTE_HOST"
    exit 1
  fi

  local ssh_cmd
  ssh_cmd="$(build_ssh_cmd)"

  local -a cmd
  cmd=(sshuttle
    --python python3
    --ssh-cmd "$ssh_cmd"
    -r "${REMOTE_USER}@${REMOTE_HOST}"
    "$SUBNETS"
  )

  # DNS flag may be empty to disable
  if [[ -n "$DNS_FLAG" ]]; then
    cmd+=("$DNS_FLAG")
  fi

  # add excludes
  for ip in "${ips[@]}"; do
    cmd+=(-x "${ip}/32")
  done

  # Save command for status/debug
  printf '%q ' "${cmd[@]}" > "$CMD_FILE"
  echo >> "$CMD_FILE"

  # Detach cleanly:
  # - setsid: no controlling terminal
  # - nohup: ignore hangup
  # - stdin: /dev/null
  # - optional logging
  if [[ "$force_log" == "true" ]]; then
    : > "$LOG_FILE"
    nohup setsid "${cmd[@]}" </dev/null >>"$LOG_FILE" 2>&1 &
  else
    nohup setsid "${cmd[@]}" </dev/null >/dev/null 2>&1 &
  fi

  local pid=$!
  echo "$pid" > "$PID_FILE"

  sleep 0.4
  if kill -0 "$pid" 2>/dev/null; then
    echo "vpn: started (pid $pid), excluded: ${ips[*]}"
    [[ "$force_log" == "true" ]] && echo "vpn: logging to $LOG_FILE"
  else
    echo "vpn: failed to start"
    rm -f "$PID_FILE"
    [[ -f "$LOG_FILE" ]] && tail -n 120 "$LOG_FILE" || true
    exit 1
  fi
}

stop_vpn() {
  if ! is_running; then
    echo "vpn: not running"
    exit 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"

  echo "vpn: stopping (pid $pid)"
  kill "$pid" 2>/dev/null || true

  for _ in {1..25}; do
    if kill -0 "$pid" 2>/dev/null; then
      sleep 0.2
    else
      break
    fi
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "vpn: force killing (pid $pid)"
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$PID_FILE"
  echo "vpn: stopped"
}

status_vpn() {
  if is_running; then
    local pid
    pid="$(cat "$PID_FILE")"
    echo "vpn: running (pid $pid)"
    [[ -f "$CMD_FILE" ]] && { echo -n "vpn: cmd: "; cat "$CMD_FILE"; }
    exit 0
  else
    echo "vpn: stopped"
    exit 1
  fi
}

show_log() {
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "vpn: no log file (start with: vpn start --force-log)"
    exit 1
  fi
  if [[ "${1:-}" == "-f" ]]; then
    tail -f "$LOG_FILE"
  else
    tail -n 200 "$LOG_FILE"
  fi
}

main() {
  local action="${1:-help}"
  shift || true

  case "$action" in
    start)
      local force_log="false"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force-log) force_log="true" ;;
          *) echo "Unknown option: $1"; usage; exit 2 ;;
        esac
        shift
      done
      start_vpn "$force_log"
      ;;
    stop)
      stop_vpn
      ;;
    restart)
      local force_log="false"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force-log) force_log="true" ;;
          *) echo "Unknown option: $1"; usage; exit 2 ;;
        esac
        shift
      done

      if is_running; then
        stop_vpn
      else
        echo "vpn: not running; starting..."
      fi

      start_vpn "$force_log"
      ;;
    status)
      status_vpn
      ;;
    log)
      show_log "${1:-}"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      echo "Unknown command: $action"
      usage
      exit 2
      ;;
  esac
}

main "$@"
EOF

sudo chmod +x "$VPN_BIN"

# ---- install bash completion ----
echo "[+] Installing bash completion: /etc/bash_completion.d/vpn"
sudo tee /etc/bash_completion.d/vpn >/dev/null <<'EOF'
_vpn_completion() {
  local cur
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"

  local cmds="start stop restart status log help"
  local opts="--force-log"
  local logopts="-f"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    start|restart)
      COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
      return 0
      ;;
    log)
      COMPREPLY=( $(compgen -W "$logopts" -- "$cur") )
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}
complete -F _vpn_completion vpn
EOF

echo
echo "== Done =="
echo "Config:  $CONF_PATH"
echo "Command: vpn"
echo
echo "Open a new terminal OR run: source /etc/bash_completion"
echo "Then try: vpn start"
