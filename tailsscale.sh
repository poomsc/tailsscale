#!/bin/bash
# tailsscale.sh - Manage personal Tailscale with transparent IP routing
#
# Enables running two Tailscale accounts simultaneously on macOS:
# - Work Tailscale: runs natively (Headscale)
# - Personal Tailscale: runs in Docker with transparent routing via tun2proxy
#
# How it works:
#   1. Personal Tailscale runs in Docker exposing a SOCKS5 proxy (port 1055)
#   2. tun2proxy creates a TUN interface connected to that SOCKS5 proxy
#   3. /32 routes for personal Tailscale peer IPs route through the TUN
#   4. /32 routes are more specific than work Tailscale's /10 route, so macOS
#      automatically sends personal traffic through tun2proxy
#
# Usage: ./tailsscale.sh {up|down|status|refresh}
#
# Prerequisites: brew install tun2proxy

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOCKS5_PORT=1055
CONTAINER_NAME="tailsscale"
PID_FILE="/tmp/tun2proxy-personal.pid"
TUN_IF_FILE="/tmp/tun2proxy-personal-iface.txt"
ROUTES_FILE="/tmp/tailsscale-routes.txt"

# Point-to-point addresses for the TUN interface (RFC 2544 benchmark range)
TUN_LOCAL="198.18.0.1"
TUN_GW="198.18.0.2"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

require_tun2proxy() {
    if ! command -v tun2proxy-bin &>/dev/null; then
        echo -e "${RED}tun2proxy is required but not installed.${NC}"
        echo ""
        echo "Install: brew install tun2proxy"
        exit 1
    fi
}

is_tun2proxy_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

is_container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"
}

get_tun_interface() {
    if [ -f "$TUN_IF_FILE" ]; then
        local iface
        iface=$(cat "$TUN_IF_FILE")
        if ifconfig "$iface" &>/dev/null; then
            echo "$iface"
            return
        fi
    fi
}

# Get all IPv4 peer IPs from personal Tailscale
get_peer_ips() {
    docker exec "$CONTAINER_NAME" tailscale status --json 2>/dev/null | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
peers = data.get('Peer', {})
for key, peer in peers.items():
    for ip in peer.get('TailscaleIPs', []):
        if ':' not in ip:  # IPv4 only
            print(ip)
" 2>/dev/null || true
}

# Get this node's own personal Tailscale IP
get_self_ip() {
    docker exec "$CONTAINER_NAME" tailscale status --json 2>/dev/null | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
self = data.get('Self', {})
for ip in self.get('TailscaleIPs', []):
    if ':' not in ip:  # IPv4 only
        print(ip)
" 2>/dev/null || true
}

add_routes() {
    local peer_ips
    peer_ips=$(get_peer_ips)

    if [ -z "$peer_ips" ]; then
        echo -e "${YELLOW}No personal Tailscale peers found.${NC}"
        echo "  Is the container connected? Check: ./tailsscale.sh status"
        return
    fi

    # Track routes we add
    : > "$ROUTES_FILE"

    local count=0
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        if sudo route add -host "$ip" "$TUN_GW" 2>/dev/null; then
            echo -e "  ${GREEN}+ route $ip → tun2proxy${NC}"
        else
            echo -e "  ${YELLOW}~ $ip (already exists)${NC}"
        fi
        echo "$ip" >> "$ROUTES_FILE"
        ((count++))
    done <<< "$peer_ips"

    echo -e "${GREEN}Routed $count personal Tailscale peer(s).${NC}"
}

remove_routes() {
    [ ! -f "$ROUTES_FILE" ] && return

    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        sudo route delete -host "$ip" 2>/dev/null && \
            echo -e "  ${RED}- $ip${NC}" || true
    done < "$ROUTES_FILE"
    rm -f "$ROUTES_FILE"
}

