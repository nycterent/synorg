#!/usr/bin/env bash
# kwok-down.sh — delete the isolated kwok/Karpenter kind cluster
# (kwok-cluster.yaml). Idempotent: safe to run when the cluster (or even kind
# itself) is absent.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="$(sed -n 's/^name:[[:space:]]*//p' "$HERE/kwok-cluster.yaml")"

if ! command -v kind >/dev/null 2>&1; then
  echo "kind not installed — no kwok cluster can exist; nothing to delete"
  exit 0
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
  echo "kwok cluster down: '$CLUSTER_NAME' deleted"
else
  echo "kwok cluster already down: no kind cluster named '$CLUSTER_NAME'"
fi
