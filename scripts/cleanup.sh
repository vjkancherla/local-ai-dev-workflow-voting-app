#!/usr/bin/env bash
set -euo pipefail

# Tear down the local k3d deployment created by scripts/deploy.sh.
#
# By default this only deletes the Kubernetes resources (reverse of
# `kubectl apply -k`). The k3d cluster and the generated
# kustomize/postgres-secret.env are removed only when explicitly requested via
# the DELETE_CLUSTER / REMOVE_SECRETS flags, so a plain run is safe to repeat.
#
# Matching deploy.sh: with REGISTRY=1 the registry overlay is used so the same
# resources that were applied are the ones deleted.
#
#   CLUSTER="${CLUSTER:-voting-app}"   k3d cluster name (must match deploy.sh)
#   KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-./kustomize}"
#   REGISTRY="${REGISTRY:-0}"          1 to target the registry overlay
#   DELETE_CLUSTER="${DELETE_CLUSTER:-0}"  1 to also `k3d cluster delete`
#   REMOVE_SECRETS="${REMOVE_SECRETS:-0}"  1 to also delete postgres-secret.env

CLUSTER="${CLUSTER:-voting-app}"
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-./kustomize}"
REGISTRY="${REGISTRY:-0}"
DELETE_CLUSTER="${DELETE_CLUSTER:-0}"
REMOVE_SECRETS="${REMOVE_SECRETS:-0}"

# Decide which overlay to target, matching deploy.sh.
if [[ "$REGISTRY" == "1" ]]; then
  TARGET="${KUSTOMIZE_DIR}/overlays/registry"
else
  TARGET="${KUSTOMIZE_DIR}"
fi

# --- Dependency checks -------------------------------------------------------
missing=0
for cmd in kubectl k3d; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: '$cmd' is not installed or not on PATH." >&2
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

# --- Delete Kubernetes resources ---------------------------------------------
echo "Deleting Kubernetes resources from '${CLUSTER}' using ${TARGET} ..."
# '--ignore-not-found' so deleting already-removed resources doesn't abort the run.
kubectl delete -k "$TARGET" --ignore-not-found || true

# Give the control plane a moment to cascade deletions, then report.
sleep 3
echo
echo "Remaining voting-app workloads (if any):"
kubectl get all,statefulset -l app.kubernetes.io/part-of=voting-app \
  || echo "  (none visible / cluster not reachable)"

# --- Optional: delete the generated secret env file --------------------------
if [[ "$REMOVE_SECRETS" == "1" ]]; then
  SECRET_ENV="${KUSTOMIZE_DIR}/postgres-secret.env"
  if [[ -f "$SECRET_ENV" ]]; then
    rm -f "$SECRET_ENV"
    echo
    echo "Removed ${SECRET_ENV}."
  else
    echo
    echo "Nothing to remove: ${SECRET_ENV} does not exist."
  fi
fi

# --- Optional: delete the k3d cluster ----------------------------------------
if [[ "$DELETE_CLUSTER" == "1" ]]; then
  if k3d cluster list 2>/dev/null | grep -qE "^${CLUSTER}[[:space:]]"; then
    echo
    echo "Deleting k3d cluster '${CLUSTER}' ..."
    k3d cluster delete "$CLUSTER"
  else
    echo
    echo "No k3d cluster named '${CLUSTER}' found; skipping cluster delete."
  fi
fi

echo
echo "Cleanup complete."
