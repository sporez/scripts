#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ccusage-dashboard.sh - Generate a self-contained HTML dashboard for ccusage
# =============================================================================

# --- Configuration ---
REMOTE_SOURCES=(
     "apps|http://apps.sporez.us:8098"
    # "work|http://work-server:8098"
)
LOCAL_NAME="$(hostname)"
OUTPUT_FILE="ccusage-dashboard.html"
SERVE_PORT=8099
SINCE=""
UNTIL=""
DO_SERVE=false
DO_OPEN=false

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

Generates a self-contained HTML dashboard from ccusage data.

Options:
  --serve           Start HTTP server on port $SERVE_PORT after generating
  --open            Open the dashboard in default browser
  --since DATE      Pass --since to ccusage (e.g. 2025-01-01)
  --until DATE      Pass --until to ccusage (e.g. 2025-12-31)
  --output FILE     Output file (default: $OUTPUT_FILE)
  --port N          Port for --serve (default: $SERVE_PORT)
  --help            Show this help message

EOF
  exit 0
}

# --- Argument Parsing ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serve)     DO_SERVE=true; shift ;;
    --open)      DO_OPEN=true; shift ;;
    --since)     SINCE="$2"; shift 2 ;;
    --until)     UNTIL="$2"; shift 2 ;;
    --output)    OUTPUT_FILE="$2"; shift 2 ;;
    --port)      SERVE_PORT="$2"; shift 2 ;;
    --help|-h)   usage ;;
    *)           die "Unknown option: $1 (use --help)" ;;
  esac
done

# --- Dependency Check ---

command -v ccusage >/dev/null 2>&1 || die "ccusage is required but not found (install with: npm install -g ccusage)"

# --- Build ccusage extra args ---

build_args() {
  local args=""
  [[ -n "$SINCE" ]] && args+=" --since $SINCE"
  [[ -n "$UNTIL" ]] && args+=" --until $UNTIL"
  echo "$args"
}

EXTRA_ARGS=$(build_args)

# --- Fetch local data ---

log "Fetching local ccusage data for '$LOCAL_NAME'..."

TMPDIR_CC=$(mktemp -d)
trap "rm -rf '$TMPDIR_CC'" EXIT

fetch_local_report() {
  local report_type="$1"
  local outfile="$2"
  log "  Fetching $report_type..."
  # shellcheck disable=SC2086
  if ccusage "$report_type" --json $EXTRA_ARGS > "$outfile" 2>/dev/null; then
    log "  $report_type OK ($(wc -c < "$outfile") bytes)"
  else
    log "  WARNING: Failed to fetch $report_type, using empty data"
    echo "{}" > "$outfile"
  fi
}

fetch_local_report daily   "$TMPDIR_CC/daily.json"   &
fetch_local_report monthly "$TMPDIR_CC/monthly.json"  &
fetch_local_report session "$TMPDIR_CC/session.json"  &
wait

LOCAL_DAILY=$(cat "$TMPDIR_CC/daily.json")
LOCAL_MONTHLY=$(cat "$TMPDIR_CC/monthly.json")
LOCAL_SESSION=$(cat "$TMPDIR_CC/session.json")

log "Local data fetched."

# --- Fetch remote data ---

REMOTE_DATA_BLOCKS=""

