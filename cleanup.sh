#!/usr/bin/env bash
set -euo pipefail

# Uninstalls everything deployed by the tutorial, returning the cluster
# to a state with no OpenShift AI, GPU Operator, or NFD installed.
# Run order: workloads → OpenShift AI → dependencies → GPU → NFD

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

delete_if_exists() {
  if oc get "$@" &>/dev/null; then
    oc delete "$@" --timeout=120s 2>/dev/null || warn "Timed out deleting $*, forcing..."
    oc delete "$@" --force --grace-period=0 2>/dev/null || true
  fi
}

delete_subscription_and_csv() {
  local name=$1 namespace=$2
  local csv
  csv=$(oc get subscription "$name" -n "$namespace" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  delete_if_exists subscription "$name" -n "$namespace"
  if [[ -n "$csv" ]]; then
    delete_if_exists clusterserviceversion "$csv" -n "$namespace"
  fi
}

delete_namespace_if_exists() {
  local ns=$1
  if oc get namespace "$ns" &>/dev/null; then
    info "Deleting namespace $ns..."
    oc delete namespace "$ns" --timeout=120s 2>/dev/null || {
      warn "Namespace $ns stuck terminating — removing finalizers..."
      oc get namespace "$ns" -o json | \
        jq '.spec.finalizers = []' | \
        oc replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
    }
  fi
}

# ─── Preflight ────────────────────────────────────────────────────────────────

if ! oc whoami &>/dev/null; then
  error "Not logged in to an OpenShift cluster. Run 'oc login' first."
  exit 1
fi

CLUSTER=$(oc whoami --show-server)
echo ""
warn "This will remove ALL tutorial components from: $CLUSTER"
warn "Destructive, cluster-wide cleanup: this script deletes operators, CRDs, and node labels/resources."
warn "Do NOT run on a shared or production cluster unless you understand and accept the impact."
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""

# ─── Step 1: Model workload ──────────────────────────────────────────────────

info "Removing model deployment..."
delete_if_exists inferenceservice llama-32-3b-instruct -n my-first-model
delete_if_exists servingruntime llama-32-3b-instruct -n my-first-model
delete_namespace_if_exists my-first-model

# ─── Step 2: OpenShift AI (RHODS) ────────────────────────────────────────────

info "Removing GPU hardware profile..."
delete_if_exists hardwareprofile gpu-profile -n redhat-ods-applications

info "Removing OpenShift AI configuration..."
delete_if_exists datasciencecluster default-dsc
delete_if_exists dscinitialization default-dsci

info "Removing OpenShift AI operator..."
delete_subscription_and_csv rhods-operator redhat-ods-operator

info "Cleaning up OpenShift AI managed namespaces..."
delete_namespace_if_exists redhat-ods-applications
delete_namespace_if_exists redhat-ods-monitoring
delete_namespace_if_exists rhoai-model-registries
delete_namespace_if_exists rhods-notebooks
delete_namespace_if_exists redhat-ods-operator

# ─── Step 3: OpenShift AI Dependencies ───────────────────────────────────────

info "Removing Pipelines operator..."
delete_subscription_and_csv openshift-pipelines-operator openshift-operators

info "Removing Authorino operator..."
delete_subscription_and_csv authorino-operator openshift-operators

info "Removing Service Mesh (Sail) operator..."
if oc get subscription servicemeshoperator3 -n openshift-operators -o jsonpath='{.metadata.annotations}' 2>/dev/null | grep -q "ingress.operator.openshift.io/owned"; then
  warn "Service Mesh subscription is platform-managed (ingress operator) — skipping."
else
  delete_subscription_and_csv servicemeshoperator3 openshift-operators
fi

info "Removing Serverless operator..."
delete_subscription_and_csv serverless-operator openshift-serverless
delete_namespace_if_exists openshift-serverless

# ─── Step 4: NVIDIA GPU Operator ─────────────────────────────────────────────

info "Removing GPU ClusterPolicy..."
delete_if_exists clusterpolicy gpu-cluster-policy

info "Removing GPU operator..."
delete_subscription_and_csv gpu-operator-certified nvidia-gpu-operator
delete_namespace_if_exists nvidia-gpu-operator

# ─── Step 5: Node Feature Discovery ──────────────────────────────────────────

info "Removing NFD instance..."
delete_if_exists nodefeaturediscovery nfd-instance -n openshift-nfd

info "Removing NFD operator..."
delete_subscription_and_csv nfd openshift-nfd
delete_namespace_if_exists openshift-nfd

# ─── Step 6: Cleanup CRDs (optional but thorough) ────────────────────────────

info "Removing leftover CRDs..."
for pattern in nvidia.com nfd.openshift.io datasciencecluster opendatahub kserve; do
  for crd in $(oc get crd -o name 2>/dev/null | grep "$pattern" || true); do
    info "  Deleting $crd"
    oc delete "$crd" --timeout=30s 2>/dev/null || true
  done
done

# ─── Step 7: Remove nvidia/nfd labels and extended resources from nodes ───────

info "Removing nvidia/nfd labels and annotations from nodes..."
for node in $(oc get nodes -o name); do
  label_args=()
  while IFS= read -r label; do
    [[ -n "$label" ]] && label_args+=("${label}-")
  done < <(oc get "$node" -o json | jq -r '.metadata.labels | keys[] | select(startswith("nvidia.com") or startswith("feature.node.kubernetes.io/"))' 2>/dev/null)
  if [[ ${#label_args[@]} -gt 0 ]]; then
    oc label "$node" "${label_args[@]}" 2>/dev/null || true
    info "  Removed ${#label_args[@]} labels from $node"
  fi

  ann_args=()
  while IFS= read -r ann; do
    [[ -n "$ann" ]] && ann_args+=("${ann}-")
  done < <(oc get "$node" -o json | jq -r '.metadata.annotations | keys[] | select(startswith("nvidia.com") or startswith("nfd.node.kubernetes.io/"))' 2>/dev/null)
  if [[ ${#ann_args[@]} -gt 0 ]]; then
    oc annotate "$node" "${ann_args[@]}" 2>/dev/null || true
    info "  Removed ${#ann_args[@]} annotations from $node"
  fi
done

info "Removing nvidia.com/gpu extended resource from nodes..."
oc proxy &>/dev/null & PROXY_PID=$!
sleep 2
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  if oc get node "$node" -o jsonpath='{.status.capacity}' | grep -q "nvidia.com/gpu"; then
    curl -s -X PATCH -H "Content-Type: application/json-patch+json" \
      --data '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"}]' \
      "http://127.0.0.1:8001/api/v1/nodes/$node/status" >/dev/null 2>&1 && \
      info "  Removed nvidia.com/gpu from $node" || true
  fi
done
kill $PROXY_PID 2>/dev/null || true

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
info "Cleanup complete. Cluster is back to a fresh state."
info "You can verify with:"
echo "  oc get subscriptions.operators -A"
echo "  oc get csv -A"
echo "  oc get ns | grep -E 'nvidia|nfd|rhods|rhoai|serverless|my-first'"
