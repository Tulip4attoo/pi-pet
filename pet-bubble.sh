#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$script_dir/tmp"
raw_id="${PI_PET_BUBBLE_ID:-$PPID}"
bubble_id="${raw_id//[^a-zA-Z0-9_.-]/_}"
root_dir="$tmp_dir/pet-bubbles"
bubble_dir="$root_dir/$bubble_id"
command_file="$bubble_dir/command.json"
manager_state_file="$root_dir/manager-state.json"
log_file="$root_dir/manager-powershell.log"
dir_label="${PI_PET_BUBBLE_DIR:-$PWD}"
owner_pid="${PI_PET_BUBBLE_PID:-$PPID}"
manager_version="0.3.0"

usage() {
  cat <<'EOF'
Usage:
  ./pet-bubble.sh start [status] [text...]
  ./pet-bubble.sh thinking [text...]
  ./pet-bubble.sh answering [text...]
  ./pet-bubble.sh finished [text...]
  ./pet-bubble.sh set <status> [text...]
  ./pet-bubble.sh move <x> <y>
  ./pet-bubble.sh stop

Multi-instance:
  PI_PET_BUBBLE_ID controls which row is targeted.
  All rows are rendered by one Windows overlay window, stacked vertically.
  Click a row to focus its terminal; drag any row to move the whole stack.
EOF
}

json_write() {
  local action="$1"
  local status="${2:-}"
  local text="${3:-}"
  local x="${4:-}"
  local y="${5:-}"

  mkdir -p "$bubble_dir"

  ACTION="$action" STATUS="$status" TEXT="$text" X="$x" Y="$y" DIR_LABEL="$dir_label" OWNER_PID="$owner_pid" COMMAND_FILE="$command_file" python3 - <<'PY'
import json, os, tempfile, time
path = os.environ["COMMAND_FILE"]
data = {
    "seq": time.time_ns(),
    "action": os.environ.get("ACTION", "set"),
    "dir": os.environ.get("DIR_LABEL", ""),
    "pid": os.environ.get("OWNER_PID", ""),
}
status = os.environ.get("STATUS", "")
text = os.environ.get("TEXT", "")
x = os.environ.get("X", "")
y = os.environ.get("Y", "")
if status:
    data["status"] = status
if text:
    data["text"] = text
if x:
    data["x"] = float(x)
if y:
    data["y"] = float(y)
parent = os.path.dirname(path)
os.makedirs(parent, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".pet-bubble-", suffix=".json", dir=parent, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

cleanup_stale_rows() {
  mkdir -p "$root_dir"
  local d pid
  for d in "$root_dir"/*; do
    [[ -d "$d" ]] || continue
    [[ "$(basename "$d")" != "$bubble_id" ]] || continue

    pid="$(python3 - "$d/command.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        print(json.load(f).get('pid', ''))
except Exception:
    pass
PY
)"

    # Old pre-pid rows, or rows whose owning WSL/pi process is gone, are stale.
    if [[ -z "$pid" || ! -d "/proc/$pid" ]]; then
      rm -rf "$d"
    fi
  done
}

stop_old_managers() {
  # One-time migration helper: terminate older pet-bubble.ps1 managers that do not carry this version marker.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
    "\$version = '$manager_version'; Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*pet-bubble.ps1*' -and \$_.CommandLine -notlike ('*-ManagerVersion ' + \$version + '*') } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" \
    >/dev/null 2>&1 || true
}

ensure_started() {
  mkdir -p "$root_dir"
  cleanup_stale_rows
  stop_old_managers
  local ps_script win_root win_state
  ps_script="$(wslpath -w "$script_dir/pet-bubble.ps1")"
  win_root="$(wslpath -w "$root_dir")"
  win_state="$(wslpath -w "$manager_state_file")"

  # Safe to call repeatedly: pet-bubble.ps1 uses one global manager mutex.
  nohup powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File "$ps_script" \
    -RootPath "$win_root" \
    -StatePath "$win_state" \
    -ManagerVersion "$manager_version" \
    >"$log_file" 2>&1 &
  disown || true
}

cmd="${1:-}"
shift || true

case "$cmd" in
  -h|--help|help|"")
    usage
    ;;
  start)
    status="${1:-finished}"
    if [[ $# -gt 0 ]]; then shift; fi
    text="${*:-Ready}"
    json_write start "$status" "$text"
    ensure_started
    ;;
  thinking|answering|finished)
    text="$*"
    case "$cmd" in
      thinking)  [[ -n "$text" ]] || text="Working..." ;;
      answering) [[ -n "$text" ]] || text="Working..." ;;
      finished)  [[ -n "$text" ]] || text="Finished" ;;
    esac
    json_write set "$cmd" "$text"
    ensure_started
    ;;
  set)
    status="${1:-finished}"
    if [[ $# -gt 0 ]]; then shift; fi
    text="$*"
    json_write set "$status" "$text"
    ensure_started
    ;;
  move)
    x="${1:?x required}"
    y="${2:?y required}"
    json_write move "" "" "$x" "$y"
    ensure_started
    ;;
  stop)
    json_write stop
    # Do not start a new manager just to stop. If the manager is alive, it polls this file and exits when this was the last row.
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
