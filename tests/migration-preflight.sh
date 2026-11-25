#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.local/preflight-tests-$$"
mkdir -p "$WORK/bin" "$WORK/infra"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/migrate-to-cilium.sh" "$WORK/"
cp "$ROOT/infra/deployment.parameters.json" "$WORK/infra/"
export PATH="$WORK/bin:$PATH" TEST_CALLS="$WORK/calls.log"
cat > "$WORK/bin/az" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'az %s\n' "$*" >> "$TEST_CALLS"
case "$1 $2" in
  "version -o") jq -n --arg version "${TEST_CLI:-2.88.0}" '{"azure-cli":$version}' ;;
  "aks show")
    jq -n --arg os "${TEST_OS:-Linux}" --arg dp "${TEST_DATAPLANE:-azure}" --arg mode "${TEST_NAP:-Manual}" \
      --arg plan "${TEST_PLAN:-KubernetesOfficial}" --arg tier "${TEST_TIER:-Free}" --arg power "${TEST_POWER:-Running}" \
      '{provisioningState:"Succeeded",currentKubernetesVersion:"1.35.9",
        kubernetesVersion:"1.35.9",supportPlan:$plan,sku:{tier:$tier},powerState:{code:$power},
        networkProfile:{networkPlugin:"azure",networkPluginMode:"overlay",networkDataplane:$dp,
          networkPolicy:(if $dp == "cilium" then "cilium" else "calico" end)},
        nodeProvisioningProfile:{mode:$mode},
        agentPoolProfiles:[{name:"system",count:1,osType:$os,provisioningState:"Succeeded",
          currentOrchestratorVersion:"1.35.9",enableAutoScaling:false}]}'
    ;;
  "aks get-credentials")
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --file ]]; then touch "$2"; break; fi
      shift
    done ;;
  *) echo "Unexpected Azure mutation: $*" >&2; exit 90 ;;
esac
SH
cat > "$WORK/bin/kubectl" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'kubectl %s\n' "$*" >> "$TEST_CALLS"
if [[ "$*" == *jsonpath* ]]; then printf '192.0.2.1'; exit 0; fi
if [[ "$*" == *"get deployment"* ]]; then echo '{"spec":{"replicas":1},"status":{"availableReplicas":1}}'; exit 0; fi
if [[ "$*" == *"get pods,deployments,services,networkpolicies"* || "$*" == *"get daemonset cilium"* ]]; then
  echo '{"items":[]}'; exit 0
fi
case "$1 $2" in
  "get crds")
    if [[ "${TEST_CUSTOM_POLICY:-false}" == true || "${TEST_MANAGED_POLICY:-false}" == true ]]; then
      echo '{"items":[{"metadata":{"name":"globalnetworkpolicies.crd.projectcalico.org"}}]}'
    else echo '{"items":[]}'; fi ;;
  "get globalnetworkpolicies.crd.projectcalico.org")
    if [[ "${TEST_MANAGED_POLICY:-false}" == true ]]; then
      jq -n --arg selector "${TEST_MANAGED_SELECTOR:-app == \"konnectivity-agent\"}" \
        '{items:[{metadata:{name:"aaa-allow-konnectivity-agent",labels:{"app.kubernetes.io/managed-by":"Eno"}},
          spec:{egress:[{action:"Allow",destination:{},source:{}}],
            namespaceSelector:"projectcalico.org/name == \"kube-system\"",order:0,selector:$selector,types:["Egress"]}}]}'
    else echo '{"items":[{"metadata":{"name":"custom"}}]}'; fi ;;
  "get nodes") echo '{"items":[{"status":{"nodeInfo":{"kubeletVersion":"v1.35.9"}}}]}' ;;
  get*) echo '{"items":[]}' ;;
  *) [[ "$*" == *wait* || "$*" == *"rollout status"* ]] || { echo "Unexpected Kubernetes mutation" >&2; exit 91; } ;;
esac
SH
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
set -eu
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then printf 'AKS Calico sample is running\n' > "$2"; exit 0; fi
  shift
