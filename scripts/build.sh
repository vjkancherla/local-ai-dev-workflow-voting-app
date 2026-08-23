#!/usr/bin/env bash
set -euo pipefail

# Build the three application images (vote, worker, result) for linux/arm64 and
# load them into the k3d cluster.
#
# Primary workflow (default): tag images plainly and `k3d image import` them
# directly into the cluster's containerd. No registry, no push, no `.local` DNS.
#
# Registry fallback (REGISTRY=1): build and push to the k3d-managed registry.
# On macOS, AirPlay Receiver may claim port 5000 — set REGISTRY_PORT=5001 if so.
# Deploy with REGISTRY=1 so deploy.sh points image refs at the registry.

CLUSTER="${CLUSTER:-voting-app}"
REGISTRY="${REGISTRY:-0}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"

SERVICES=(vote worker result)

if [[ "$REGISTRY" == "1" ]]; then
  for svc in "${SERVICES[@]}"; do
    docker build --platform linux/arm64 -t "localhost:${REGISTRY_PORT}/${svc}:latest" "./${svc}"
    docker push "localhost:${REGISTRY_PORT}/${svc}:latest"
  done
  echo "Pushed images to registry localhost:${REGISTRY_PORT}. Deploy with REGISTRY=1."
else
  for svc in "${SERVICES[@]}"; do
    docker build --platform linux/arm64 -t "${svc}:latest" "./${svc}"
    k3d image import "${svc}:latest" -c "$CLUSTER"
  done
  echo "Imported ${SERVICES[*]} into k3d cluster '${CLUSTER}'."
fi
