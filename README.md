# AKS Calico to Cilium migration demonstration

Current declarative AKS infrastructure: Kubernetes **1.35.9**, **Premium** tier,
**AKSLongTermSupport** support, Azure CNI **Overlay** powered by Cilium, one
`Standard_D2s_v5` Ubuntu node with a 64 GiB managed OS disk, and one non-root
NGINX replica exposed on public HTTP port 80. The resource group is
`rg-aks-calico-support` in West Europe with `SecurityControl=Ignore`.

See [the executed customer report](./CUSTOMER-MIGRATION-REPORT.md) for the
24 November 2026 deployment/migration evidence, measured availability,
resolved issues and production/security recommendations.

The initial configuration uses Microsoft-managed Calico network policy.
`infra/deployment.parameters.json` is the authoritative data-plane selection:
`azure` means Azure data plane plus Calico; `cilium` means Azure CNI powered
by Cilium. It also explicitly selects `skuTier` and `supportPlan`.
The networking migration updates the data-plane selection automatically. The Bicep data-plane
parameter is mandatory to prevent implicit legacy defaults, and `deploy.sh`
refuses to revert an existing Cilium cluster to Calico or disable existing LTS.

## Deploy

Requires authenticated Azure CLI **2.52.0+** with Bicep, kubectl compatible
with Kubernetes 1.35, Bash, jq, curl, Azure deployment permissions, and
registered Microsoft.ContainerService, Microsoft.Compute, and
Microsoft.Network providers.

```bash
bash deploy.sh
```

Defaults can be overridden with `SUBSCRIPTION_ID`, `LOCATION`,
`RESOURCE_GROUP`, `CLUSTER_NAME`, `KUBERNETES_VERSION` (exact 1.35 patch),
and `NODE_VM_SIZE`. Default subscription:
`1217c203-6c76-47b4-b61c-9bba62dc8e02`.

The script deploys Bicep, verifies networking/version/support/tags, applies
`k8s/sample-app.yaml`, waits for nodes, the active policy daemonset, app
rollout and public load-balancer IP, and tests the HTTP response marker.
The page's historic “AKS Calico sample is running” heading is a stable test
marker, **not** a claim about the current policy engine.

Credentials and evidence stay under ignored `.local/`; the normal kubeconfig
is not modified. Do not publish kubeconfig or raw credentials.

```bash
export KUBECONFIG="$PWD/.local/kubeconfig"
kubectl get nodes
kubectl -n sample-app get pods,services,networkpolicies
cat .local/endpoint.txt
```

## Supported Calico to Cilium migration

```bash
bash migrate-to-cilium.sh --check-only
bash migrate-to-cilium.sh
```

The script is deliberately scoped to this demonstration: one manually scaled,
healthy Linux pool; Azure CNI Overlay; NAP disabled; and Calico or Cilium.
It rejects Windows, unsupported networking, autoscaling/NAP and nonempty
Calico-specific policy/set resources requiring translation. `--check-only`
only reads live state and writes local evidence/credentials; it does not scale
or mutate the cluster. The exact AKS-managed Calico
`aaa-allow-konnectivity-agent` policy is inventoried but allowed for AKS-managed
replacement; changed specifications or other custom policies still block.
Both modes accept the same subscription/group/cluster
overrides as deployment. An already-Cilium run checks health and reconciles
the declarative selection without repeating migration.

Preparation temporarily increases a single-node/single-replica deployment to
**two nodes and two replicas**, uses preferred cross-node pod anti-affinity,
and creates a temporary PodDisruptionBudget with `minAvailable: 1`.
This increases billable compute and disk usage. **It does not guarantee
availability**: AKS reimages all pools concurrently, and a PDB protects only
evictions that respect it, not all node/network disruptions.

The supported command is:

```bash
az aks update --subscription "$SUBSCRIPTION_ID" \
  -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --network-dataplane cilium --network-policy cilium
```

AKS automatically uninstalls Calico and installs Cilium; the script never
manually deletes Calico or changes the IPAM mode. It does not enroll in LTS.
Microsoft warns that **Cilium starts enforcing policies only after all nodes
are reimaged**. Schedule a maintenance window and apply external controls if
policy-enforcement continuity is required.

The Learn example uses only `--network-dataplane cilium`. On this execution,
Azure CLI 2.88.0/the service rejected that request with “Cilium dataplane
requires network policy cilium.” The script explicitly selects the supported
`--network-policy cilium` in the same data-plane update. This does not alter
Overlay IPAM or manually uninstall Calico.

The script records:

- Before, prepared, after and final Azure/node/pod/service/policy/daemonset
  snapshots, including UIDs, versions and IPs, plus Kubernetes events.