done
printf 'AKS Calico sample is running\n'
SH
chmod +x "$WORK/bin/"*
run_case() {
  local name="$1" expected="$2" mode="$3"
  shift 3
  : > "$TEST_CALLS"
  local status=0
  env "$@" bash "$WORK/migrate-to-cilium.sh" "$mode" > "$WORK/$name.log" 2>&1 || status=$?
  if [[ "$status" -ne "$expected" ]]; then
    cat "$WORK/$name.log"; echo "$name: expected $expected, got $status" >&2; exit 1
  fi
  if grep -Eq 'az aks (update|nodepool)|kubectl.*(scale|apply|delete)' "$TEST_CALLS"; then
    echo "$name: unexpected mutation" >&2; exit 1
  fi
  echo "PASS: $name"
}
run_case healthy-calico-check 0 --check-only
run_case reject-windows 1 --check-only TEST_OS=Windows
run_case reject-nap 1 --check-only TEST_NAP=Auto
run_case reject-old-cli 1 --check-only TEST_CLI=2.51.0
run_case reject-custom-calico-policy 1 --check-only TEST_CUSTOM_POLICY=true
run_case accept-exact-managed-konnectivity-policy 0 --check-only TEST_MANAGED_POLICY=true
run_case reject-modified-managed-policy 1 --check-only TEST_MANAGED_POLICY=true TEST_MANAGED_SELECTOR=all
run_case reconcile-already-cilium 0 --migrate TEST_DATAPLANE=cilium
jq -e '.parameters.networkDataplane.value == "cilium"' "$WORK/infra/deployment.parameters.json" >/dev/null
cp "$ROOT/deploy.sh" "$WORK/"
jq '.parameters.networkDataplane.value = "azure" |
  .parameters.skuTier.value = "Free" |
  .parameters.supportPlan.value = "KubernetesOfficial"' "$WORK/infra/deployment.parameters.json" > "$WORK/legacy.parameters.json"
cp "$WORK/legacy.parameters.json" "$WORK/infra/deployment.parameters.json"
: > "$TEST_CALLS"
status=0
TEST_DATAPLANE=cilium bash "$WORK/deploy.sh" > "$WORK/revert-guard.log" 2>&1 || status=$?
[[ "$status" -eq 1 ]]
grep -Fq "Refusing to revert Cilium" "$WORK/revert-guard.log"
if grep -q 'az deployment' "$TEST_CALLS"; then echo "Revert guard submitted deployment" >&2; exit 1; fi
echo "PASS: deployment-refuses-cilium-reversion"
jq '.parameters.networkDataplane.value = "cilium"' "$WORK/infra/deployment.parameters.json" > "$WORK/non-lts.parameters.json"
cp "$WORK/non-lts.parameters.json" "$WORK/infra/deployment.parameters.json"
: > "$TEST_CALLS"
status=0
TEST_DATAPLANE=cilium TEST_PLAN=AKSLongTermSupport bash "$WORK/deploy.sh" > "$WORK/lts-guard.log" 2>&1 || status=$?
[[ "$status" -eq 1 ]]
grep -Fq "Refusing to disable LTS" "$WORK/lts-guard.log"
if grep -q 'az deployment' "$TEST_CALLS"; then echo "LTS guard submitted deployment" >&2; exit 1; fi
echo "PASS: deployment-refuses-lts-downgrade"
cp "$ROOT/migrate-to-lts.sh" "$WORK/"
for case_name in lts-check-cilium lts-block-calico lts-block-stopped; do
  : > "$TEST_CALLS"
  status=0
  case "$case_name" in
    lts-check-cilium)
      expected=0
      TEST_DATAPLANE=cilium TEST_PLAN=AKSLongTermSupport TEST_TIER=Premium \
        bash "$WORK/migrate-to-lts.sh" --check-only > "$WORK/$case_name.log" 2>&1 || status=$? ;;
    lts-block-calico)
      expected=2
      bash "$WORK/migrate-to-lts.sh" --check-only > "$WORK/$case_name.log" 2>&1 || status=$? ;;
    lts-block-stopped)
      expected=1
      TEST_POWER=Stopped bash "$WORK/migrate-to-lts.sh" > "$WORK/$case_name.log" 2>&1 || status=$? ;;
  esac
  if [[ "$status" -ne "$expected" ]]; then
    cat "$WORK/$case_name.log"; echo "$case_name: expected $expected, got $status" >&2; exit 1
  fi
  if grep -Eq 'az aks (update|nodepool)|kubectl.*(scale|apply|delete)' "$TEST_CALLS"; then
    echo "$case_name: unexpected mutation" >&2; exit 1
  fi
  echo "PASS: $case_name"
done
echo "All focused migration preflight tests passed."