for entry in "${REMOTE_SOURCES[@]+"${REMOTE_SOURCES[@]}"}"; do
  [[ -z "$entry" ]] && continue
  NAME="${entry%%|*}"
  URL="${entry#*|}"
  log "Fetching remote data from '$NAME' at $URL..."

  curl -sf --connect-timeout 5 --max-time 15 "$URL/daily.json"   > "$TMPDIR_CC/r_daily.json"   2>/dev/null &
  curl -sf --connect-timeout 5 --max-time 15 "$URL/monthly.json" > "$TMPDIR_CC/r_monthly.json"  2>/dev/null &
  curl -sf --connect-timeout 5 --max-time 15 "$URL/session.json" > "$TMPDIR_CC/r_session.json"  2>/dev/null &
  wait

  R_DAILY=$(cat "$TMPDIR_CC/r_daily.json" 2>/dev/null)
  R_MONTHLY=$(cat "$TMPDIR_CC/r_monthly.json" 2>/dev/null)
  R_SESSION=$(cat "$TMPDIR_CC/r_session.json" 2>/dev/null)
  [[ -z "$R_DAILY" ]]   && { log "  WARNING: Could not reach $URL/daily.json";   R_DAILY="[]"; }   || log "  daily.json OK"
  [[ -z "$R_MONTHLY" ]] && { log "  WARNING: Could not reach $URL/monthly.json"; R_MONTHLY="[]"; } || log "  monthly.json OK"
  [[ -z "$R_SESSION" ]] && { log "  WARNING: Could not reach $URL/session.json"; R_SESSION="[]"; } || log "  session.json OK"

  REMOTE_DATA_BLOCKS+="
    {
      name: $(printf '%s' "$NAME" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
      daily: $R_DAILY,
      monthly: $R_MONTHLY,
      sessions: $R_SESSION
    },"
done

# --- Generate HTML ---

log "Generating dashboard: $OUTPUT_FILE"

# Part 1: HTML head + CSS (quoted heredoc, no interpolation)
cat << 'PART1_EOF' > "$OUTPUT_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Claude Code Usage Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
  :root {
    --bg-primary: #0f172a;
    --bg-secondary: #1e293b;
    --bg-tertiary: #334155;
    --text-primary: #f1f5f9;
    --text-secondary: #94a3b8;
    --accent-primary: #3b82f6;
    --accent-green: #10b981;
    --accent-amber: #f59e0b;
    --accent-red: #ef4444;
    --accent-purple: #8b5cf6;
    --radius: 12px;
  }

  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    background: var(--bg-primary);
    color: var(--text-primary);
    font-family: 'JetBrains Mono', 'Fira Code', 'SF Mono', 'Cascadia Code', 'Consolas', monospace;
    line-height: 1.6;
    padding: 24px;
    min-height: 100vh;
  }

  .container {
    max-width: 1400px;
    margin: 0 auto;
  }

  /* Header */
  .header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 16px;
    margin-bottom: 32px;
    padding-bottom: 24px;
    border-bottom: 1px solid var(--bg-tertiary);
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 16px;
  }

  .header h1 {
    font-size: 1.75rem;
    font-weight: 700;
    letter-spacing: -0.5px;
    background: linear-gradient(135deg, var(--text-primary), var(--accent-primary));
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
  }

  .live-indicator {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 0.8rem;
    color: var(--accent-green);
    font-weight: 500;
  }

  .pulse-dot {
    width: 8px;
    height: 8px;
    background: var(--accent-green);
    border-radius: 50%;
    animation: pulse 2s ease-in-out infinite;
  }

  @keyframes pulse {
    0%, 100% { opacity: 1; box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.4); }
    50% { opacity: 0.7; box-shadow: 0 0 0 6px rgba(16, 185, 129, 0); }
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }

  .timestamp {
    font-size: 0.75rem;
    color: var(--text-secondary);
  }

  .source-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 12px;
    border-radius: 20px;
    font-size: 0.75rem;
    font-weight: 600;
    border: 1px solid;
  }

  .source-pill .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
  }

  /* Cards */
  .card {
    background: var(--bg-secondary);
    border: 1px solid var(--bg-tertiary);
    border-radius: var(--radius);
    padding: 24px;
    transition: transform 0.2s ease, box-shadow 0.2s ease;
  }

  .card:hover {
    transform: translateY(-2px);
    box-shadow: 0 8px 25px rgba(0, 0, 0, 0.3);
  }

  .card h2 {
    font-size: 1rem;
    font-weight: 600;
    margin-bottom: 16px;
    color: var(--text-secondary);
  }

  /* Summary grid */
  .summary-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 20px;
    margin-bottom: 28px;
  }

  .stat-card {
    background: var(--bg-secondary);
    border: 1px solid var(--bg-tertiary);
    border-radius: var(--radius);
    padding: 24px;
    position: relative;
    overflow: hidden;
    transition: transform 0.2s ease, box-shadow 0.2s ease;
  }

  .stat-card:hover {
    transform: translateY(-2px);
    box-shadow: 0 8px 25px rgba(0, 0, 0, 0.3);
  }

  .stat-card::before {
    content: '';
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    width: 4px;
  }

  .stat-card.amber::before { background: var(--accent-amber); }
  .stat-card.blue::before { background: var(--accent-primary); }
  .stat-card.green::before { background: var(--accent-green); }
  .stat-card.purple::before { background: var(--accent-purple); }

  .stat-card .label {
    font-size: 0.8rem;
    color: var(--text-secondary);
    margin-bottom: 8px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .stat-card .value {
    font-size: 2rem;
    font-weight: 700;
    line-height: 1.2;
  }

  .stat-card.amber .value { color: var(--accent-amber); }
  .stat-card.blue .value { color: var(--accent-primary); }
  .stat-card.green .value { color: var(--accent-green); }
  .stat-card.purple .value { color: var(--accent-purple); }

  .stat-card .sub {
    font-size: 0.75rem;
    color: var(--text-secondary);
    margin-top: 4px;
  }

  /* Chart containers */
  .chart-card {
    margin-bottom: 28px;
  }

  .chart-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 16px;
  }

  .chart-header h2 {
    margin-bottom: 0;
  }

  .chart-wrapper {
    position: relative;
    width: 100%;
    height: 350px;
  }

  .chart-wrapper canvas {
    width: 100% !important;
    height: 100% !important;
  }

  .toggle-btn {
    background: var(--bg-tertiary);
    color: var(--text-secondary);
    border: 1px solid rgba(148, 163, 184, 0.2);
    padding: 6px 14px;
    border-radius: 8px;
    font-family: inherit;
    font-size: 0.75rem;
    cursor: pointer;
    transition: all 0.2s ease;
  }

  .toggle-btn:hover {
    background: var(--accent-primary);
    color: var(--text-primary);
    border-color: var(--accent-primary);
  }

  .toggle-btn.active {
    background: var(--accent-primary);
    color: var(--text-primary);
    border-color: var(--accent-primary);
  }

  /* Tables */
  .table-card {
    margin-bottom: 28px;
    overflow: hidden;
  }

  .table-scroll {
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
  }

  .data-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.82rem;
  }

  .data-table th {
    text-align: left;
    padding: 12px 16px;
    background: var(--bg-tertiary);
    color: var(--text-secondary);
    font-weight: 600;
    text-transform: uppercase;
    font-size: 0.72rem;
    letter-spacing: 0.5px;
    white-space: nowrap;
    position: sticky;
    top: 0;
  }

  .data-table td {
    padding: 10px 16px;
    border-bottom: 1px solid rgba(51, 65, 85, 0.5);
    white-space: nowrap;
  }

  .data-table tr {
    transition: background 0.15s ease;
  }

  .data-table tbody tr:hover {
    background: rgba(59, 130, 246, 0.05);
  }

  .data-table .subtotal-row {
    background: rgba(59, 130, 246, 0.08);
    font-weight: 600;
  }

  .data-table .subtotal-row:hover {
    background: rgba(59, 130, 246, 0.12);
  }

  .data-table .grand-total-row {
    background: rgba(245, 158, 11, 0.1);
    font-weight: 700;
    font-size: 0.85rem;
  }

  .data-table .grand-total-row:hover {
    background: rgba(245, 158, 11, 0.15);
  }

  .data-table .cost-cell {
    color: var(--accent-amber);
    font-weight: 600;
  }

  .sessions-scroll {
    max-height: 600px;
    overflow-y: auto;
  }

  .show-all-btn {
    display: block;
    width: 100%;
    padding: 12px;
    margin-top: 0;
    background: var(--bg-tertiary);
    color: var(--text-secondary);
    border: none;
    font-family: inherit;
    font-size: 0.8rem;
    cursor: pointer;
    transition: all 0.2s ease;
    border-radius: 0 0 var(--radius) var(--radius);
  }

  .show-all-btn:hover {
    background: var(--accent-primary);
    color: var(--text-primary);
  }

  /* Donut chart layout */
  .donut-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 28px;
    margin-bottom: 28px;
  }

  .donut-wrapper {
    position: relative;
    max-width: 350px;
    margin: 0 auto;
  }

  .model-legend {
    display: flex;
    flex-direction: column;
    gap: 8px;
    justify-content: center;
  }

  .legend-item {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 0.8rem;
  }

  .legend-color {
    width: 12px;
    height: 12px;
    border-radius: 3px;
    flex-shrink: 0;
  }

  .legend-name {
    color: var(--text-secondary);
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .legend-value {
    color: var(--accent-amber);
    font-weight: 600;
    white-space: nowrap;
  }

  /* Footer */
  .footer {
    text-align: center;
    padding: 24px;
    color: var(--text-secondary);
    font-size: 0.72rem;
    border-top: 1px solid var(--bg-tertiary);
    margin-top: 16px;
  }

  /* Responsive */
  @media (max-width: 1024px) {
    .summary-grid {
      grid-template-columns: repeat(2, 1fr);
    }
    .donut-grid {
      grid-template-columns: 1fr;
    }
  }

  @media (max-width: 640px) {
    body { padding: 12px; }
    .summary-grid { grid-template-columns: 1fr; }
    .header { flex-direction: column; align-items: flex-start; }
    .stat-card .value { font-size: 1.5rem; }
    .chart-wrapper { height: 280px; }
  }

  /* Scrollbar styling */
  ::-webkit-scrollbar { width: 6px; height: 6px; }
  ::-webkit-scrollbar-track { background: var(--bg-primary); }
  ::-webkit-scrollbar-thumb { background: var(--bg-tertiary); border-radius: 3px; }
  ::-webkit-scrollbar-thumb:hover { background: var(--text-secondary); }
</style>
</head>
<body>
<div class="container">

  <!-- Header -->
  <div class="header">
    <div class="header-left">
      <h1>Claude Code Usage</h1>
      <div class="live-indicator">
        <span class="pulse-dot"></span>
        Live
      </div>
    </div>
    <div class="header-right">
      <span class="timestamp" id="last-updated"></span>
      <div id="source-pills"></div>
    </div>
  </div>

  <!-- Summary Cards -->
  <div class="summary-grid">
    <div class="stat-card amber">
      <div class="label">Total Cost</div>
      <div class="value" id="total-cost">--</div>
      <div class="sub" id="cost-sub"></div>
    </div>
    <div class="stat-card blue">
      <div class="label">Total Tokens</div>
      <div class="value" id="total-tokens">--</div>
      <div class="sub" id="tokens-sub"></div>
    </div>
    <div class="stat-card green">
      <div class="label">Days Tracked</div>
      <div class="value" id="total-days">--</div>
      <div class="sub" id="days-sub"></div>
    </div>
    <div class="stat-card purple">
      <div class="label">Sessions</div>
      <div class="value" id="total-sessions">--</div>
      <div class="sub" id="sessions-sub"></div>
    </div>
  </div>

  <!-- Daily Cost Chart -->
  <div class="card chart-card">
    <div class="chart-header">
      <h2>Daily Cost</h2>
      <button class="toggle-btn" id="cost-stack-toggle" onclick="toggleCostChart()">Grouped</button>
    </div>
    <div class="chart-wrapper">
      <canvas id="dailyCostChart"></canvas>
    </div>
  </div>

  <!-- Daily Token Chart -->
  <div class="card chart-card">
    <div class="chart-header">
      <h2>Daily Token Usage</h2>
    </div>
    <div class="chart-wrapper">
      <canvas id="dailyTokenChart"></canvas>
    </div>
  </div>

  <!-- Model Donut -->
  <div class="card chart-card">
    <h2>Cost by Model</h2>
    <div class="donut-grid">
      <div class="donut-wrapper">
        <canvas id="modelDonutChart"></canvas>
      </div>
      <div class="model-legend" id="model-legend"></div>
    </div>
  </div>

  <!-- Monthly Table -->
  <div class="card table-card">
    <h2>Monthly Summary</h2>
    <div class="table-scroll">
      <table class="data-table" id="monthly-table">
        <thead>
          <tr>
            <th>Month</th>
            <th>Source</th>
            <th>Input Tokens</th>
            <th>Output Tokens</th>
            <th>Total Tokens</th>
            <th>Cost</th>
            <th>Models</th>
          </tr>
        </thead>
        <tbody></tbody>
      </table>
    </div>
  </div>

  <!-- Sessions Table -->
  <div class="card table-card">
    <h2>Sessions</h2>
    <div class="table-scroll sessions-scroll" id="sessions-container">
      <table class="data-table" id="sessions-table">
        <thead>
          <tr>
            <th>Source</th>
            <th>Project</th>
            <th>Last Activity</th>
            <th>Input</th>
            <th>Output</th>
            <th>Total Tokens</th>
            <th>Cost</th>
          </tr>
        </thead>
        <tbody></tbody>
      </table>
    </div>
    <button class="show-all-btn" id="show-all-sessions" onclick="showAllSessions()">Show All</button>
  </div>

  <div class="footer">
    Generated by ccusage-dashboard.sh
  </div>
</div>

<script>
PART1_EOF

# Part 2: Inject data (unquoted to allow variable expansion)
cat << PART2_EOF >> "$OUTPUT_FILE"
const SOURCES = [
  {
    name: $(printf '%s' "$LOCAL_NAME" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
    daily: $LOCAL_DAILY,
    monthly: $LOCAL_MONTHLY,
    sessions: $LOCAL_SESSION
  },${REMOTE_DATA_BLOCKS}
];
const GENERATED_AT = "$(date -Iseconds)";
PART2_EOF

# Part 3: Dashboard JS logic (quoted heredoc, no interpolation)
cat << 'PART3_EOF' >> "$OUTPUT_FILE"

// ===========================================================================
// Helpers
// ===========================================================================

function getCost(item) {
  if (item.totalCost !== undefined) return item.totalCost;
  if (item.costUSD !== undefined) return item.costUSD;
  if (item.cost !== undefined) return item.cost;
  return 0;
}

function formatCurrency(n) {
  if (n == null || isNaN(n)) return '$0.00';
  return '$' + n.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function formatTokens(n) {
  if (n == null || isNaN(n)) return '0';
  if (n >= 1e9) return (n / 1e9).toFixed(1) + 'B';
  if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
  return n.toLocaleString();
}

function formatNumber(n) {
  if (n == null || isNaN(n)) return '0';
  return n.toLocaleString();
}

function formatDate(d) {
  if (!d) return '--';
  return d;
}

// Get an array from a source's daily/monthly/sessions data.
// ccusage wraps arrays in an object like { daily: [...] }, { monthly: [...] }, { sessions: [...] }
function getArray(data, key) {
  if (!data) return [];
  if (Array.isArray(data)) return data;
  if (data[key] && Array.isArray(data[key])) return data[key];
  // Try first key
  const keys = Object.keys(data);
  if (keys.length === 1 && Array.isArray(data[keys[0]])) return data[keys[0]];
  return [];
}

const SOURCE_COLORS = [
  '#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6',
  '#ec4899', '#06b6d4', '#f97316', '#14b8a6', '#a855f7'
];

function getSourceColor(idx) {
  return SOURCE_COLORS[idx % SOURCE_COLORS.length];
}

// ===========================================================================
// Parse sources
// ===========================================================================

const sources = SOURCES.map((s, i) => ({
  name: s.name,
  color: getSourceColor(i),
  daily: getArray(s.daily, 'daily'),
  monthly: getArray(s.monthly, 'monthly'),
  sessions: getArray(s.sessions, 'sessions')
}));

// ===========================================================================
// Header
// ===========================================================================

document.getElementById('last-updated').textContent = 'Updated: ' + new Date(GENERATED_AT).toLocaleString();

const pillsContainer = document.getElementById('source-pills');
sources.forEach(s => {
  const pill = document.createElement('span');
  pill.className = 'source-pill';
  pill.style.borderColor = s.color;
  pill.style.color = s.color;
  pill.innerHTML = '<span class="dot" style="background:' + s.color + '"></span>' + s.name;
  pillsContainer.appendChild(pill);
});

// ===========================================================================
// Summary Cards
// ===========================================================================

let totalCost = 0, totalTokens = 0, totalSessions = 0;
const allDates = new Set();

sources.forEach(s => {
  s.daily.forEach(d => {
    totalCost += getCost(d);
    totalTokens += (d.totalTokens || 0);
    if (d.date) allDates.add(d.date);
  });
  totalSessions += s.sessions.length;
});

document.getElementById('total-cost').textContent = formatCurrency(totalCost);
document.getElementById('cost-sub').textContent = 'across ' + sources.length + ' source' + (sources.length > 1 ? 's' : '');
document.getElementById('total-tokens').textContent = formatTokens(totalTokens);
document.getElementById('tokens-sub').textContent = 'input + output + cache';
document.getElementById('total-days').textContent = allDates.size;
document.getElementById('days-sub').textContent = allDates.size > 0 ? [...allDates].sort()[0] + ' → ' + [...allDates].sort().pop() : '';
document.getElementById('total-sessions').textContent = totalSessions;
document.getElementById('sessions-sub').textContent = 'across all sources';

// ===========================================================================
// Daily Cost Chart
// ===========================================================================

// Collect all unique dates across sources
const allDatesArr = [...allDates].sort();

let costChartStacked = true;

const costDatasets = sources.map(s => {
  const byDate = {};
  s.daily.forEach(d => { byDate[d.date] = getCost(d); });
  return {
    label: s.name,
    data: allDatesArr.map(date => byDate[date] || 0),
    backgroundColor: s.color,
    borderColor: s.color,
    borderWidth: 1,
    borderRadius: 3
  };
});

const costCtx = document.getElementById('dailyCostChart').getContext('2d');
let costChart = new Chart(costCtx, {
  type: 'bar',
  data: { labels: allDatesArr, datasets: costDatasets },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    interaction: { mode: 'index', intersect: false },
    plugins: {
      tooltip: {
        callbacks: {
          label: ctx => ctx.dataset.label + ': ' + formatCurrency(ctx.raw),
          footer: items => 'Total: ' + formatCurrency(items.reduce((a, b) => a + b.raw, 0))
        }
      },
      legend: {
        display: sources.length > 1,
        labels: { color: '#94a3b8', font: { family: "'JetBrains Mono', monospace", size: 11 } }
      }
    },
    scales: {
      x: {
        stacked: true,
        ticks: { color: '#94a3b8', font: { family: "'JetBrains Mono', monospace", size: 10 }, maxRotation: 45 },
        grid: { color: 'rgba(51,65,85,0.3)' }
      },
      y: {
        stacked: true,
        ticks: {
          color: '#94a3b8',
          font: { family: "'JetBrains Mono', monospace", size: 10 },
          callback: v => '$' + v.toFixed(0)
        },
        grid: { color: 'rgba(51,65,85,0.3)' }
      }
    }
  }
});

function toggleCostChart() {
  costChartStacked = !costChartStacked;
  costChart.options.scales.x.stacked = costChartStacked;
  costChart.options.scales.y.stacked = costChartStacked;
  costChart.update();
  const btn = document.getElementById('cost-stack-toggle');
  btn.textContent = costChartStacked ? 'Grouped' : 'Stacked';
  btn.classList.toggle('active', !costChartStacked);
}

// ===========================================================================
// Daily Token Chart
// ===========================================================================

const tokenTypes = [
  { key: 'inputTokens', label: 'Input', color: '#3b82f6' },
  { key: 'outputTokens', label: 'Output', color: '#10b981' },
  { key: 'cacheCreationTokens', label: 'Cache Create', color: '#f59e0b' },
  { key: 'cacheReadTokens', label: 'Cache Read', color: '#8b5cf6' }
];

// Aggregate tokens by date across all sources
const tokensByDate = {};
allDatesArr.forEach(d => { tokensByDate[d] = { inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 }; });
sources.forEach(s => {
  s.daily.forEach(d => {
    if (!tokensByDate[d.date]) tokensByDate[d.date] = { inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 };
    tokensByDate[d.date].inputTokens += (d.inputTokens || 0);
    tokensByDate[d.date].outputTokens += (d.outputTokens || 0);
    tokensByDate[d.date].cacheCreationTokens += (d.cacheCreationTokens || 0);
    tokensByDate[d.date].cacheReadTokens += (d.cacheReadTokens || 0);
  });
});

const tokenDatasets = tokenTypes.map(t => ({
  label: t.label,
  data: allDatesArr.map(d => tokensByDate[d][t.key] || 0),
  backgroundColor: t.color,
  borderColor: t.color,
  borderWidth: 1,
  borderRadius: 3
}));

const tokenCtx = document.getElementById('dailyTokenChart').getContext('2d');
new Chart(tokenCtx, {
  type: 'bar',
  data: { labels: allDatesArr, datasets: tokenDatasets },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    interaction: { mode: 'index', intersect: false },
    plugins: {
      tooltip: {
        callbacks: {
          label: ctx => ctx.dataset.label + ': ' + formatTokens(ctx.raw),
          footer: items => 'Total: ' + formatTokens(items.reduce((a, b) => a + b.raw, 0))
        }
      },
      legend: {
        labels: { color: '#94a3b8', font: { family: "'JetBrains Mono', monospace", size: 11 } }
      }
    },
    scales: {
      x: {
        stacked: true,
        ticks: { color: '#94a3b8', font: { family: "'JetBrains Mono', monospace", size: 10 }, maxRotation: 45 },
        grid: { color: 'rgba(51,65,85,0.3)' }
      },
      y: {
        stacked: true,
        ticks: {
          color: '#94a3b8',
          font: { family: "'JetBrains Mono', monospace", size: 10 },
          callback: v => formatTokens(v)
        },
        grid: { color: 'rgba(51,65,85,0.3)' }
      }
    }
  }
});

// ===========================================================================
// Model Donut Chart
// ===========================================================================

const modelCosts = {};
sources.forEach(s => {
  s.daily.forEach(d => {
    if (d.modelBreakdowns) {
      d.modelBreakdowns.forEach(mb => {
        const name = mb.modelName || mb.model || 'unknown';
        const cost = mb.cost || mb.costUSD || mb.totalCost || 0;
        modelCosts[name] = (modelCosts[name] || 0) + cost;
      });
    }
  });
});

const modelEntries = Object.entries(modelCosts).sort((a, b) => b[1] - a[1]);
const modelColors = ['#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6', '#ec4899', '#06b6d4', '#f97316', '#14b8a6', '#a855f7'];

const donutCtx = document.getElementById('modelDonutChart').getContext('2d');
new Chart(donutCtx, {
  type: 'doughnut',
  data: {
    labels: modelEntries.map(e => e[0]),
    datasets: [{
      data: modelEntries.map(e => e[1]),
      backgroundColor: modelEntries.map((_, i) => modelColors[i % modelColors.length]),
      borderColor: '#1e293b',
      borderWidth: 3,
      hoverBorderWidth: 0
    }]
  },
  options: {
    responsive: true,
    maintainAspectRatio: true,
    cutout: '65%',
    plugins: {
      legend: { display: false },
      tooltip: {
        callbacks: {
          label: ctx => ctx.label + ': ' + formatCurrency(ctx.raw)
        }
      }
    }
  },
  plugins: [{
    id: 'centerText',
    beforeDraw(chart) {
      const { width, height, ctx: c } = chart;
      c.save();
      c.font = 'bold 18px "JetBrains Mono", monospace';
      c.fillStyle = '#f59e0b';
      c.textAlign = 'center';
      c.textBaseline = 'middle';
      const total = modelEntries.reduce((a, b) => a + b[1], 0);
      c.fillText(formatCurrency(total), width / 2, height / 2 - 8);
      c.font = '11px "JetBrains Mono", monospace';
      c.fillStyle = '#94a3b8';
      c.fillText('total', width / 2, height / 2 + 14);
      c.restore();
    }
  }]
});

// Model legend
const legendEl = document.getElementById('model-legend');
modelEntries.forEach((entry, i) => {
  const div = document.createElement('div');
  div.className = 'legend-item';
  div.innerHTML = '<span class="legend-color" style="background:' + modelColors[i % modelColors.length] + '"></span>' +
    '<span class="legend-name">' + entry[0] + '</span>' +
    '<span class="legend-value">' + formatCurrency(entry[1]) + '</span>';
  legendEl.appendChild(div);
});

// ===========================================================================
// Monthly Table
// ===========================================================================

(function buildMonthlyTable() {
  const tbody = document.querySelector('#monthly-table tbody');

  // Collect all month rows: { month, source, data }
  const rows = [];
  sources.forEach(s => {
    s.monthly.forEach(m => {
      rows.push({ month: m.month, source: s.name, data: m });
    });
  });

  // Group by month
  const months = [...new Set(rows.map(r => r.month))].sort();
  let grandInput = 0, grandOutput = 0, grandTotal = 0, grandCost = 0;

  months.forEach(month => {
    const monthRows = rows.filter(r => r.month === month);
    let subInput = 0, subOutput = 0, subTotal = 0, subCost = 0;

    monthRows.forEach(r => {
      const d = r.data;
      const cost = getCost(d);
      subInput += (d.inputTokens || 0);
      subOutput += (d.outputTokens || 0);
      subTotal += (d.totalTokens || 0);
      subCost += cost;

      const tr = document.createElement('tr');
      tr.innerHTML =
        '<td>' + month + '</td>' +
        '<td>' + r.source + '</td>' +
        '<td>' + formatNumber(d.inputTokens || 0) + '</td>' +
        '<td>' + formatNumber(d.outputTokens || 0) + '</td>' +
        '<td>' + formatNumber(d.totalTokens || 0) + '</td>' +
        '<td class="cost-cell">' + formatCurrency(cost) + '</td>' +
        '<td>' + (d.modelsUsed || []).join(', ') + '</td>';
      tbody.appendChild(tr);
    });

    // Month subtotal
    if (sources.length > 1) {
      const str = document.createElement('tr');
      str.className = 'subtotal-row';
      str.innerHTML =
        '<td>' + month + '</td>' +
        '<td>SUBTOTAL</td>' +
        '<td>' + formatNumber(subInput) + '</td>' +
        '<td>' + formatNumber(subOutput) + '</td>' +
        '<td>' + formatNumber(subTotal) + '</td>' +
        '<td class="cost-cell">' + formatCurrency(subCost) + '</td>' +
        '<td></td>';
      tbody.appendChild(str);
    }

    grandInput += subInput;
    grandOutput += subOutput;
    grandTotal += subTotal;
    grandCost += subCost;
  });

  // Grand total
  const gtr = document.createElement('tr');
  gtr.className = 'grand-total-row';
  gtr.innerHTML =
    '<td>TOTAL</td>' +
    '<td></td>' +
    '<td>' + formatNumber(grandInput) + '</td>' +
    '<td>' + formatNumber(grandOutput) + '</td>' +
    '<td>' + formatNumber(grandTotal) + '</td>' +
    '<td class="cost-cell">' + formatCurrency(grandCost) + '</td>' +
    '<td></td>';
  tbody.appendChild(gtr);
})();

// ===========================================================================
// Sessions Table
// ===========================================================================

let showAllSessionsFlag = false;
const MAX_SESSIONS_DEFAULT = 50;

function getProjectName(session) {
  if (session.projectPath && session.projectPath !== 'Unknown Project') {
    // Extract last part of path
    const parts = session.projectPath.split('/').filter(Boolean);
    return parts[parts.length - 1] || session.projectPath;
  }
  if (session.sessionId) {
    // Clean up sessionId which looks like a path
    return session.sessionId.replace(/^-/, '').replace(/-/g, '/');
  }
  return '--';
}

function renderSessions() {
  const tbody = document.querySelector('#sessions-table tbody');
  tbody.innerHTML = '';

  // Collect all sessions
  const allSessions = [];
  sources.forEach(s => {
    s.sessions.forEach(sess => {
      allSessions.push({ source: s.name, session: sess });
    });
  });

  // Sort by cost descending
  allSessions.sort((a, b) => getCost(b.session) - getCost(a.session));

  const toShow = showAllSessionsFlag ? allSessions : allSessions.slice(0, MAX_SESSIONS_DEFAULT);

  toShow.forEach(item => {
    const s = item.session;
    const tr = document.createElement('tr');
    tr.innerHTML =
      '<td>' + item.source + '</td>' +
      '<td>' + getProjectName(s) + '</td>' +
      '<td>' + formatDate(s.lastActivity) + '</td>' +
      '<td>' + formatNumber(s.inputTokens || 0) + '</td>' +
      '<td>' + formatNumber(s.outputTokens || 0) + '</td>' +
      '<td>' + formatNumber(s.totalTokens || 0) + '</td>' +
      '<td class="cost-cell">' + formatCurrency(getCost(s)) + '</td>';
    tbody.appendChild(tr);
  });

  const btn = document.getElementById('show-all-sessions');
  if (allSessions.length <= MAX_SESSIONS_DEFAULT) {
    btn.style.display = 'none';
  } else {
    btn.style.display = 'block';
    btn.textContent = showAllSessionsFlag
      ? 'Show Top ' + MAX_SESSIONS_DEFAULT
      : 'Show All (' + allSessions.length + ' sessions)';
  }
}

function showAllSessions() {
  showAllSessionsFlag = !showAllSessionsFlag;
  renderSessions();
}

renderSessions();

</script>
</body>
</html>
PART3_EOF

log "Dashboard written to $OUTPUT_FILE ($(wc -c < "$OUTPUT_FILE") bytes)"

# --- Post-generation actions ---

if [[ "$DO_OPEN" == true ]]; then
  log "Opening dashboard..."
  xdg-open "$OUTPUT_FILE" 2>/dev/null || open "$OUTPUT_FILE" 2>/dev/null || log "Could not open browser"
fi

if [[ "$DO_SERVE" == true ]]; then
  log "Starting HTTP server on port $SERVE_PORT..."
  REAL_OUTPUT=$(realpath "$OUTPUT_FILE")
  SERVE_DIR=$(dirname "$REAL_OUTPUT")
  SERVE_FILE=$(basename "$REAL_OUTPUT")

  python3 -c "
import sys, os
from http.server import HTTPServer, SimpleHTTPRequestHandler

port = int(sys.argv[1])
directory = sys.argv[2]
index_file = sys.argv[3]

class DashboardHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)
    def do_GET(self):
        if self.path == '/' or self.path == '':
            self.path = '/' + index_file
        return super().do_GET()
    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        super().end_headers()

httpd = HTTPServer(('0.0.0.0', port), DashboardHandler)
print(f'Serving dashboard at http://0.0.0.0:{port}/', flush=True)
httpd.serve_forever()
" "$SERVE_PORT" "$SERVE_DIR" "$SERVE_FILE" &
  SERVER_PID=$!
  log "Dashboard at http://localhost:$SERVE_PORT/"
  log "Press Ctrl+C to stop"
  trap "kill $SERVER_PID 2>/dev/null; exit 0" SIGINT SIGTERM
  wait "$SERVER_PID"
fi
