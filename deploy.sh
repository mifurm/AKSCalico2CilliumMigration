#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-1217c203-6c76-47b4-b61c-9bba62dc8e02}"
LOCATION="${LOCATION:-westeurope}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-calico-support}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-calico-support}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35.9}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D2s_v5}"

for tool in az kubectl curl jq; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
if [[ ! "$KUBERNETES_VERSION" =~ ^1\.35\.[0-9]+$ ]]; then
  echo "This deployment requires an exact Kubernetes 1.35 patch version." >&2
  exit 1
fi

mkdir -p "$ROOT/.local"
export KUBECONFIG="$ROOT/.local/kubeconfig"
dataplane="$(jq -er '.parameters.networkDataplane.value' "$ROOT/infra/deployment.parameters.json")"
[[ "$dataplane" == azure || "$dataplane" == cilium ]] || { echo "Invalid declarative data plane." >&2; exit 1; }
policy=calico
[[ "$dataplane" != cilium ]] || policy=cilium
tier="$(jq -er '.parameters.skuTier.value' "$ROOT/infra/deployment.parameters.json")"
support_plan="$(jq -er '.parameters.supportPlan.value' "$ROOT/infra/deployment.parameters.json")"
if [[ "$tier" == Premium && "$support_plan" == AKSLongTermSupport && "$dataplane" == cilium ]]; then
  :
elif [[ "$tier" != Free || "$support_plan" != KubernetesOfficial ]]; then
  echo "Invalid tier/support-plan/data-plane combination." >&2
  exit 1
fi
# Never reconcile an already migrated cluster back to the legacy data plane.
if az aks show --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
    -o json > "$ROOT/.local/deploy-existing.json" 2>"$ROOT/.local/deploy-existing-error.log"; then
  live_dataplane="$(jq -r '.networkProfile.networkDataplane' "$ROOT/.local/deploy-existing.json")"
  [[ "$live_dataplane" != cilium || "$dataplane" == cilium ]] || {
    echo "Refusing to revert Cilium. Reconcile infra/deployment.parameters.json first." >&2; exit 1;
  }
  live_plan="$(jq -r '.supportPlan' "$ROOT/.local/deploy-existing.json")"
  [[ "$live_plan" != AKSLongTermSupport || "$support_plan" == AKSLongTermSupport ]] || {
    echo "Refusing to disable LTS through redeployment." >&2; exit 1;
  }
fi

az deployment sub create \
  --subscription "$SUBSCRIPTION_ID" \
  --name aks-calico-support \
  --location "$LOCATION" \
  --template-file "$ROOT/infra/main.bicep" \
  --parameters "@$ROOT/infra/deployment.parameters.json" location="$LOCATION" resourceGroupName="$RESOURCE_GROUP" \
    clusterName="$CLUSTER_NAME" kubernetesVersion="$KUBERNETES_VERSION" nodeVmSize="$NODE_VM_SIZE" \
  --only-show-errors --output none

actual="$(az aks show --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --query "[[currentKubernetesVersion, supportPlan, sku.tier, networkProfile.networkPlugin, networkProfile.networkPluginMode, networkProfile.networkPolicy, networkProfile.networkDataplane]]" \
  -o tsv)"
expected="$(printf '%s\t%s\t%s\tazure\toverlay\t%s\t%s' "$KUBERNETES_VERSION" "$support_plan" "$tier" "$policy" "$dataplane")"
if [[ "$actual" != "$expected" ]]; then
  printf 'Unexpected cluster configuration:\n%s\n' "$actual" >&2
  exit 1
fi
tag="$(az group show --subscription "$SUBSCRIPTION_ID" -n "$RESOURCE_GROUP" --query tags.SecurityControl -o tsv)"
if [[ "$tag" != Ignore ]]; then
  echo "Resource group is missing SecurityControl=Ignore." >&2
  exit 1
fi

az aks get-credentials --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --file "$KUBECONFIG" --overwrite-existing --only-show-errors
chmod 600 "$KUBECONFIG"
kubectl wait --for=condition=Ready nodes --all --timeout=300s
if [[ "$dataplane" == azure ]]; then
  kubectl -n calico-system wait --for=create daemonset/calico-node --timeout=300s
  kubectl -n calico-system rollout status daemonset/calico-node --timeout=300s
else
  kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
fi
kubectl apply -f "$ROOT/k8s/sample-app.yaml"
kubectl -n sample-app rollout status deployment/sample-app --timeout=300s
kubectl -n sample-app wait service/sample-app \
  --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' --timeout=300s
public_ip="$(kubectl -n sample-app get service sample-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

verified=false
for ((attempt=1; attempt<=30; attempt++)); do
  if curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 10 \
      "http://$public_ip/" -o "$ROOT/.local/response.html"; then
    if grep -Fq 'AKS Calico sample is running' "$ROOT/.local/response.html"; then
      verified=true
      break
    fi
    echo "Endpoint returned an unexpected response." >&2
    exit 1
  fi
  sleep 10
done
if [[ "$verified" != true ]]; then
  echo "Public endpoint did not become reachable: http://$public_ip/" >&2
  exit 1
fi
printf 'http://%s/\n' "$public_ip" > "$ROOT/.local/endpoint.txt"
printf 'Verified AKS %s, %s/%s, %s, and SecurityControl=Ignore.\n' "$KUBERNETES_VERSION" "$tier" "$support_plan" "$policy"
printf 'Sample application: http://%s/\n' "$public_ip"