wait_for_tailscale() {
    local max_wait=15
    for i in $(seq 1 $max_wait); do
        if docker exec "$CONTAINER_NAME" tailscale status &>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

cmd_up() {
    require_tun2proxy

    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  Starting Personal Tailscale VPN           ${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""

    # 1. Start Docker container
    echo -e "${YELLOW}[1/4] Starting Docker container...${NC}"
    cd "$SCRIPT_DIR"
    docker compose up -d

    echo "  Waiting for Tailscale daemon..."
    if ! wait_for_tailscale; then
        echo -e "${RED}Container failed to start. Check: docker logs $CONTAINER_NAME${NC}"
        exit 1
    fi

    # 2. Check authentication
    echo -e "${YELLOW}[2/4] Checking authentication...${NC}"
    STATUS=$(docker exec "$CONTAINER_NAME" tailscale status 2>&1 || true)

    if echo "$STATUS" | grep -q "NeedsLogin\|Logged out\|not logged in"; then
        echo "  Authentication required — generating login URL..."
        docker exec "$CONTAINER_NAME" tailscale up 2>&1 &
        UP_PID=$!

        URL=""
        for i in $(seq 1 30); do
            URL=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -o 'https://login.tailscale.com/[^ ]*' | tail -1)
            if [ -n "$URL" ]; then
                echo ""
                echo -e "  ${GREEN}Open this URL to authenticate:${NC}"
                echo "  $URL"
                echo ""
                echo "  Waiting for authentication..."
                wait $UP_PID 2>/dev/null || true
                echo -e "  ${GREEN}Authenticated!${NC}"
                break
            fi
            sleep 1
        done

        if [ -z "$URL" ]; then
            echo -e "${RED}Could not get login URL. Run manually:${NC}"
            echo "  docker exec $CONTAINER_NAME tailscale up"
            exit 1
        fi
    else
        echo -e "  ${GREEN}Already authenticated.${NC}"
    fi

    # 3. Start tun2proxy (if not already running)
    if is_tun2proxy_running; then
        echo -e "${YELLOW}[3/4] tun2proxy already running — refreshing routes...${NC}"
        cmd_refresh
        echo ""
        echo -e "${GREEN}✅ Personal Tailscale VPN is running!${NC}"
        return
    fi

    echo -e "${YELLOW}[3/4] Starting tun2proxy...${NC}"

    # Capture existing utun devices before starting tun2proxy
    UTUN_BEFORE=$(ifconfig -l | tr ' ' '\n' | grep utun | sort)

    # Start tun2proxy in background (no --setup: we manage routes ourselves)
    sudo tun2proxy-bin --proxy "socks5://127.0.0.1:${SOCKS5_PORT}" \
        &>/tmp/tun2proxy-personal.log &
    TUN_PID=$!
    echo "$TUN_PID" | sudo tee "$PID_FILE" >/dev/null
    sleep 2

    if ! kill -0 "$TUN_PID" 2>/dev/null; then
        echo -e "${RED}tun2proxy failed to start. Log:${NC}"
        cat /tmp/tun2proxy-personal.log 2>/dev/null
        sudo rm -f "$PID_FILE"
        exit 1
    fi

    # Find the newly created utun device
    UTUN_AFTER=$(ifconfig -l | tr ' ' '\n' | grep utun | sort)
    TUN_IF=$(comm -13 <(echo "$UTUN_BEFORE") <(echo "$UTUN_AFTER") | head -1)

    if [ -z "$TUN_IF" ]; then
        echo -e "${RED}Could not detect new TUN interface.${NC}"
        sudo kill "$TUN_PID" 2>/dev/null || true
        sudo rm -f "$PID_FILE"
        exit 1
    fi

    echo "$TUN_IF" | sudo tee "$TUN_IF_FILE" >/dev/null
    echo -e "  ${GREEN}Created interface: $TUN_IF${NC}"

    # Configure TUN interface as point-to-point link
    sudo ifconfig "$TUN_IF" "$TUN_LOCAL" "$TUN_GW" up
    echo -e "  ${GREEN}Configured: $TUN_LOCAL ↔ $TUN_GW${NC}"

    # 4. Add routes for personal Tailscale peers
    echo -e "${YELLOW}[4/4] Adding routes for personal Tailscale peers...${NC}"
    add_routes

    SELF_IP=$(get_self_ip)
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  ✅ Personal Tailscale VPN is running!     ${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "  This node:      ${BLUE}${SELF_IP:-unknown}${NC}"
    echo -e "  TUN interface:  ${BLUE}$TUN_IF${NC}"
    echo -e "  SOCKS5 proxy:   ${BLUE}socks5://localhost:$SOCKS5_PORT${NC} (also available)"
    echo ""
    echo "  Personal Tailscale IPs are now directly accessible — no proxy needed."
    echo ""
    echo "  Commands:"
    echo "    ./tailsscale.sh status   — show connection status"
    echo "    ./tailsscale.sh refresh  — re-sync peer routes"
    echo "    ./tailsscale.sh down     — disconnect everything"
}

cmd_down() {
    echo -e "${BLUE}Stopping Personal Tailscale VPN...${NC}"
    echo ""

    # 1. Remove routes
    if [ -f "$ROUTES_FILE" ]; then
        echo "Removing routes..."
        remove_routes
    fi

    # 2. Stop tun2proxy
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "Stopping tun2proxy (PID $pid)..."
            sudo kill "$pid" 2>/dev/null || true
            sleep 1
        fi
        sudo rm -f "$PID_FILE"
    fi
    sudo rm -f "$TUN_IF_FILE"

    # 3. Stop Docker container
    echo "Stopping Docker container..."
    cd "$SCRIPT_DIR"
    docker compose down

    echo ""
    echo -e "${GREEN}✅ Personal Tailscale VPN stopped.${NC}"
}

cmd_status() {
    echo -e "${BLUE}Personal Tailscale VPN Status${NC}"
    echo "──────────────────────────────────"

    # Docker container
    if is_container_running; then
        echo -e "  Container:   ${GREEN}running${NC}"
    else
        echo -e "  Container:   ${RED}stopped${NC}"
        echo ""
        echo "Run './tailsscale.sh up' to start."
        return
    fi

    # Tailscale auth
    local ts_status
    ts_status=$(docker exec "$CONTAINER_NAME" tailscale status 2>&1 || echo "")
    if echo "$ts_status" | grep -q "NeedsLogin\|Logged out\|not logged in"; then
        echo -e "  Tailscale:   ${RED}not authenticated${NC}"
    else
        echo -e "  Tailscale:   ${GREEN}connected${NC}"
    fi

    # Self IP
    local self_ip
    self_ip=$(get_self_ip)
    if [ -n "$self_ip" ]; then
        echo -e "  Personal IP: ${GREEN}$self_ip${NC}"
    fi

    # tun2proxy
    if is_tun2proxy_running; then
        echo -e "  tun2proxy:   ${GREEN}running${NC} (PID $(cat "$PID_FILE"))"
    else
        echo -e "  tun2proxy:   ${RED}stopped${NC}"
    fi

    # TUN interface
    local tun_if
    tun_if=$(get_tun_interface)
    if [ -n "$tun_if" ]; then
        echo -e "  Interface:   ${GREEN}$tun_if${NC}"
    else
        echo -e "  Interface:   ${RED}none${NC}"
    fi

    # Routes
    if [ -f "$ROUTES_FILE" ] && [ -s "$ROUTES_FILE" ]; then
        local count
        count=$(wc -l < "$ROUTES_FILE" | tr -d ' ')
        echo -e "  Routes:      ${GREEN}$count peer(s)${NC}"
    else
        echo -e "  Routes:      ${YELLOW}none${NC}"
    fi

    # Peer list
    echo ""
    echo -e "${BLUE}Peers:${NC}"
    docker exec "$CONTAINER_NAME" tailscale status 2>/dev/null | head -20 || \
        echo "  (unavailable)"
}

cmd_refresh() {
    if ! is_container_running; then
        echo -e "${RED}Container not running. Run './tailsscale.sh up' first.${NC}"
        exit 1
    fi

    local tun_if
    tun_if=$(get_tun_interface)
    if [ -z "$tun_if" ]; then
        echo -e "${RED}TUN interface not found. Run './tailsscale.sh up' first.${NC}"
        exit 1
    fi

    echo -e "${BLUE}Refreshing routes...${NC}"

    # Remove old routes
    remove_routes

    # Add current routes
    add_routes

    echo -e "${GREEN}✅ Routes refreshed.${NC}"
}

cmd_setup_alias() {
    local ZSHRC="$HOME/.zshrc"
    local ALIAS_MARKER="# tailsscale alias"
    local SCRIPT_ABS_PATH="$SCRIPT_DIR/tailsscale.sh"

    # Remove old alias if exists
    if grep -q "$ALIAS_MARKER" "$ZSHRC" 2>/dev/null; then
        sed -i '' "/$ALIAS_MARKER/,/# end tailsscale alias/d" "$ZSHRC"
        echo -e "${YELLOW}Updating existing alias...${NC}"
    fi

    cat >> "$ZSHRC" <<EOF

$ALIAS_MARKER
alias tailsscale='$SCRIPT_ABS_PATH'
# end tailsscale alias
EOF

    echo -e "${GREEN}✅ Alias installed!${NC}"
    echo ""
    echo "You can now use:"
    echo "  tailsscale up"
    echo "  tailsscale down"
    echo "  tailsscale status"
    echo "  tailsscale refresh"

    source "$ZSHRC"
}

cmd_uninstall() {
    local ZSHRC="$HOME/.zshrc"
    local ALIAS_MARKER="# tailsscale alias"

    # Remove alias from zshrc
    if grep -q "$ALIAS_MARKER" "$ZSHRC" 2>/dev/null; then
        sed -i '' "/$ALIAS_MARKER/,/# end tailsscale alias/d" "$ZSHRC"
        # Remove trailing blank lines left behind
        sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$ZSHRC"
        echo -e "${GREEN}✅ Alias removed from ~/.zshrc${NC}"
        source "$ZSHRC"
    else
        echo -e "${YELLOW}No alias found in ~/.zshrc${NC}"
    fi

    # Stop everything if running
    if is_container_running || is_tun2proxy_running; then
        echo ""
        cmd_down
    fi

    # Clean up temp files
    sudo rm -f "$PID_FILE" "$TUN_IF_FILE" "$ROUTES_FILE" 2>/dev/null

    echo ""
    echo -e "${GREEN}✅ Uninstalled. You can safely delete this directory.${NC}"
}

# ── Main ──────────────────────────────────────────────────────────

case "${1:-help}" in
    up|start)        cmd_up ;;
    down|stop)       cmd_down ;;
    status|st)       cmd_status ;;
    refresh|re)      cmd_refresh ;;
    setup-alias)     cmd_setup_alias ;;
    uninstall)       cmd_uninstall ;;
    *)
        echo "Personal Tailscale VPN — transparent dual-account routing"
        echo ""
        echo "Usage: $0 {up|down|status|refresh|setup-alias|uninstall}"
        echo ""
        echo "Commands:"
        echo "  up            Start personal Tailscale with transparent IP routing"
        echo "  down          Stop everything and clean up routes"
        echo "  status        Show connection status and peers"
        echo "  refresh       Re-sync peer routes (run when peers change)"
        echo "  setup-alias   Install 'tailsscale' as a global command"
        echo "  uninstall     Remove alias, stop services, clean up"
        echo ""
        echo "Prerequisites:"
        echo "  - Docker Desktop running"
        echo "  - tun2proxy installed (brew install tun2proxy)"
        exit 1
        ;;
esac
