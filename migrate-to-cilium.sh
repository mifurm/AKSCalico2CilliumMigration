#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-1217c203-6c76-47b4-b61c-9bba62dc8e02}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-calico-support}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-calico-support}"
MODE="${1:---migrate}"
[[ $# -le 1 && ( "$MODE" == --migrate || "$MODE" == --check-only ) ]] || {
  echo "Usage: bash migrate-to-cilium.sh [--migrate|--check-only]" >&2; exit 1;
}
for tool in az kubectl curl jq tee; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
mkdir -p "$ROOT/.local"
export KUBECONFIG="$ROOT/.local/kubeconfig"
RECORDS="$ROOT/.local/cilium-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir "$RECORDS"
printf '%s\n' "$RECORDS" > "$ROOT/.local/latest-cilium-records.txt"
exec > >(tee "$RECORDS/outcome.log") 2>&1
monitor_pid=
sampler_pid=
stop_helpers() {
  if [[ -n "$monitor_pid" ]]; then kill "$monitor_pid" 2>/dev/null || true; wait "$monitor_pid" 2>/dev/null || true; monitor_pid=; fi
  if [[ -n "$sampler_pid" ]]; then kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true; sampler_pid=; fi
}
finish() {
  status=$?
  stop_helpers
  printf 'Finished UTC: %s; exit: %s\n' "$(date -u +%FT%TZ)" "$status"
  printf '%s\n' "$status" > "$RECORDS/exit-code.txt"
  if [[ "$status" -ne 0 ]]; then
    echo "FAILED: inspect records and live state. Preparation capacity may remain billable; no rollback or LTS enrollment attempted."
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Started UTC: $(date -u +%FT%TZ); mode: $MODE; records: $RECORDS"
cluster_state() {
  az aks show --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --only-show-errors -o json
}
snapshot() {
  local phase="$1"
  date -u +%FT%TZ > "$RECORDS/$phase.timestamp.txt"
  cluster_state > "$RECORDS/$phase.cluster.json"
  kubectl get nodes -o json > "$RECORDS/$phase.nodes.json"
  kubectl get pods -A -o json > "$RECORDS/$phase.pods.json"
  kubectl get services -A -o json > "$RECORDS/$phase.services.json"
  kubectl get networkpolicies -A -o json > "$RECORDS/$phase.policies.json"
  kubectl get daemonsets -A -o json > "$RECORDS/$phase.daemonsets.json"
  kubectl -n sample-app get deployment sample-app -o json > "$RECORDS/$phase.app.json"
  kubectl get events -A -o json > "$RECORDS/$phase.events.json"
}
check_http() {
  curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 10 \
    "http://$app_ip/" -o "$RECORDS/verified-response.html"
  grep -Fq 'AKS Calico sample is running' "$RECORDS/verified-response.html"
}
persist_dataplane() {
  jq '.parameters.networkDataplane.value = "cilium"' "$ROOT/infra/deployment.parameters.json" \
    > "$RECORDS/deployment.parameters.json"
  cp "$RECORDS/deployment.parameters.json" "$ROOT/infra/deployment.parameters.json"
}
cli_version="$(az version -o json | jq -er '."azure-cli"')"
jq -en --arg version "$cli_version" '$version | split(".") | map(tonumber) | .[0] > 2 or (.[0] == 2 and .[1] >= 52)' >/dev/null
echo "Azure CLI: $cli_version (minimum 2.52.0)"
cluster_state > "$RECORDS/preflight.cluster.json"
jq -e '
  .provisioningState == "Succeeded" and
  .networkProfile.networkPlugin == "azure" and
  .networkProfile.networkPluginMode == "overlay" and
  (.networkProfile.networkDataplane == "azure" or .networkProfile.networkDataplane == "cilium") and
  (.networkProfile.networkPolicy == "calico" or .networkProfile.networkPolicy == "cilium") and
  (.nodeProvisioningProfile.mode // "Manual") != "Auto" and
  (.agentPoolProfiles | length == 1) and
  all(.agentPoolProfiles[]; .osType == "Linux" and .provisioningState == "Succeeded" and (.enableAutoScaling != true))
' "$RECORDS/preflight.cluster.json" >/dev/null || {
  echo "Unsupported/unhealthy configuration: this demo requires Azure CNI Overlay, Linux, NAP off, one manual pool, Calico or Cilium." >&2; exit 1;
}
az aks get-credentials --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --file "$KUBECONFIG" --overwrite-existing --only-show-errors
chmod 600 "$KUBECONFIG"
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl -n sample-app rollout status deployment/sample-app --timeout=300s
app_ip="$(kubectl -n sample-app get service sample-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
[[ -n "$app_ip" ]]
check_http
snapshot before
kubectl get crds -o json > "$RECORDS/before.crds.json"
# Calico-specific policies cannot simply be assumed to translate to Cilium.
while IFS= read -r crd; do
  [[ -n "$crd" ]] || continue
  kubectl get "$crd" -A -o json > "$RECORDS/before.$crd.json"
  jq -e --arg crd "$crd" '
    .items | map(select((
      $crd == "globalnetworkpolicies.crd.projectcalico.org" and
      .metadata.name == "aaa-allow-konnectivity-agent" and
      .metadata.labels["app.kubernetes.io/managed-by"] == "Eno" and
      .spec == {
        egress:[{action:"Allow",destination:{},source:{}}],
        namespaceSelector:"projectcalico.org/name == \"kube-system\"",
        order:0,selector:"app == \"konnectivity-agent\"",types:["Egress"]
      }
    ) | not)) | length == 0
  ' "$RECORDS/before.$crd.json" >/dev/null || {
    echo "Calico-specific policy resources require manual translation: $crd" >&2; exit 1;
  }
  if [[ "$(jq '.items | length' "$RECORDS/before.$crd.json")" -gt 0 ]]; then
    echo "Recognized exact AKS-managed aaa-allow-konnectivity-agent policy; retained for AKS-managed replacement. No custom policy exemption."
  fi
done < <(jq -r '.items[].metadata.name | select(test("^(globalnetworkpolicies|networkpolicies|globalnetworksets|networksets)\\.crd\\.projectcalico\\.org$"))' "$RECORDS/before.crds.json")
if [[ "$MODE" == --check-only ]]; then
  echo "Preflight passed; no Azure or workload changes."; exit 0
fi
if [[ "$(jq -r '.networkProfile.networkDataplane' "$RECORDS/before.cluster.json")" == cilium ]]; then
  persist_dataplane
  kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
  echo "Already Cilium; declarative parameters reconciled and endpoint checked."; exit 0
fi
kubectl -n calico-system rollout status daemonset/calico-node --timeout=300s
pool="$(jq -r '.agentPoolProfiles[0].name' "$RECORDS/before.cluster.json")"
current_count="$(jq -r '.agentPoolProfiles[0].count' "$RECORDS/before.cluster.json")"
original_count="${RESTORE_NODE_COUNT:-$current_count}"
original_replicas="${RESTORE_APP_REPLICAS:-$(jq -r '.spec.replicas' "$RECORDS/before.app.json")}"
[[ "$original_count" =~ ^[1-9][0-9]*$ && "$original_replicas" =~ ^[1-9][0-9]*$ ]] || {
  echo "Restoration counts must be positive integers." >&2; exit 1;
}
printf 'Restoration target: %s node(s), %s replica(s).\n' "$original_count" "$original_replicas"
date -u +%FT%TZ > "$RECORDS/preparation-start.txt"
echo "Preparation: temporary minimum two nodes and two app replicas; billed compute/disks increase until restored. This does not guarantee continuity."
if [[ "$current_count" -lt 2 ]]; then
  echo "Command: az aks nodepool scale --subscription $SUBSCRIPTION_ID -g $RESOURCE_GROUP --cluster-name $CLUSTER_NAME -n $pool --node-count 2"
  az aks nodepool scale --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" \
    -n "$pool" --node-count 2 --only-show-errors -o none
fi
kubectl wait --for=condition=Ready nodes --all --timeout=600s
if [[ "$original_replicas" -lt 2 ]]; then kubectl -n sample-app scale deployment/sample-app --replicas=2; fi
kubectl -n sample-app rollout status deployment/sample-app --timeout=300s
if kubectl -n sample-app get pdb migration-availability >/dev/null 2>&1; then
  echo "Refusing to overwrite existing migration-availability PDB." >&2; exit 1
fi
kubectl apply -f - <<'YAML'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: migration-availability
  namespace: sample-app
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: sample-app
YAML
snapshot prepared
check_http
(
  trap 'exit 0' TERM INT
  printf 'timestamp_utc,epoch,curl_exit,http_status,seconds,marker_ok\n' > "$RECORDS/http.csv"
  while :; do
    timestamp="$(date -u +%FT%TZ)"; epoch="$(date +%s)"
    rc=0
    metrics="$(curl --noproxy '*' --silent --show-error --connect-timeout 3 --max-time 5 \
      "http://$app_ip/" -o "$RECORDS/monitor-response.html" -w '%{http_code},%{time_total}' \
      2>>"$RECORDS/http-errors.log")" || rc=$?
    marker=false
    if [[ "$rc" -eq 0 ]] && grep -Fq 'AKS Calico sample is running' "$RECORDS/monitor-response.html"; then marker=true; fi
    printf '%s,%s,%s,%s,%s\n' "$timestamp" "$epoch" "$rc" "$metrics" "$marker" >> "$RECORDS/http.csv"
    sleep 2
  done
) &
monitor_pid=$!
(
  trap 'exit 0' TERM INT
  sample=0
  while :; do
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    kubectl --request-timeout=8s get nodes -o json > "$RECORDS/during-$stamp.nodes.json" 2>>"$RECORDS/sampler-errors.log" || true
    kubectl --request-timeout=8s get pods -A -o json > "$RECORDS/during-$stamp.pods.json" 2>>"$RECORDS/sampler-errors.log" || true
    if [[ $((sample % 4)) -eq 0 ]]; then
      cluster_state > "$RECORDS/during-$stamp.cluster.json" 2>>"$RECORDS/sampler-errors.log" || true
    fi
    sample=$((sample + 1))
    sleep 15
  done
) &
sampler_pid=$!
sleep 10
kill -0 "$monitor_pid"; kill -0 "$sampler_pid"
[[ "$(wc -l < "$RECORDS/http.csv")" -gt 1 ]]
date -u +%FT%TZ > "$RECORDS/migration-start.txt"
echo "Command: az aks update --subscription $SUBSCRIPTION_ID -g $RESOURCE_GROUP -n $CLUSTER_NAME --network-dataplane cilium --network-policy cilium --only-show-errors -o none"
update_status=0
az aks update --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --network-dataplane cilium --network-policy cilium --only-show-errors -o none || update_status=$?
date -u +%FT%TZ > "$RECORDS/migration-end.txt"
printf '%s\n' "$update_status" > "$RECORDS/update-exit-code.txt"
cluster_state > "$RECORDS/update.cluster.json"
# Persist even after a CLI error if Azure accepted the new data plane.
if [[ "$(jq -r '.networkProfile.networkDataplane' "$RECORDS/update.cluster.json")" == cilium ]]; then persist_dataplane; fi
[[ "$update_status" -eq 0 ]] || exit "$update_status"
kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl -n kube-system rollout status daemonset/cilium --timeout=600s
kubectl -n sample-app rollout status deployment/sample-app --timeout=600s
check_http
snapshot after
jq -e '.provisioningState == "Succeeded" and .networkProfile.networkDataplane == "cilium" and .networkProfile.networkPolicy == "cilium"' "$RECORDS/after.cluster.json" >/dev/null
jq -S '{version:.currentKubernetesVersion,desiredVersion:.kubernetesVersion,plan:.supportPlan,tier:.sku.tier,
  networking:(.networkProfile | del(.networkPolicy,.networkDataplane))}' "$RECORDS/before.cluster.json" > "$RECORDS/invariants-before.json"
