#!/usr/bin/env bash
set -euo pipefail

# roku-play.sh
# Usage:
#   ./roku-play.sh <media_url> [v|a]

MEDIA_URL="${1:-}"
MEDIA_TYPE="${2:-v}"      # v=video, a=audio
CHANNEL_ID="782875"

if [[ -z "$MEDIA_URL" ]]; then
  echo "Usage: $0 <media_url> [v|a]" >&2
  exit 2
fi

if [[ "$MEDIA_TYPE" != "v" && "$MEDIA_TYPE" != "a" ]]; then
  echo "Media type must be v or a" >&2
  exit 2
fi

ENC_URL="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$MEDIA_URL")"

# SSDP M-SEARCH packet (Roku responds to both roku:ecp and upnp:rootdevice)
SSDP_QUERY=$'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 1\r\nST: roku:ecp\r\n\r\n'

echo "Discovering Roku devices (SSDP)…"

# Send multicast + collect responses (python keeps this clean & fast)
mapfile -t ROKUS < <(python3 - <<'PY'
import socket, re, time

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.settimeout(1)
sock.sendto(b"""M-SEARCH * HTTP/1.1\r
HOST: 239.255.255.250:1900\r
MAN: "ssdp:discover"\r
MX: 1\r
ST: roku:ecp\r
\r
""", ("239.255.255.250", 1900))

found = {}
end = time.time() + 1.0

while time.time() < end:
    try:
        data, addr = sock.recvfrom(4096)
    except socket.timeout:
        break
    ip = addr[0]
    if ip not in found:
        found[ip] = True
        print(ip)
PY
)

if [[ "${#ROKUS[@]}" -eq 0 ]]; then
  echo "No Roku devices found." >&2
  exit 1
fi

# Query friendly names
NAMES=()
for ip in "${ROKUS[@]}"; do
  xml="$(curl -fsS --max-time 1 "http://${ip}:8060/query/device-info" 2>/dev/null || true)"
  name="$(echo "$xml" | sed -n 's:.*<friendly-device-name>\(.*\)</friendly-device-name>.*:\1:p')"
  model="$(echo "$xml" | sed -n 's:.*<model-name>\(.*\)</model-name>.*:\1:p')"
  if [[ -n "$name" && -n "$model" ]]; then
    NAMES+=("$name ($model)")
  else
    NAMES+=("Roku @ $ip")
  fi
done

echo ""
echo "Found Roku devices:"
for i in "${!ROKUS[@]}"; do
  printf "  [%d] %-15s  %s\n" "$((i+1))" "${ROKUS[$i]}" "${NAMES[$i]}"
done

echo ""
read -rp "Pick a device: " sel
sel=$((sel-1))

if (( sel < 0 || sel >= ${#ROKUS[@]} )); then
  echo "Invalid selection" >&2
  exit 2
fi

ROKU_IP="${ROKUS[$sel]}"
ECP_URL="http://${ROKU_IP}:8060/launch/${CHANNEL_ID}?u=${ENC_URL}&t=${MEDIA_TYPE}"

echo "Launching on ${NAMES[$sel]} (${ROKU_IP})"
curl -fsS --data '' "$ECP_URL" >/dev/null
echo "Done."

