#!/usr/bin/env bash
#
# Multica Local Server — One-click Start
#
# Starts all local services: PostgreSQL → Backend → Frontend → Daemon
# Performs health checks at each step before proceeding.
#
# Usage:
#   ./scripts/local-start.sh          # Start all services
#   ./scripts/local-start.sh --stop   # Stop all services
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
CONFIG_FILE="$HOME/.multica/config.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[  OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[FAIL]${NC} $*"; }
step()    { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# Load env
load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    error "Missing .env file at $ENV_FILE"
    echo "  Run: cp .env.example .env  and configure it."
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

# Defaults after loading env
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
PORT="${PORT:-8080}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"

# ──────────────────────────────────────────────
# Stop mode
# ──────────────────────────────────────────────
stop_all() {
  step "Stopping all Multica services"

  # Stop daemon
  if cd "$PROJECT_DIR/server" && go run ./cmd/multica daemon status >/dev/null 2>&1; then
    info "Stopping daemon..."
    go run ./cmd/multica daemon stop 2>/dev/null && success "Daemon stopped" || warn "Daemon stop failed (may not be running)"
  else
    info "Daemon is not running"
  fi

  # Stop backend
  local backend_pids
  backend_pids=$(lsof -ti:"$PORT" 2>/dev/null || true)
  if [ -n "$backend_pids" ]; then
    info "Stopping backend (port $PORT)..."
    echo "$backend_pids" | xargs kill -9 2>/dev/null || true
    success "Backend stopped"
  else
    info "Backend is not running"
  fi

  # Stop frontend
  local frontend_pids
  frontend_pids=$(lsof -ti:"$FRONTEND_PORT" 2>/dev/null || true)
  if [ -n "$frontend_pids" ]; then
    info "Stopping frontend (port $FRONTEND_PORT)..."
    echo "$frontend_pids" | xargs kill -9 2>/dev/null || true
    success "Frontend stopped"
  else
    info "Frontend is not running"
  fi

  echo ""
  success "All services stopped. PostgreSQL container is still running."
  echo "  To stop PostgreSQL too: make db-down"
}

# ──────────────────────────────────────────────
# Step 1: PostgreSQL
# ──────────────────────────────────────────────
ensure_postgres() {
  step "Step 1/5: PostgreSQL (Podman)"

  # Check if podman is available
  if ! command -v podman >/dev/null 2>&1; then
    error "podman is not installed. Install it first: brew install podman"
    exit 1
  fi

  # Check if postgres container is already running and healthy
  if podman compose -f "$PROJECT_DIR/docker-compose.yml" exec -T postgres pg_isready -U "${POSTGRES_USER:-multica}" -d postgres >/dev/null 2>&1; then
    success "PostgreSQL is already running on port $POSTGRES_PORT"
    return
  fi

  info "Starting PostgreSQL container..."
  cd "$PROJECT_DIR"
  podman compose up -d postgres

  info "Waiting for PostgreSQL to be ready..."
  local retries=0
  local max_retries=30
  until podman compose exec -T postgres pg_isready -U "${POSTGRES_USER:-multica}" -d postgres >/dev/null 2>&1; do
    retries=$((retries + 1))
    if [ "$retries" -ge "$max_retries" ]; then
      error "PostgreSQL failed to start after ${max_retries}s"
      exit 1
    fi
    sleep 1
  done

  success "PostgreSQL is ready on port $POSTGRES_PORT"
}

# ──────────────────────────────────────────────
# Step 2: Database & Migrations
# ──────────────────────────────────────────────
ensure_database() {
  step "Step 2/5: Database & Migrations"

  local db_name="${POSTGRES_DB:-multica}"
  local db_user="${POSTGRES_USER:-multica}"

  # Check if database exists
  local db_exists
  db_exists="$(podman compose -f "$PROJECT_DIR/docker-compose.yml" exec -T postgres \
    psql -U "$db_user" -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$db_name'" 2>/dev/null || echo "")"

  if [ "$db_exists" != "1" ]; then
    info "Creating database '$db_name'..."
    podman compose -f "$PROJECT_DIR/docker-compose.yml" exec -T postgres \
      psql -U "$db_user" -d postgres -v ON_ERROR_STOP=1 \
      -c "CREATE DATABASE \"$db_name\"" >/dev/null
    success "Database '$db_name' created"
  else
    success "Database '$db_name' already exists"
  fi

  info "Running migrations..."
  cd "$PROJECT_DIR/server"
  go run ./cmd/migrate up 2>&1 | tail -1
  success "Migrations up to date"
}

# ──────────────────────────────────────────────
# Step 3: Go Backend
# ──────────────────────────────────────────────
start_backend() {
  step "Step 3/5: Go Backend (port $PORT)"

  # Check if already running
  if lsof -ti:"$PORT" >/dev/null 2>&1; then
    local existing_cmd
    existing_cmd=$(lsof -ti:"$PORT" | head -1 | xargs ps -p 2>/dev/null | tail -1 || echo "")
    if echo "$existing_cmd" | grep -q "go\|server"; then
      success "Backend is already running on port $PORT"
      return
    else
      warn "Port $PORT is occupied by another process. Killing it..."
      lsof -ti:"$PORT" | xargs kill -9 2>/dev/null || true
      sleep 1
    fi
  fi

  info "Starting Go backend..."
  cd "$PROJECT_DIR/server"
  go run ./cmd/server > /tmp/multica-backend.log 2>&1 &
  local backend_pid=$!

  # Wait for backend to be ready
  local retries=0
  local max_retries=30
  while ! curl -s "http://localhost:$PORT/health" >/dev/null 2>&1; do
    retries=$((retries + 1))
    if [ "$retries" -ge "$max_retries" ]; then
      error "Backend failed to start after ${max_retries}s"
      echo "  Check logs: cat /tmp/multica-backend.log"
      exit 1
    fi
    # Check if process is still alive
    if ! kill -0 "$backend_pid" 2>/dev/null; then
      error "Backend process exited unexpectedly"
      echo "  Check logs: cat /tmp/multica-backend.log"
      exit 1
    fi
    sleep 1
  done

  success "Backend running at http://localhost:$PORT (pid $backend_pid)"
}

