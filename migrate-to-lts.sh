#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-1217c203-6c76-47b4-b61c-9bba62dc8e02}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-calico-support}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-calico-support}"
MODE="${1:---migrate}"
if [[ $# -gt 1 || ( "$MODE" != --migrate && "$MODE" != --check-only && "$MODE" != --attempt-migration ) ]]; then
  echo "Usage: bash migrate-to-lts.sh [--migrate|--check-only|--attempt-migration]" >&2
  exit 1
fi

for tool in az kubectl curl jq tee mktemp; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
mkdir -p "$ROOT/.local"
export KUBECONFIG="$ROOT/.local/kubeconfig"
REPORT_DIR="$(mktemp -d "$ROOT/.local/lts-migration-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
exec > >(tee "$REPORT_DIR/outcome.log") 2>&1
monitor_pid=
finish() {
  status=$?
  if [[ -n "$monitor_pid" ]]; then
    touch "$REPORT_DIR/stop-monitor"
    wait "$monitor_pid"
  fi
  printf 'Finished (UTC): %s; script exit code: %s\n' "$(date -u +%FT%TZ)" "$status"
}
trap finish EXIT
printf 'Started (UTC): %s\nMode: %s\nRecords: %s\n' "$(date -u +%FT%TZ)" "$MODE" "$REPORT_DIR"

cluster_state() {
  az aks show --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o json
}

snapshot_workloads() {
  kubectl get nodes -o json > "$REPORT_DIR/$1-nodes.json"
  kubectl -n sample-app get pods,deployments,services,networkpolicies -o json > "$REPORT_DIR/$1-app.json"
  kubectl -n kube-system get daemonset cilium -o json > "$REPORT_DIR/$1-cilium.json"
}

check_versions() {
  jq -e '
    .provisioningState == "Succeeded" and
    (.currentKubernetesVersion | test("^1\\.35\\.[0-9]+$")) and
    .kubernetesVersion == .currentKubernetesVersion and
    (.agentPoolProfiles | length > 0) and
    all(.agentPoolProfiles[];
      .provisioningState == "Succeeded" and
      (.currentOrchestratorVersion | test("^1\\.35\\.[0-9]+$")))
  ' <<< "$1" >/dev/null || {
    echo "Expected a successfully provisioned Kubernetes 1.35 cluster and node pools." >&2
    exit 1
  }
}

network_state() {
  jq -cS '.networkProfile | {
    networkPlugin, networkPluginMode, networkPolicy, networkDataplane,
    podCidrs, serviceCidrs, dnsServiceIp, outboundType, loadBalancerSku
  }' <<< "$1"
}

check_app() {
  kubectl -n sample-app rollout status deployment/sample-app --timeout=120s
  app_ip="$(kubectl -n sample-app get service sample-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  if [[ -z "$app_ip" ]]; then
    echo "Sample application's public IP is missing." >&2
    exit 1
  fi
  response="$(curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 15 "http://$app_ip/")"
  if [[ "$response" != *"AKS Calico sample is running"* ]]; then
    echo "Sample application returned an unexpected response." >&2
    exit 1
  fi
}

before="$(cluster_state)"
printf '%s\n' "$before" > "$REPORT_DIR/before.json"
if [[ "$(jq -r '.powerState.code' <<< "$before")" != Running ]]; then
  echo "Cluster must be running before LTS enrollment. Start it with az aks start, then verify application recovery." >&2
  exit 1
fi
check_versions "$before"
version="$(jq -r '.currentKubernetesVersion' <<< "$before")"
plan="$(jq -r '.supportPlan' <<< "$before")"
tier="$(jq -r '.sku.tier' <<< "$before")"
network_before="$(network_state "$before")"
policy="$(jq -r '.networkProfile.networkPolicy' <<< "$before")"

az aks get-credentials --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --file "$KUBECONFIG" --overwrite-existing --only-show-errors
chmod 600 "$KUBECONFIG"
kubectl wait --for=condition=Ready nodes --all --timeout=120s
node_versions="$(kubectl get nodes -o json)"
jq -e '.items | length > 0 and all(.[];
  .status.nodeInfo.kubeletVersion | test("^v1\\.35\\.[0-9]+$"))
' <<< "$node_versions" >/dev/null || {
  echo "One or more live nodes are not running Kubernetes 1.35." >&2
  exit 1
}
if [[ "$policy" == calico ]]; then
  kubectl -n calico-system rollout status daemonset/calico-node --timeout=120s
elif [[ "$policy" == cilium ]]; then
  kubectl -n kube-system rollout status daemonset/cilium --timeout=120s
  snapshot_workloads before
fi
check_app
original_ip="$app_ip"
printf 'Kubernetes: %s; tier: %s; support plan: %s\n' "$version" "$tier" "$plan"
printf 'Networking: %s\nApplication verified: http://%s/\n' "$network_before" "$app_ip"

