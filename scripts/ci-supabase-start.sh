#!/usr/bin/env bash
# Start the local Supabase stack in CI.
#
# Twice (cd4981b, ed69099) « supabase start » failed on a fresh runner with
# « failed to bind host port 0.0.0.0:54322/tcp: address already in use »,
# before any test. The stack's ports (54321-54324, 54327, 54329) lie inside
# Linux's ephemeral port range (32768-60999), so an outbound connection made
# while the images are pulled can hold one of them as its source port when the
# database container binds it. Reserving the ports keeps the kernel from
# handing them out; if the start still fails, the listeners are logged (the
# evidence for the next look) and the start is tried once more.
set -euo pipefail

ports="54320-54329"
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

reserved="$(cat /proc/sys/net/ipv4/ip_local_reserved_ports 2>/dev/null || true)"
as_root sysctl -q -w "net.ipv4.ip_local_reserved_ports=${reserved:+$reserved,}$ports" || true
echo "reserved ports: $(cat /proc/sys/net/ipv4/ip_local_reserved_ports 2>/dev/null || echo '?')"

log_ports() {
  echo "::group::sockets on $ports ($1)"
  if command -v ss >/dev/null; then
    as_root ss -tanp | awk 'NR == 1 || $4 ~ /:5432[0-9]$/ || $5 ~ /:5432[0-9]$/' || true
  elif command -v lsof >/dev/null; then
    as_root lsof -nP -iTCP:54320-54329 || true
  fi
  docker ps -a --format '{{.Names}} {{.Status}} {{.Ports}}' || true
  echo "::endgroup::"
}

if supabase start; then
  exit 0
fi
log_ports "after the failed start"
supabase stop --no-backup || true
sleep 5
log_ports "before the second start"
supabase start