# ──────────────────────────────────────────────
# Step 4: Next.js Frontend
# ──────────────────────────────────────────────
start_frontend() {
  step "Step 4/5: Next.js Frontend (port $FRONTEND_PORT)"

  # Check if already running
  if curl -s "http://localhost:$FRONTEND_PORT" >/dev/null 2>&1; then
    success "Frontend is already running on port $FRONTEND_PORT"
    return
  fi

  info "Starting Next.js frontend..."
  cd "$PROJECT_DIR"
  pnpm dev:web > /tmp/multica-frontend.log 2>&1 &
  local frontend_pid=$!

  # Wait for frontend to be ready (Next.js takes a while to compile)
  local retries=0
  local max_retries=60
  while ! curl -s "http://localhost:$FRONTEND_PORT" >/dev/null 2>&1; do
    retries=$((retries + 1))
    if [ "$retries" -ge "$max_retries" ]; then
      error "Frontend failed to start after ${max_retries}s"
      echo "  Check logs: cat /tmp/multica-frontend.log"
      exit 1
    fi
    if ! kill -0 "$frontend_pid" 2>/dev/null; then
      error "Frontend process exited unexpectedly"
      echo "  Check logs: cat /tmp/multica-frontend.log"
      exit 1
    fi
    sleep 1
  done

  success "Frontend running at http://localhost:$FRONTEND_PORT (pid $frontend_pid)"
}

# ──────────────────────────────────────────────
# Step 5: Daemon
# ──────────────────────────────────────────────
start_daemon() {
  step "Step 5/5: Agent Daemon"

  cd "$PROJECT_DIR/server"

  # Check if daemon is already running
  if go run ./cmd/multica daemon status >/dev/null 2>&1; then
    success "Daemon is already running"
    return
  fi

  # Check if CLI is authenticated
  if [ ! -f "$CONFIG_FILE" ]; then
    warn "CLI config not found at $CONFIG_FILE"
    warn "Please run: cd server && go run ./cmd/multica login"
    warn "Then re-run this script."
    return
  fi

  # Check if token exists in config
  if ! grep -q '"token"' "$CONFIG_FILE" 2>/dev/null || grep -q '"token":""' "$CONFIG_FILE" 2>/dev/null || grep -q '"token": ""' "$CONFIG_FILE" 2>/dev/null; then
    # token field missing or empty — check if config has no token at all
    local has_token
    has_token=$(python3 -c "
import json, sys
try:
    c = json.load(open('$CONFIG_FILE'))
    t = c.get('token', '')
    print('yes' if t else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

    if [ "$has_token" = "no" ]; then
      warn "Not authenticated. Starting login flow..."
      go run ./cmd/multica login
      echo ""
    fi
  fi

  # Ensure config points to local server
  local server_url
  server_url=$(python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
print(c.get('server_url', ''))
" 2>/dev/null || echo "")

  if [ -n "$server_url" ] && [ "$server_url" != "http://localhost:$PORT" ]; then
    warn "CLI is pointing to $server_url (not localhost:$PORT)"
    warn "Run: cd server && go run ./cmd/multica login  to re-authenticate with local server"
    return
  fi

  info "Starting daemon..."
  go run ./cmd/multica daemon start 2>&1

  # Verify daemon started
  sleep 2
  if go run ./cmd/multica daemon status >/dev/null 2>&1; then
    success "Daemon is running"
  else
    warn "Daemon may not have started. Check logs:"
    echo "  cat ~/.multica/daemon.log"
  fi
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
  echo -e "${CYAN}"
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║   Multica Local Server Launcher  🚀  ║"
  echo "  ╚══════════════════════════════════════╝"
  echo -e "${NC}"

  load_env

  if [ "${1:-}" = "--stop" ] || [ "${1:-}" = "stop" ]; then
    stop_all
    exit 0
  fi

  ensure_postgres
  ensure_database
  start_backend
  start_frontend
  start_daemon

  echo ""
  echo -e "${GREEN}━━━ All services are running! ━━━${NC}"
  echo ""
  echo "  🌐 Frontend:  http://localhost:$FRONTEND_PORT"
  echo "  🔧 Backend:   http://localhost:$PORT"
  echo "  🗄️  Database:  localhost:$POSTGRES_PORT"
  echo "  🤖 Daemon:    running (logs: ~/.multica/daemon.log)"
  echo ""
  echo "  📋 Logs:"
  echo "     Backend:  cat /tmp/multica-backend.log"
  echo "     Frontend: cat /tmp/multica-frontend.log"
  echo "     Daemon:   cat ~/.multica/daemon.log"
  echo ""
  echo "  🛑 To stop:   ./scripts/local-start.sh --stop"
  echo ""
}

main "$@"
