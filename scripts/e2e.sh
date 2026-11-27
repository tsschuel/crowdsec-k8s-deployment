#!/usr/bin/env bash
# End-to-end test on kind: deploys the chart in detect mode, checks that attacks are logged but allowed,
# upgrades to block mode, checks that attacks and a custom rule are blocked, and that WebSocket upgrades work.
#
# Env: CLUSTER (kind cluster name), NS, REL, IMG_TRAEFIK, IMG_CROWDSEC, CROWDSEC_VERSION, TAG, KEEP=1 to keep the cluster.
set -euo pipefail

CLUSTER=${CLUSTER:-crowdsec-waf-e2e}
NS=${NS:-waf-e2e}
REL=${REL:-waf}
TAG=${TAG:-e2e}
IMG_TRAEFIK=${IMG_TRAEFIK:-local/crowdsec-waf-traefik}
IMG_CROWDSEC=${IMG_CROWDSEC:-local/crowdsec-waf-crowdsec}
LOCAL_PORT=${LOCAL_PORT:-18443}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
PF_PID=""

for bin in kind kubectl helm docker curl openssl; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 2; }
done

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
nok()  { echo "  FAIL  $1"; fail=$((fail+1)); }
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 (got $3)"; else nok "$1 (expected $2, got $3)"; fi
}

cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  if [ "${KEEP:-0}" != "1" ]; then kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

k() { kubectl --context "kind-$CLUSTER" -n "$NS" "$@"; }
status() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }
ws_status() { # first status line of a WebSocket upgrade handshake
  curl -sk -i --max-time 4 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "https://localhost:$LOCAL_PORT/.ws" 2>/dev/null | head -1 | tr -d '\r' || true
}
find_deploy() { k get deploy -o name | grep -- "$1" | head -1 | sed 's|.*/||'; }

echo "== cluster"
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config "$ROOT/test/e2e/kind-config.yaml" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "== load images"
CS_VERSION=${CROWDSEC_VERSION:?CROWDSEC_VERSION must be set (see versions.env)}
kind load docker-image --name "$CLUSTER" "$IMG_TRAEFIK:$TAG" "$IMG_CROWDSEC:$TAG" "$IMG_CROWDSEC:$CS_VERSION"

echo "== prerequisites"
kubectl --context "kind-$CLUSTER" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "kind-$CLUSTER" apply -f - >/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
  -keyout "$WORK/tls.key" -out "$WORK/tls.crt" 2>/dev/null
k create secret tls waf-frontend-tls --cert="$WORK/tls.crt" --key="$WORK/tls.key" --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -f "$ROOT/test/e2e/backend.yaml" >/dev/null
k rollout status deploy/echo --timeout=180s

deploy() { # deploy <mode>
  helm --kube-context "kind-$CLUSTER" upgrade --install "$REL" "$ROOT/charts/crowdsec-waf" -n "$NS" \
    -f "$ROOT/test/e2e/values.yaml" \
    --set image.repository="$IMG_TRAEFIK" --set image.tag="$TAG" --set image.pullPolicy=Never \
    --set crowdsec.image.repository="$IMG_CROWDSEC" --set crowdsec.image.tag="$CS_VERSION" \
    --set crowdsec.image.pullPolicy=Never \
    --set waf.mode="$1" --wait --timeout 8m
  k rollout restart "deploy/$(find_deploy appsec)" >/dev/null
  k rollout status "deploy/$(find_deploy appsec)" --timeout=300s
  k rollout status "deploy/$(find_deploy proxy)" --timeout=300s
}

portforward() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  k port-forward "svc/$(k get svc -o name | grep -- 'proxy$' | sed 's|.*/||')" "$LOCAL_PORT:443" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 30); do
    [ "$(status "https://localhost:$LOCAL_PORT/")" != "000" ] && return 0
    sleep 1
  done
  echo "port-forward did not become ready" >&2; return 1
}

URL="https://localhost:$LOCAL_PORT"
SQLI="$URL/?id=1%27%20OR%20%271%27=%271"
TRAVERSAL="$URL/../../etc/passwd"

echo "== deploy (detect mode)"
deploy detect
portforward

echo "== detect mode: nothing is blocked, matches are alerted"
check "clean request"           200 "$(status "$URL/")"
check "SQL injection allowed"   200 "$(status "$SQLI")"
check "path traversal allowed"  200 "$(status --path-as-is "$TRAVERSAL")"
check "custom rule /debug allowed" 200 "$(status "$URL/debug")"
alerts=""
for _ in $(seq 1 20); do
  alerts=$(k exec "deploy/$(find_deploy lapi)" -- cscli alerts list -o json 2>/dev/null || true)
  [ -n "$alerts" ] && [ "$alerts" != "null" ] && [ "$alerts" != "[]" ] && break
  sleep 3
done
if [ -n "$alerts" ] && [ "$alerts" != "null" ] && [ "$alerts" != "[]" ]; then ok "alerts recorded in LAPI"; else nok "no alerts recorded in LAPI"; fi
ws=$(ws_status); case "$ws" in *101*) ok "WebSocket upgrade ($ws)";; *) nok "WebSocket upgrade (got '$ws')";; esac

echo "== upgrade to block mode"
deploy block
portforward

echo "== block mode: attacks are blocked"
check "clean request"             200 "$(status "$URL/")"
check "SQL injection blocked"     403 "$(status "$SQLI")"
check "path traversal blocked"    403 "$(status --path-as-is "$TRAVERSAL")"
check "custom rule /debug blocked" 403 "$(status "$URL/debug")"
ws=$(ws_status); case "$ws" in *101*) ok "WebSocket upgrade ($ws)";; *) nok "WebSocket upgrade (got '$ws')";; esac

echo
echo "passed: $pass  failed: $fail"
if [ "$fail" -gt 0 ]; then
  echo "--- proxy logs"; k logs "deploy/$(find_deploy proxy)" --tail=40 || true
  echo "--- appsec logs"; k logs "deploy/$(find_deploy appsec)" --tail=60 || true
  exit 1
fi