jq -S '{version:.currentKubernetesVersion,desiredVersion:.kubernetesVersion,plan:.supportPlan,tier:.sku.tier,
  networking:(.networkProfile | del(.networkPolicy,.networkDataplane))}' "$RECORDS/after.cluster.json" > "$RECORDS/invariants-after.json"
diff -u "$RECORDS/invariants-before.json" "$RECORDS/invariants-after.json"
diff -u <(jq -S '[.items[] | {name:.metadata.name,namespace:.metadata.namespace,spec}]' "$RECORDS/before.policies.json") \
  <(jq -S '[.items[] | {name:.metadata.name,namespace:.metadata.namespace,spec}]' "$RECORDS/after.policies.json")
[[ "$(kubectl -n sample-app get service sample-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" == "$app_ip" ]]
if kubectl get daemonsets -A -o json | jq -e '.items[] | select(.metadata.name == "calico-node")' >/dev/null; then
  echo "Calico daemonset remains unexpectedly." >&2; exit 1
fi
echo "Restoring original capacity: $original_count node(s), $original_replicas replica(s)."
date -u +%FT%TZ > "$RECORDS/restoration-start.txt"
kubectl -n sample-app delete pdb migration-availability
kubectl -n sample-app scale deployment/sample-app --replicas="$original_replicas"
kubectl -n sample-app rollout status deployment/sample-app --timeout=300s
if [[ "$original_count" -ne "$(jq -r '.agentPoolProfiles[0].count' "$RECORDS/after.cluster.json")" ]]; then
  az aks nodepool scale --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" \
    -n "$pool" --node-count "$original_count" --only-show-errors -o none