- During-migration node/pod samples approximately every 15 seconds and Azure
  cluster-state samples approximately every minute.
- Public HTTP probes approximately every two seconds (up to five seconds
  request time), UTC timestamps, curl exit, status, latency and body marker.
  Sampling is not a continuous availability guarantee.
- Command start/end timestamps, exit codes and an outcome log.

After a successful update it checks Cilium rollout, Calico removal, app health,
unchanged Kubernetes version/support/tier/Overlay settings, unchanged Kubernetes
policy specifications and public IP. It restores the original node/replica
counts and removes the temporary PDB, while monitoring through restoration.
Results are under `.local/cilium-*`; `.local/latest-cilium-records.txt` points
to the latest run. Policy object preservation **does not establish equivalent
security enforcement**; deny/allow, DNS, egress and application-specific tests
are needed for production.

On failure the script stops monitors and exits nonzero without attempting a
networking rollback. Increased preparation capacity can remain running and
billable: inspect the live state and logs before deciding how to recover.
For recovery from an interrupted preparation, `RESTORE_NODE_COUNT` and
`RESTORE_APP_REPLICAS` can explicitly select positive final counts instead of
the current live counts. Review/remove a leftover `migration-availability`
PDB before retrying; the script refuses to overwrite an existing PDB.
If Azure reports Cilium even after a CLI error, the declarative parameters are
still reconciled to Cilium to prevent a subsequent accidental reversion.

## LTS enrollment after Cilium migration

```bash
bash migrate-to-lts.sh
bash migrate-to-lts.sh --check-only
```

The separate LTS script requires a running, healthy AKS 1.35 cluster and checks
the live kubelet, app and active policy engine. It enables the billable Premium
tier and `AKSLongTermSupport` plan without changing Kubernetes version or
networking. Calico remains blocked at preflight unless the historical explicit
`--attempt-migration` mode is used to record Azure's rejection.

The script captures before/after Azure, node, application, policy and Cilium
snapshots, timestamped update results, and public HTTP samples approximately
every two seconds under `.local/lts-migration-*`. Samples are not a guarantee
of continuous availability. It verifies the version, networking and app IP
are unchanged and provides an idempotent check of Premium/LTS enrollment.
`--check-only` does not mutate Azure/Kubernetes resources.

If the cluster is stopped, first run `az aks start` with the correct subscription,
resource group and name, and confirm app recovery before enrollment. Start-up
disruption is separate from the LTS configuration change.

Automatic upgrades remain `none` and node-image updates remain enabled.
Microsoft supports only the two latest patches in LTS; establish a manual
patch schedule or separately enable the recommended `patch` upgrade channel
with an appropriate maintenance window. LTS enrollment is not a patch upgrade.

## Validation

```bash
bash -n deploy.sh migrate-to-cilium.sh migrate-to-lts.sh
bash tests/migration-preflight.sh
az bicep build --file infra/main.bicep --stdout > .local/template.json
kubectl apply --dry-run=server -f k8s/sample-app.yaml
```

## Limitations, costs and cleanup

This is not production infrastructure: one final node/replica, public API
server, local cluster credentials, and public
unencrypted unauthenticated HTTP. The ingress policy allows TCP 8080 from
any source to app pods; no egress policy is configured. Do not serve sensitive
data. `SecurityControl=Ignore` is an explicit demonstration tag, not security
hardening. Preferred anti-affinity does not enforce fault-domain separation.

Worker VMs, managed disks, Standard Load Balancer, public IPs and outbound
traffic incur charges even with a Free control plane. Temporary migration
capacity and AKS-managed reimage/surge resources can add charges. Resources
are left running after migration. The current Premium control-plane tier
adds ongoing charges; an SLA does not make this single-replica app highly available.
Kubernetes minor automatic upgrades are
disabled; node image upgrades remain enabled. Support deadlines and
platform-mandated upgrades still apply.

Only when explicitly intended, remove the cluster, application and managed
node resource group:

```bash
az group delete --subscription 1217c203-6c76-47b4-b61c-9bba62dc8e02 \
  --name rg-aks-calico-support --yes
```

## References

- [Supported data-plane migration and warnings](https://learn.microsoft.com/azure/aks/update-azure-cni#update-the-data-plane-to-azure-cni-powered-by-cilium)
- [Azure CNI powered by Cilium](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium)
- [Network policy behavior differences](https://learn.microsoft.com/azure/aks/migrate-from-npm-to-cilium-network-policy)
- [AKS network policies](https://learn.microsoft.com/azure/aks/use-network-policies)
- [AKS support policies](https://learn.microsoft.com/azure/aks/support-policies)