# AKS rejects managed Calico with LTS, even during community support.
if [[ "$policy" == calico && "$MODE" != --attempt-migration ]]; then
  echo "BLOCKED: AKS LTS does not support Microsoft-managed Calico (LTSUnsupportedAddon)." >&2
  echo "No Azure resources or Kubernetes workloads were changed. Keeping Calico requires community support." >&2
  echo "Reference: https://learn.microsoft.com/azure/aks/long-term-support#add-on-and-feature-lifecycle-considerations" >&2
  exit 2
fi

update_status=0
if [[ "$MODE" != --check-only && ( "$plan" != AKSLongTermSupport || "$tier" != Premium ) ]]; then
  if [[ "$policy" == calico ]]; then
    echo "Explicit attempt requested: submitting the unsupported Calico/LTS combination to Azure."
  fi
  echo "Enabling the billable Premium tier and LTS plan without changing Kubernetes or networking."
  printf 'Command: az aks update --subscription %s -g %s -n %s --tier premium --k8s-support-plan AKSLongTermSupport --only-show-errors -o none\n' \
    "$SUBSCRIPTION_ID" "$RESOURCE_GROUP" "$CLUSTER_NAME"
  (
    printf 'timestamp_utc,curl_exit,http_status,seconds,marker_ok\n' > "$REPORT_DIR/http.csv"
    while [[ ! -f "$REPORT_DIR/stop-monitor" ]]; do
      rc=0
      metrics="$(curl --noproxy '*' --fail --silent --show-error --connect-timeout 3 --max-time 5 \
        "http://$original_ip/" -o "$REPORT_DIR/monitor-response.html" \
        -w '%{http_code},%{time_total}' 2>>"$REPORT_DIR/http-errors.log")" || rc=$?
      marker=false
      if [[ "$rc" -eq 0 ]] && grep -Fq 'AKS Calico sample is running' "$REPORT_DIR/monitor-response.html"; then
        marker=true
      fi
      printf '%s,%s,%s,%s\n' "$(date -u +%FT%TZ)" "$rc" "$metrics" "$marker" >> "$REPORT_DIR/http.csv"
      sleep 2
    done
  ) &
  monitor_pid=$!
  sleep 3
  kill -0 "$monitor_pid"
  [[ "$(wc -l < "$REPORT_DIR/http.csv")" -gt 1 ]]
  printf '%s\n' "$(date -u +%FT%TZ)" > "$REPORT_DIR/update-start.txt"
  if az aks update --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
      --tier premium --k8s-support-plan AKSLongTermSupport --only-show-errors -o none; then
    echo "Azure update command succeeded."
  else
    update_status=$?
    printf 'Azure update failed (exit %s). Checking the cluster and app after the attempt.\n' "$update_status" >&2
  fi
  printf '%s\n' "$(date -u +%FT%TZ)" > "$REPORT_DIR/update-end.txt"
fi

after="$(cluster_state)"
printf '%s\n' "$after" > "$REPORT_DIR/after.json"
printf 'After attempt: Kubernetes %s; tier: %s; support plan: %s; provisioning: %s\n' \
  "$(jq -r '.currentKubernetesVersion' <<< "$after")" \
  "$(jq -r '.sku.tier' <<< "$after")" \
  "$(jq -r '.supportPlan' <<< "$after")" \
  "$(jq -r '.provisioningState' <<< "$after")"
check_app
printf 'Application verified after attempt: http://%s/\n' "$app_ip"
kubectl wait --for=condition=Ready nodes --all --timeout=120s
if [[ "$policy" == calico ]]; then
  kubectl -n calico-system rollout status daemonset/calico-node --timeout=120s
elif [[ "$policy" == cilium ]]; then
  kubectl -n kube-system rollout status daemonset/cilium --timeout=120s
  snapshot_workloads after
fi
check_versions "$after"
if [[ "$(jq -r '.currentKubernetesVersion' <<< "$after")" != "$version" ||
      "$(network_state "$after")" != "$network_before" ]]; then
  echo "Cluster version or networking changed unexpectedly." >&2
  exit 1
fi
if [[ "$app_ip" != "$original_ip" ]]; then
  echo "The application's public IP changed unexpectedly." >&2
  exit 1
fi
echo "Verified unchanged Kubernetes patch version, network configuration, and public app IP."
if [[ "$update_status" -ne 0 ]]; then
  echo "Migration failed. See the Azure error above and the before/after state records." >&2
  exit "$update_status"
fi
if ! jq -e '.supportPlan == "AKSLongTermSupport" and .sku.tier == "Premium"' <<< "$after" >/dev/null; then
  echo "Cluster is not configured for LTS: Premium and AKSLongTermSupport are both required." >&2
  exit 1
fi
printf 'Verified Kubernetes %s with Premium/AKSLongTermSupport, unchanged networking, and working app.\n' "$version"
if [[ -n "$monitor_pid" ]]; then
  touch "$REPORT_DIR/stop-monitor"
  wait "$monitor_pid"
  monitor_pid=
  jq -Rn '[inputs | split(",")] | .[1:] |
    {probes:length, failures:([.[] | select(.[1] != "0" or .[2] != "200" or .[4] != "true")] | length)}
  ' < "$REPORT_DIR/http.csv" | tee "$REPORT_DIR/http-summary.json"
fi
