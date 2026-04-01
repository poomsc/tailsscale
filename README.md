# Tailsscale (The Tails of Tailscale)

Run two Tailscale accounts simultaneously on macOS — work (native) and personal (Docker) — with transparent IP routing.

## How it works

- Work Tailscale runs natively on macOS (Headscale)
- Personal Tailscale runs in Docker with a SOCKS5 proxy
- `tun2proxy` creates a TUN interface connected to that proxy
- Per-peer `/32` routes override work Tailscale's `/10` route, so macOS automatically sends traffic to the right network

## Prerequisites

```bash
brew install tun2proxy
```

Docker Desktop must be running.

## Setup

```bash
# Install global alias (one-time)
./tailsscale.sh setup-alias
```

## Usage

```bash
# Start (first run will prompt for Tailscale login)
tailsscale up

# Access personal devices directly — no proxy needed
ssh pi@100.120.114.68
curl http://100.115.142.80:8080

# Check status
tailsscale status

# Re-sync routes when peers change
tailsscale refresh

# Stop
tailsscale down
```

## Files

| File | Purpose |
|---|---|
| `tailsscale.sh` | Main script — manages container, tun2proxy, and routes |
| `docker-compose.yml` | Personal Tailscale container with SOCKS5 proxy on port 1055 |
