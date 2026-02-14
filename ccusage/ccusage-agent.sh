#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ccusage-agent.sh - Lightweight data server for ccusage JSON data
# =============================================================================

# --- Configuration ---
PORT=8098
OUTPUT_DIR="${CCUSAGE_OUTPUT_DIR:-/tmp/ccusage-data}"
REFRESH_INTERVAL=0
SINCE=""
UNTIL=""
BG_PIDS=()

# --- Helpers ---

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Fetches ccusage data (daily, monthly, session) as JSON and serves it via HTTP
with CORS support.

Options:
  --port N        Port for HTTP server (default: $PORT)
  --refresh N     Re-fetch ccusage data every N minutes (0 = disabled)
  --since DATE    Pass --since DATE to ccusage commands
  --until DATE    Pass --until DATE to ccusage commands
  --output DIR    Output directory (default: $OUTPUT_DIR)
  --help          Show this help message

Environment:
  CCUSAGE_OUTPUT_DIR   Override default output directory

EOF
  exit 0
}

# --- Argument Parsing ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2 ;;
    --refresh)
      REFRESH_INTERVAL="$2"; shift 2 ;;
    --since)
      SINCE="$2"; shift 2 ;;
    --until)
      UNTIL="$2"; shift 2 ;;
    --output)
      OUTPUT_DIR="$2"; shift 2 ;;
    --help|-h)
      usage ;;
    *)
      die "Unknown option: $1 (use --help for usage)" ;;
  esac
done

# --- Dependency Check ---

check_deps() {
  local missing=()
  command -v ccusage  >/dev/null 2>&1 || missing+=(ccusage)
  command -v python3  >/dev/null 2>&1 || missing+=(python3)
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required dependencies: ${missing[*]} (install ccusage with: npm install -g ccusage)"
  fi
}

# --- Data Fetching ---

build_ccusage_args() {
  local args=()
  [[ -n "$SINCE" ]] && args+=(--since "$SINCE")
  [[ -n "$UNTIL" ]] && args+=(--until "$UNTIL")
  echo "${args[@]:-}"
}

fetch_report() {
  local report="$1"
  local extra_args="$2"
  # shellcheck disable=SC2086
  if ccusage "$report" --json $extra_args > "$OUTPUT_DIR/${report}.json" 2>/dev/null; then
    log "  $report.json written ($(wc -c < "$OUTPUT_DIR/${report}.json") bytes)"
  else
    log "  WARNING: Failed to fetch $report report, writing empty array"
    echo "[]" > "$OUTPUT_DIR/${report}.json"
  fi
}

fetch_data() {
  log "Fetching ccusage data (parallel)..."
  mkdir -p "$OUTPUT_DIR"

  local extra_args
  extra_args=$(build_ccusage_args)

  for report in daily monthly session; do
    fetch_report "$report" "$extra_args" &
  done
  wait

  # Write meta.json
  cat > "$OUTPUT_DIR/meta.json" <<METAEOF
{
  "hostname": "$(hostname)",
  "updated": "$(date -Iseconds)"
}
METAEOF
  log "  meta.json written"
  log "Data fetch complete."
}

# --- Background Refresh Loop ---

refresh_loop() {
  local interval_seconds=$(( REFRESH_INTERVAL * 60 ))
  while true; do
    sleep "$interval_seconds"
    log "Refresh interval reached ($REFRESH_INTERVAL min), re-fetching data..."
    fetch_data
  done
}

# --- CORS HTTP Server (Python inline) ---

start_server() {
  log "Starting HTTP server on port $PORT (serving $OUTPUT_DIR)..."

  python3 - "$PORT" "$OUTPUT_DIR" <<'PYEOF' &
import sys
import os
from http.server import HTTPServer, SimpleHTTPRequestHandler

port = int(sys.argv[1])
directory = sys.argv[2]

class CORSHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(200)
        self.end_headers()

    def log_message(self, format, *args):
        pass  # silence per-request logs

httpd = HTTPServer(("0.0.0.0", port), CORSHandler)
print(f"[ccusage-agent] CORS HTTP server listening on 0.0.0.0:{port}", flush=True)
httpd.serve_forever()
PYEOF

  BG_PIDS+=($!)
}

# --- Signal Handling ---

cleanup() {
  log "Shutting down..."
  for pid in "${BG_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  log "Goodbye."
  exit 0
}

trap cleanup SIGINT SIGTERM

# --- Main ---

main() {
  log "ccusage-agent starting"
  check_deps

  fetch_data
  start_server

  if [[ "$REFRESH_INTERVAL" -gt 0 ]]; then
    log "Background refresh enabled: every $REFRESH_INTERVAL minute(s)"
    refresh_loop &
    BG_PIDS+=($!)
  fi

  log "Ready. Data at http://localhost:$PORT/"
  wait
}

main
