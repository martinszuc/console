#!/usr/bin/env bash
# Script to reproduce OCPBUGS-44235 by running bridge with unwritable HOME
# This simulates the console pod environment where HOME=/ (read-only)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=============================================${NC}"
echo -e "${YELLOW}OCPBUGS-44235 Bug Reproduction Environment${NC}"
echo -e "${YELLOW}Running Bridge with Read-Only HOME${NC}"
echo -e "${YELLOW}=============================================${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"
if ! command -v oc &> /dev/null; then
    echo -e "${RED}ERROR: 'oc' command not found${NC}"
    echo "Please install OpenShift CLI: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html"
    exit 1
fi

if ! oc whoami &> /dev/null; then
    echo -e "${RED}ERROR: Not logged into OpenShift cluster${NC}"
    echo "Please login first: oc login <cluster-url>"
    exit 1
fi

echo -e "${GREEN}✓ Logged into OpenShift as: $(oc whoami)${NC}"
echo -e "${GREEN}✓ Cluster: $(oc whoami --show-server)${NC}"
echo ""

# Create a temporary read-only directory to simulate pod's HOME=/
FAKE_HOME=$(mktemp -d -t console-readonly-home)
echo -e "${GREEN}Created temporary HOME: ${FAKE_HOME}${NC}"
echo "Making it read-only (simulating pod's HOME=/ environment)..."
chmod 555 "$FAKE_HOME"
ls -ld "$FAKE_HOME"
echo ""

# Verify it's unwritable
echo "Verifying HOME is unwritable..."
if ! mkdir -p "$FAKE_HOME/.cache/test" 2>/dev/null; then
    echo -e "${GREEN}✓ HOME is read-only (as expected in pod)${NC}"
else
    echo -e "${RED}✗ Warning: HOME is writable (cleanup test dir)${NC}"
    rmdir "$FAKE_HOME/.cache/test" "$FAKE_HOME/.cache" 2>/dev/null || true
fi
echo ""

# Setup cleanup trap
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    chmod 755 "$FAKE_HOME" 2>/dev/null || true
    rm -rf "$FAKE_HOME" 2>/dev/null || true
    echo -e "${GREEN}Cleanup complete${NC}"
}
trap cleanup EXIT INT TERM

echo -e "${YELLOW}Collecting cluster information (before changing HOME)...${NC}"
# Get cluster info BEFORE changing HOME (so oc can find kubeconfig)
REAL_HOME="$HOME"
REAL_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
K8S_ENDPOINT="$(oc whoami --show-server)"
ALERTMANAGER_URL="$(oc -n openshift-config-managed get configmap monitoring-shared-config -o jsonpath='{.data.alertmanagerPublicURL}' 2>/dev/null || echo '')"
THANOS_URL="$(oc -n openshift-config-managed get configmap monitoring-shared-config -o jsonpath='{.data.thanosPublicURL}' 2>/dev/null || echo '')"
echo "  Cluster: $K8S_ENDPOINT"

# Auto-setup cluster credentials if needed
echo -e "${YELLOW}Checking cluster credentials...${NC}"
if [ ! -f examples/token ] || [ ! -s examples/token ]; then
    echo "  Updating token..."
    oc whoami -t > examples/token
fi

if [ ! -f examples/ca.crt ] || [ ! -s examples/ca.crt ] || grep -q "Placeholder" examples/ca.crt 2>/dev/null; then
    echo "  Updating cluster CA certificate..."
    K8S_HOST=$(echo "$K8S_ENDPOINT" | sed 's|https://||;s|:443||')
    echo | openssl s_client -connect "$K8S_HOST:443" -showcerts 2>/dev/null | openssl x509 -outform PEM > examples/ca.crt
fi

if [ ! -f examples/console-client-secret ] || [ ! -s examples/console-client-secret ]; then
    echo "  Creating OAuth client..."
    oc get oauthclient console-oauth-client >/dev/null 2>&1 || oc process -f examples/console-oauth-client.yaml | oc apply -f -
    oc get oauthclient console-oauth-client -o jsonpath='{.secret}' > examples/console-client-secret
fi

echo -e "${GREEN}✓ Cluster credentials ready${NC}"
echo ""

echo -e "${YELLOW}Starting bridge with read-only HOME...${NC}"
echo "When you try to install a Helm chart with CA certificates configured,"
echo "it will fail with: 'no such file or directory' (this is the bug)"
echo ""
echo -e "${GREEN}Console will be available at: http://localhost:9000${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop the bridge${NC}"
echo ""

# Export HOME for the bridge process (but keep KUBECONFIG pointing to real location)
export HOME="$FAKE_HOME"
export KUBECONFIG="$REAL_KUBECONFIG"
# IMPORTANT: Do NOT set HELM_CACHE_HOME or HELM_CONFIG_HOME to reproduce the bug!
# The ClusterBot console pod doesn't have these set, so Helm uses $HOME/.cache
# export HELM_CACHE_HOME="/tmp/helm-cache"  # COMMENTED OUT TO REPRODUCE BUG
# export HELM_CONFIG_HOME="/tmp/helm-config"  # COMMENTED OUT TO REPRODUCE BUG

echo "Environment for bridge:"
echo "  HOME=$HOME (read-only)"
echo "  KUBECONFIG=$KUBECONFIG (from real home)"
echo "  HELM_CACHE_HOME=(not set - Helm will use \$HOME/.cache - THIS IS THE BUG!)"
echo ""

# Run bridge using the same configuration as examples/run-bridge.sh
exec ./bin/bridge \
    --base-address=http://localhost:9000 \
    --ca-file=examples/ca.crt \
    --k8s-mode=off-cluster \
    --k8s-mode-off-cluster-endpoint="$K8S_ENDPOINT" \
    --k8s-mode-off-cluster-skip-verify-tls=true \
    --listen=http://127.0.0.1:9000 \
    --public-dir=./frontend/public/dist \
    --user-auth=openshift \
    --user-auth-oidc-client-id=console-oauth-client \
    --user-auth-oidc-client-secret-file=examples/console-client-secret \
    --user-auth-oidc-ca-file=examples/ca.crt \
    --k8s-mode-off-cluster-service-account-bearer-token-file=examples/token \
    --k8s-mode-off-cluster-alertmanager="$ALERTMANAGER_URL" \
    --k8s-mode-off-cluster-thanos="$THANOS_URL" \
    "$@"

