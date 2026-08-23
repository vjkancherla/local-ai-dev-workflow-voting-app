#!/usr/bin/env bash
set -euo pipefail

# Create the k3d cluster (if missing), build + load images, and apply the
# kustomize manifests.
#
# Local access notes:
#   - vote.127.0.0.1.nip.io and result.127.0.0.1.nip.io are routed by nginx
#     ingress through the k3d loadbalancer on host ports 8081 (HTTP) and 8082 (HTTPS).
#     Add to /etc/hosts:
#       127.0.0.1 vote.127.0.0.1.nip.io result.127.0.0.1.nip.io
#   - Then open https://vote.127.0.0.1.nip.io:8082/ and
#     https://result.127.0.0.1.nip.io:8082/
#
# Registry mode (REGISTRY=1): create the cluster with --registry-create and
# apply kustomize/overlays/registry, which points image refs at the
# cluster-internal registry hostname (default port 5000; edit the overlay to
# 5001 if AirPlay Receiver claims port 5000). Uses scripts/build.sh, which must
# also run with REGISTRY=1 (this script passes it).

CLUSTER="${CLUSTER:-voting-app}"
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-./kustomize}"
REGISTRY="${REGISTRY:-0}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"

# 1. Create the cluster if it does not already exist.
if ! k3d cluster list 2>/dev/null | grep -qE "^${CLUSTER}[[:space:]]"; then
  args=(cluster create "$CLUSTER" -p "8081:80@loadbalancer" -p "8082:443@loadbalancer" --agents 1)
  if [[ "$REGISTRY" == "1" ]]; then
    args+=(--registry-create "voting-app-registry.localhost:${REGISTRY_PORT}")
  fi
  k3d "${args[@]}"
fi

# 2. Build and load the application images.
REGISTRY="$REGISTRY" REGISTRY_PORT="$REGISTRY_PORT" CLUSTER="$CLUSTER" ./scripts/build.sh

# 3. Generate the gitignored credentials/secret env file once (persisted across
#    applies so Postgres credentials and the Flask SECRET_KEY stay stable).
if [[ ! -f "${KUSTOMIZE_DIR}/postgres-secret.env" ]]; then
  {
    echo "POSTGRES_USER=postgres"
    echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)"
    echo "SECRET_KEY=$(openssl rand -hex 16)"
  } > "${KUSTOMIZE_DIR}/postgres-secret.env"
  echo "Generated ${KUSTOMIZE_DIR}/postgres-secret.env (persisted; do not commit)."
fi

# 4. Apply the manifests.
if [[ "$REGISTRY" == "1" ]]; then
  kubectl apply -k "${KUSTOMIZE_DIR}/overlays/registry"
else
  kubectl apply -k "${KUSTOMIZE_DIR}"
fi

# 5. Wait for all workloads to become ready.
kubectl rollout status deployment voting-app-vote --timeout=300s
kubectl rollout status deployment voting-app-worker --timeout=300s
kubectl rollout status deployment voting-app-result --timeout=300s
kubectl rollout status deployment voting-app-redis --timeout=300s
kubectl rollout status statefulset voting-app-postgres --timeout=300s

echo "Deploy complete."
echo "  Add to /etc/hosts: 127.0.0.1 vote.127.0.0.1.nip.io result.127.0.0.1.nip.io"
echo "  vote:   https://vote.127.0.0.1.nip.io:8082/"
echo "  result: https://result.127.0.0.1.nip.io:8082/"

