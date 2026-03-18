#!/usr/bin/env bash
# Integration test: validates node-probe DaemonSet detects Ollama on the host.
#
# What it does:
#   1. Waits for node-probe to annotate the node with inference-healthy=true
#   2. Validates port annotation (sympozium.ai/inference-ollama=11434)
#   3. Validates proxy port annotation (sympozium.ai/inference-proxy-port=9473)
#   4. Tests the proxy endpoint via port-forward
#
# Prerequisites:
#   - Kind cluster running with Sympozium installed
#   - node-probe DaemonSet deployed (kubectl apply -f config/node-probe/node-probe.yaml)
#   - Ollama running on host at 127.0.0.1:11434
#
# Usage:
#   ./test/integration/test-ollama-local.sh

set -euo pipefail

NAMESPACE="${TEST_NAMESPACE:-sympozium-system}"
TIMEOUT="${TEST_TIMEOUT:-90}"
LOCAL_PROXY_PORT=19473

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $*${NC}"; }
fail() { echo -e "${RED}✗ $*${NC}"; exit 1; }
info() { echo -e "${YELLOW}● $*${NC}"; }

# Clean up background processes on exit.
PF_PID=""
cleanup() {
    if [[ -n "$PF_PID" ]]; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Pre-flight checks ---
info "Running integration test: node-probe Ollama detection"

if ! command -v kubectl >/dev/null 2>&1; then
    fail "Required command not found: kubectl"
fi

if ! command -v jq >/dev/null 2>&1; then
    fail "Required command not found: jq"
fi

if ! kubectl get crd agentruns.sympozium.ai >/dev/null 2>&1; then
    fail "Sympozium CRDs not installed. Is the cluster set up?"
fi

if ! kubectl get daemonset sympozium-node-probe -n "$NAMESPACE" >/dev/null 2>&1; then
    fail "node-probe DaemonSet not found. Deploy it first: kubectl apply -f config/node-probe/node-probe.yaml"
fi

# --- Step 1: Verify DaemonSet is healthy ---
info "Checking node-probe DaemonSet health..."

DS_STATUS=$(kubectl get daemonset sympozium-node-probe -n "$NAMESPACE" -o json 2>/dev/null) || {
    fail "DaemonSet sympozium-node-probe not found in namespace $NAMESPACE"
}

DESIRED=$(echo "$DS_STATUS" | jq '.status.desiredNumberScheduled')
READY=$(echo "$DS_STATUS" | jq '.status.numberReady')

if [[ "$DESIRED" -eq 0 ]]; then
    fail "DaemonSet has 0 desired pods"
fi

if [[ "$READY" -ne "$DESIRED" ]]; then
    fail "DaemonSet not fully ready: $READY/$DESIRED pods"
fi

pass "DaemonSet is healthy ($READY/$DESIRED pods ready)"

# --- Step 2: Wait for node-probe to detect Ollama ---
info "Waiting for node-probe to annotate the node..."

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || {
    fail "Could not get node name"
}

PROBE_WAIT=0
HEALTHY=""
while [[ $PROBE_WAIT -lt $TIMEOUT ]]; do
    HEALTHY=$(kubectl get node "$NODE_NAME" \
        -o jsonpath='{.metadata.annotations.sympozium\.ai/inference-healthy}' 2>/dev/null) || true
    if [[ "$HEALTHY" == "true" ]]; then
        break
    fi
    sleep 2
    PROBE_WAIT=$((PROBE_WAIT + 2))

    if (( PROBE_WAIT % 15 == 0 )); then
        info "  ...${PROBE_WAIT}s elapsed (no inference-healthy annotation yet)"
    fi
done

if [[ "$HEALTHY" != "true" ]]; then
    info "Current annotations:"
    kubectl get node "$NODE_NAME" -o json | jq '.metadata.annotations | with_entries(select(.key | startswith("sympozium.ai")))' 2>/dev/null || true
    info "Node-probe logs:"
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/component=node-probe --tail=30 2>/dev/null || true
    fail "node-probe did not annotate node with inference-healthy within ${TIMEOUT}s"
fi

pass "node-probe annotated node $NODE_NAME with inference-healthy=true after ${PROBE_WAIT}s"

# --- Step 3: Validate annotations ---
ANNOTATIONS=$(kubectl get node "$NODE_NAME" -o json | \
    jq '.metadata.annotations | with_entries(select(.key | startswith("sympozium.ai")))')

OLLAMA_PORT=$(echo "$ANNOTATIONS" | jq -r '.["sympozium.ai/inference-ollama"] // ""')
PROXY_PORT=$(echo "$ANNOTATIONS" | jq -r '.["sympozium.ai/inference-proxy-port"] // ""')

if [[ -z "$OLLAMA_PORT" ]]; then
    fail "No Ollama port annotation found"
else
    pass "Ollama port annotation: $OLLAMA_PORT"
fi

if [[ -z "$PROXY_PORT" ]]; then
    fail "No proxy port annotation found"
else
    pass "Proxy port annotation: $PROXY_PORT"
fi

OLLAMA_MODELS=$(echo "$ANNOTATIONS" | jq -r '.["sympozium.ai/inference-models-ollama"] // ""')
if [[ -n "$OLLAMA_MODELS" ]]; then
    pass "Ollama models detected: $OLLAMA_MODELS"
else
    info "No model annotations (Ollama might have no models loaded - OK)"
fi

# --- Step 4: Test proxy via port-forward ---
info "Testing node-probe reverse proxy..."

POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=node-probe -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || {
    fail "Could not get node-probe pod"
}

kubectl port-forward -n "$NAMESPACE" "pod/$POD_NAME" "${LOCAL_PROXY_PORT}:9473" &
PF_PID=$!
sleep 2

PROXY_URL="http://127.0.0.1:${LOCAL_PROXY_PORT}/proxy/ollama/api/tags"
RESPONSE=$(curl -s --connect-timeout 5 -w "\n%{http_code}" "$PROXY_URL" 2>/dev/null || echo -e "\n000")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

kill "$PF_PID" 2>/dev/null || true
wait "$PF_PID" 2>/dev/null || true
PF_PID=""

if [[ "$HTTP_CODE" != "200" ]]; then
    fail "Proxy returned HTTP $HTTP_CODE (expected 200)"
else
    pass "Proxy endpoint returned 200"
fi

if echo "$BODY" | jq -e '.models' >/dev/null 2>&1; then
    pass "Proxy returned expected response format (models array present)"
else
    fail "Proxy response missing models array"
fi

# --- Summary ---
echo ""
echo "=============================="
echo " Node-probe Validation"
echo "=============================="
echo " DaemonSet: ready ($READY/$DESIRED)"
echo " Node:      $NODE_NAME"
echo " Provider:  ollama"
echo " Port:      ${OLLAMA_PORT}"
echo " Proxy:     ${PROXY_PORT}"
[[ -n "$OLLAMA_MODELS" ]] && echo " Models:    $OLLAMA_MODELS" || echo " Models:    (none loaded)"
echo "=============================="

pass "node-probe is working correctly with Ollama"