fi
kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl -n sample-app rollout status deployment/sample-app --timeout=600s
check_http
sleep 30
snapshot final
jq -e --argjson count "$original_count" --argjson replicas "$original_replicas" \
  '.agentPoolProfiles[0].count == $count and .provisioningState == "Succeeded" and
   .networkProfile.networkDataplane == "cilium"' "$RECORDS/final.cluster.json" >/dev/null
jq -e --argjson replicas "$original_replicas" '.spec.replicas == $replicas and .status.availableReplicas == $replicas' \
  "$RECORDS/final.app.json" >/dev/null
[[ "$(kubectl -n sample-app get service sample-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" == "$app_ip" ]]
version="$(jq -r '.currentKubernetesVersion' "$RECORDS/final.cluster.json")"
jq -e --arg version "v$version" '.items | length > 0 and all(.[]; .status.nodeInfo.kubeletVersion == $version)' \
  "$RECORDS/final.nodes.json" >/dev/null
stop_helpers
jq -Rs '
  split("\n") | .[1:] | map(select(length > 0) | split(",")) |
  map({timestamp:.[0],epoch:(.[1]|tonumber),curlExit:(.[2]|tonumber),httpStatus:.[3],
       seconds:(.[4]|tonumber),marker:(.[5] == "true")}) |
  {samples:length,successes:([.[]|select(.curlExit == 0 and .httpStatus == "200" and .marker)]|length),
   failures:([.[]|select(.curlExit != 0 or .httpStatus != "200" or (.marker|not))]|length),
   first:.[0].timestamp,last:.[-1].timestamp,observations:.}
' "$RECORDS/http.csv" > "$RECORDS/http-summary.json"
echo "Verified Cilium, retained Overlay/version/tier/support plan/policies/public IP and healthy sample HTTP. Security equivalence was not tested."
echo "Endpoint: http://$app_ip/; evidence: $RECORDS"
