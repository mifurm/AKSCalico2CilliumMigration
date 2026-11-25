# AKS Calico to Cilium migration and LTS enrollment — execution report

**Execution dates:** 24 November 2026 (network migration), updated
25 November 2026 (LTS enrollment). All execution timestamps below are UTC.  
**Scope:** Fresh deployment of the supplied minimal demonstration, followed by
the Microsoft-supported Azure CNI data-plane migration and subsequent
explicitly authorized Premium/LTS enrollment.

## Executive outcome

**Deployment, networking migration, and subsequent LTS enrollment completed
successfully.** Azure CNI Overlay now
uses **Cilium 1.18.16** instead of Calico. Kubernetes **1.35.9**, **Free**
tier and **KubernetesOfficial** support were retained during the 24 November
networking migration. On 25 November, the existing 1.35.9 cluster was enrolled
in **Premium / AKSLongTermSupport**, without changing Cilium, Overlay or the
public app IP. Final capacity remains **one node and one ready NGINX replica**.
No resource-group deletion was performed; billable resources remain running,
now with additional Premium control-plane charges.

The successful networking update took **16m 39s**. Across **548 HTTP probes**
covering migration and restoration, **zero failures were observed**;
**461** probes fell within the update-command interval, also with zero
failures. This is sampled observation, **not an availability guarantee or
proof of security-policy equivalence**. Initial implementation/preflight and
Azure-request issues were resolved and are documented below. No unresolved
execution blocker remains.

The deployed application endpoint is
**http://20.76.10.249/** (public, unauthenticated HTTP; demonstration content only).

## Follow-up: successful LTS enrollment on 25 November 2026

### Outcome and customer interpretation

The earlier managed-Calico LTS attempt had been rejected with
`LTSUnsupportedAddon`. After the supported Cilium migration, Azure accepted
the same Premium/LTS enrollment. The final live state is:

| Item | Before LTS enrollment (after startup recovery) | After enrollment |
|---|---|---|
| Kubernetes control plane / kubelet | 1.35.9 / v1.35.9 | Unchanged |
| Tier / support plan | Free / KubernetesOfficial | Premium / AKSLongTermSupport |
| Provisioning / power | Succeeded / Running | Succeeded / Running |
| Networking | Azure CNI Overlay, Cilium | Unchanged complete network profile |
| Node / app replicas | One / one | One / one |
| Public application | HTTP 200 at 20.76.10.249 | Same IP and expected response |
| Node object name, UID and addresses | Captured before update | Unchanged |
| App pod, deployment, service and policy UIDs/specifications | Captured before update | Unchanged |
| App container restart count | 0 | 0 |
| Cilium DaemonSet UID/specification | Captured before update | Unchanged |
| Node-pool configuration | Captured before update | Only the Azure `eTag` changed |
| Resource tags / automatic upgrades | Ignore / none / NodeImage | Unchanged |

This is **LTS support-plan enrollment**, not a Kubernetes minor or patch
upgrade. There is no separate `1.35 LTS` version string. No node replacement
or application restart was observed during the enrollment interval.

### Actual procedure and measured availability

1. Confirmed that the cluster used Cilium, not managed Calico.
2. Recovered the stopped cluster and validated API, node and app readiness.
3. Checked control-plane, node-pool and live kubelet versions; captured
   Azure, node, app, service, policy and Cilium snapshots.
4. Ran the enrollment with public HTTP monitoring:

```bash
# Process-local DNS setting used for this client's startup DNS-cache issue:
GODEBUG=netdns=go bash migrate-to-lts.sh
```

The script submitted:

```bash
az aks update --subscription 1217c203-6c76-47b4-b61c-9bba62dc8e02 \
  -g rg-aks-calico-support -n aks-calico-support \
  --tier premium --k8s-support-plan AKSLongTermSupport \
  --only-show-errors -o none
```

5. Verified successful Azure provisioning, Premium/LTS enrollment, unchanged
   Kubernetes patch/networking/public IP, Cilium rollout, node readiness and
   the expected app response.
6. Repeated `migrate-to-lts.sh --check-only`: exit **0**, no Azure mutation.

The Azure update ran **05:44:05–05:51:05 UTC (7m 00s)**.
The full successful script ran **05:43:52–05:51:13 UTC (7m 21s)** and exited
**0**. HTTP monitoring started before the update and continued through final
checks: **200 probes, zero observed failures**. Probes are approximately two
seconds apart plus request time and check HTTP status and the stable response
marker. This is sampled evidence, not a continuous-availability guarantee,
load test, or proof of security-policy equivalence.

### Challenges and issues affecting the procedure

- **Cluster was stopped before enrollment.** Azure showed `Stopped` with
  VM scale-set capacity zero. API DNS did not resolve and the app request
  failed. The first preflight exited before submitting an LTS update.
  The stop's origin was not investigated or attributed to this migration.
  We explicitly started the cluster using `az aks start` at approximately
  **05:38:30 UTC**. Start completed successfully; application and API recovery
  were verified before the successful enrollment.
- **DNS recovery lag on the client.** Two further preflight attempts after
  startup still failed in kubectl with `no such host`, without submitting
  an LTS update. Local/public `dig` then resolved the API to `20.76.214.64`,
  while kubectl's default resolver continued to fail. A process-local
  `GODEBUG=netdns=go` setting made kubectl work. No system DNS, hosts file,
  TLS validation or shared machine setting was modified. Production procedures
  should wait for API DNS and client resolution to recover after start.
- **Separate startup disruption from enrollment.** The app was unreachable
  while stopped; these failures are not included in the 200 enrollment probes.
  Total startup outage duration was not continuously monitored and is not
  claimed. An already-running production cluster does not need this step.
- **Premium adds charges.** The previous Free control-plane cost assumptions
  below describe the networking experiment, not the new final state.
  Premium control-plane charges now apply in addition to worker, disk,
  load-balancer, public-IP and traffic costs. No price quote is implied.
  A control-plane SLA does not make a one-node/one-replica app highly available.
- **Patch maintenance remains required.** West Europe offered 1.35.9 and
  1.35.8 as its two latest 1.35 patches at verification. No patch upgrade
  was needed. Automatic upgrades remain `none` to preserve the existing
  experiment's settings. Microsoft recommends the `patch` channel and
  supports only the latest two patches during LTS; the customer must establish
  patch maintenance or separately enable that channel and a maintenance window.
  The current published 1.35 LTS end-of-life is **31 March 2028**, subject to
  lifecycle updates and staying on supported patches.

### Code, validation and evidence

`migrate-to-lts.sh` now explicitly rejects stopped clusters and verifies
Cilium readiness, captures workload snapshots and monitors HTTP for the
enrollment. Bicep exposes explicit tier/support parameters;
`infra/deployment.parameters.json` now selects **Cilium, Premium and
AKSLongTermSupport**. `deploy.sh` verifies these configured values and refuses
an accidental LTS downgrade, as well as Cilium reversion.

Shell syntax, Bicep compilation, **13 focused mocked preflight/guard tests**,
live LTS check-only verification and Azure subscription deployment validation
all passed. The additional tests cover LTS downgrade refusal, healthy
Cilium/LTS check-only, managed-Calico rejection and stopped-cluster rejection.
HTTP helpers completed and a process check found none remaining.
No full infrastructure redeployment was necessary for enrollment.

- Successful enrollment and monitoring:
  `.local/lts-migration-20261125T054352Z-pOHuwy/`.
  Includes `outcome.log`, `before.json`, `after.json`, before/after node,
  app and Cilium snapshots, `update-start.txt`, `update-end.txt`, `http.csv`
  and `http-summary.json`.
- Initial stopped-cluster failure:
  `.local/lts-migration-20261125T053743Z-1LLLOb/`.
- Post-start resolver failures:
  `.local/lts-migration-20261125T054311Z-JdLzRS/` and
  `.local/lts-migration-20261125T054333Z-0wsZo9/`.
- Successful final check-only:
  `.local/lts-migration-20261125T055122Z-Jvnxet/`.
- [Microsoft: LTS enrollment, pricing and supported patch requirements](https://learn.microsoft.com/azure/aks/long-term-support)
- [Microsoft: AKS release and LTS lifecycle calendar](https://learn.microsoft.com/azure/aks/supported-kubernetes-versions#lts-versions)

The remaining networking-migration sections below preserve the
**24 November execution history** and its then-current Free/non-LTS baseline.

## Environment and authorization

- Subscription: `1217c203-6c76-47b4-b61c-9bba62dc8e02`.
- Resource group: `rg-aks-calico-support`, West Europe.
- Cluster: `aks-calico-support`.
- Resource-group tag verified live: `SecurityControl=Ignore`.
- Previous infrastructure was absent (`az group exists` returned `false`).
- User authorized billable deployment and networking migration, not deletion
  or Premium/LTS enrollment.
- Azure CLI **2.88.0**; kubectl **1.36.1**, compatible with this 1.35 server.

## Deployment and methodology

The existing subscription/cluster Bicep, deployment script, historical LTS
script, README and application manifests were read before changes. Official
Microsoft Learn migration documentation was fetched on the execution date.
It supports Azure CNI Overlay plus Calico to Azure CNI powered by Cilium
using CLI 2.52.0+, Linux pools and NAP disabled.

Infrastructure was deployed from code using:

```bash
bash deploy.sh
```

The underlying subscription deployment used `infra/main.bicep` and
`infra/deployment.parameters.json`, with explicit subscription, location,
resource group, cluster name, Kubernetes version and VM-size parameters.
The deployment was **Succeeded**, correlation ID
`a3f9179d-5fb6-41fa-9ef8-c10e9532ac81`.
Azure recorded **5m 37.347s** deployment duration. The complete deployment
script, including compilation, credentials, rollout, public-IP provisioning
and HTTP verification, ran **17:47:42–17:54:37 (6m 55s)**.

The new `migrate-to-cilium.sh` encapsulates eligibility checks, initial state
capture, temporary availability preparation, public HTTP monitoring, supported
update, verification, declarative reconciliation and capacity restoration.
The historical `migrate-to-lts.sh` was read but **not executed**.

Actual workflow commands:

```bash
bash -n deploy.sh migrate-to-cilium.sh migrate-to-lts.sh tests/migration-preflight.sh
bash tests/migration-preflight.sh
az bicep build --file infra/main.bicep --stdout
az deployment sub validate --subscription 1217c203-6c76-47b4-b61c-9bba62dc8e02 \
  --location westeurope --template-file infra/main.bicep \
  --parameters @infra/deployment.parameters.json
KUBECONFIG="$PWD/.local/kubeconfig" kubectl apply --dry-run=server -f k8s/sample-app.yaml
KUBECONFIG="$PWD/.local/kubeconfig" kubectl apply -f k8s/sample-app.yaml
bash migrate-to-cilium.sh --check-only
bash migrate-to-cilium.sh
# Recovery after the rejected first update, retaining its prepared capacity:
KUBECONFIG="$PWD/.local/kubeconfig" kubectl -n sample-app delete pdb migration-availability
RESTORE_NODE_COUNT=1 RESTORE_APP_REPLICAS=1 bash migrate-to-cilium.sh
```

The supported data-plane update issued by the script is:

```bash
az aks update --subscription 1217c203-6c76-47b4-b61c-9bba62dc8e02 \
  -g rg-aks-calico-support -n aks-calico-support \
  --network-dataplane cilium --network-policy cilium --only-show-errors -o none
```

No manual Calico deletion, IPAM migration, Kubernetes upgrade, LTS enrollment
or resource-group deletion is part of this workflow.

## Actual before/during/after evidence

### Timeline and cluster configuration

| Stage | UTC timestamp/window | Actual outcome |
|---|---|---|
| Initial Calico baseline | 17:58:06 | One node, one app replica; healthy HTTP |
| Initial preparation requested | 17:58:21 | Scale to two nodes and two replicas |
| First prepared snapshot | 18:00:23 | Two ready nodes; app replicas on different nodes |
| First Azure update attempt | 18:00:43–18:00:50 | Rejected: explicit Cilium policy selector required |
| Recovery script | 18:01:52–18:22:31 | Exit **0**, including preparation, verification and restoration; **20m 39s** |
| Successful retry preparation snapshot | 18:02:22 | Reused two nodes/two replicas, recreated PDB |
| Successful Azure update | 18:02:42–18:19:21 | Exit **0**, **999 seconds / 16m 39s** |
| After-migration snapshot | 18:19:29 | Succeeded; two reimaged nodes, Cilium 2/2 ready |
| Minimal-capacity restoration began | 18:19:40 | Remove PDB, replicas 2→1, nodes 2→1 |
| Final snapshot | 18:22:12 | Succeeded; one ready node, one ready app replica, Cilium 1/1 ready |
| Final read-only preflight | 18:23:42–18:24:07 | Exit 0; no Azure/workload mutation |
| Live already-Cilium rerun | 18:24:07–18:24:32 | Exit 0; reconciled declaration, no repeated migration/scaling |

Snapshots use a timestamp recorded **before** sequential API reads; they
are not atomic, simultaneous views of every object.

| Property | Initial Calico baseline | Prepared for successful retry | After migration | Final |
|---|---|---|---|---|
| Kubernetes control plane / kubelets | 1.35.9 / v1.35.9 | Same | Same | Same |
| Tier / support plan | Free / KubernetesOfficial | Same | Same | Same |
| Network plugin / IPAM mode | azure / overlay | Same | Same | Same |
| Data plane / policy engine | azure / calico | azure / calico | cilium / cilium | cilium / cilium |
| Requested pool nodes / ready app replicas | 1 / 1 | 2 / 2 | 2 / 2 | 1 / 1 |
| Pod CIDR / service CIDR | 10.244.0.0/16 / 10.0.0.0/16 | Same | Same | Same |
| DNS service IP | 10.0.0.10 | Same | Same | Same |
| App Service ClusterIP | 10.0.56.177 | Same | Same | Same |
| App public IP | 20.76.10.249 | Same | Same | Same |
| Kubernetes-native policy objects | 2 | 2 | 2; unchanged specs | 2 |
| All-namespace pod objects in snapshot | 19 | 27 | 24 | 17 |

The sample Service UID remained
`cffd9497-7ebe-4b8e-a941-9b36d91ed394`. Outbound type remained
`loadBalancer`, load-balancer SKU remained `standard`, and IPv4/CIDR/DNS
settings were unchanged. Final public-IP inventory includes the application's
**20.76.10.249** and managed outbound **57.153.45.92**, both Standard/static.
The resource-group and cluster `SecurityControl=Ignore` tags were retained.

### Node and pod identity changes

Node names below abbreviate the common prefix `aks-system-30940125-vmss`.
Full names and complete objects are retained in the JSON snapshots.

| Node | Before migration UID | After migration UID | Internal IP | Final disposition |
|---|---|---|---|---|
| `000000` | `8e2eeede-21b6-4b9d-8f26-43c10a4f438e` | `8b8a1d22-54c6-4414-a5f3-8722a75b598f` | 10.224.0.4, retained | Final single ready worker |
| `000001` | `85c1d503-5232-4193-81c4-27ef3850ad28` | `07144a8d-e3f5-44e7-adfa-20b5cc120f61` | 10.224.0.5, retained during reimage | Removed by final scale-down |
| `000002` | Not present at baseline | Surge UID `f59d45ce-ae5f-4c85-99b0-aa35a0b2b094` | 10.224.0.6 during migration | Temporary surge; absent after migration |

The original `000000` Node object was created at **17:51:53**; its replacement
was created at **18:12:00**. `000001` joined during preparation at **17:59:16**;
its replacement was created at **18:16:16**. Thus stable names/IPs did **not**
mean stable Node identity. Kubelet **v1.35.9**, OS **Ubuntu 24.04.5 LTS**,
kernel **6.8.0-1073-azure** and runtime **containerd://2.3.7-4** remained
unchanged. “LTS” in the Ubuntu OS name is **not** AKSLongTermSupport enrollment.

| App pod (prefix `sample-app-5dd9f745db-`) | UID | Pod IP | Observed placement/disposition |
|---|---|---|---|
| `kcpws` | `6c424464-612e-4036-948e-f8ffb9a97e42` | 10.244.0.254 | Initial node `000000`; replaced during migration |
| `7bw52` | `0d5e33df-990b-49c1-88e5-23116fc7b0d3` | 10.244.1.24 | Prepared node `000001`; replaced during migration |
| `bt565` | `ea3373c2-5091-4a54-93a4-d510f86d7044` | 10.244.0.192 | After-migration node `000000`; removed when replicas restored to one |
| `hc6cs` | `5a0e2789-dd01-46d1-858c-83485fccf4df` | 10.244.0.10 | After-migration and final node `000000`; ready, zero container restarts |

The app image remained `docker.io/nginxinc/nginx-unprivileged:1.28-alpine`,
with identical resolved digest
`sha256:7377697a821c131a924a7105fafbe7414db4e9fcc77a6f08f776f33f141ec3f8`.
Pod replacement/UID and IP changes occurred without an application-image
upgrade. The historic Calico heading remained intentionally as the HTTP test
marker; it does not identify the live policy engine.

### During-migration changes and availability observations

The monitor captured **68 node samples**, **68 pod samples** and **17 Azure
cluster-state samples** over migration/restoration. In the **56 node/pod
samples starting inside the update interval**, at least **two nodes were
Ready** and at least **one app pod was Ready**. Final restoration reduced
node/app readiness counts to one, as intended. No sampled zero-ready-app
state was observed; states between samples remain unknown.

The maximum registered node count was **three**, consistent with temporary
surge beyond the requested two-node preparation. Azure reported `Updating`,
data plane/policy `cilium`, and pool count three during part of the update.
A transitional networking snapshot contained Calico and
`azure-cns-transition` alongside Cilium with no ready Cilium agents yet.
Therefore the Azure `networkDataplane=cilium` field alone did **not** mean
all node reimages or policy readiness had completed.

After migration, the Calico and kube-proxy daemonsets were absent, and Cilium
was **2/2 ready**; after restoration Cilium was **1/1 ready**. Live
`cilium-dbg version` subsequently reported both client and daemon
**1.18.16**, build `143b3588c5`, matching image
`mcr.microsoft.com/containernetworking/cilium/cilium-distroless:v1.18.16-261107`.

The prepared replicas initially occupied different nodes. The
after-migration snapshot showed **both replicas on node `000000`** despite
preferred anti-affinity. This is a concrete limitation: preferred placement
does not enforce separation or automatically rebalance after drains.

| Monitoring window | UTC first/last request start | Probes | Observed failures |
|---|---|---:|---:|
| Rejected first request, including short pre/post checks | 18:00:33–18:00:53 | 10 | 0 |
| Successful migration and restoration | 18:02:32–18:22:21 (**19m 49s**) | 548 | **0** |
| Subset starting within successful Azure update | 18:02:43–18:19:20 | 461 | **0** |

Every completed probe in those windows returned HTTP **200** with the expected
body marker and curl exit 0. Maximum observed request duration was
**3.682071 seconds**; the largest interval between consecutive request starts
was **five seconds**. No observed outage interval can be reported because no
failed probe occurred. This **does not establish zero downtime**: short
interruptions, other locations, untested traffic, persistent connections and
load-dependent failures were outside the measurement.
The gap between the first monitoring window and the retry was **not
continuously monitored**; preparation included discrete healthy HTTP checks.

HTTP monitoring uses an external client on the execution workstation:
one sequential request approximately every two seconds, connection timeout
three seconds and total timeout five seconds. Each record includes UTC start
timestamp, epoch, curl exit code, HTTP status, request duration and expected
body-marker result. A successful observation requires curl exit 0, HTTP 200
and the marker. Requests do not overlap; timed-out requests lengthen the
sampling interval. This measures **observed sampled availability from one
location**, not a service SLA or proof of continuous availability.

Node and pod JSON snapshots were collected before preparation, after
preparation, during migration approximately every 15 seconds, after migration
and after restoring minimal capacity. Azure cluster state is sampled
approximately every minute during monitoring. Kubernetes API calls and Azure
queries can lengthen these intervals. UIDs, kubelet/container versions,
node/pod/service IPs, policies, daemonsets and events are retained.

## Availability preparation and cost implications

The intended default remains **one node and one NGINX replica**. Migration
temporarily requests **two Standard_D2s_v5 nodes and two app replicas**, adds
preferred cross-node pod anti-affinity and a temporary PodDisruptionBudget
(`minAvailable: 1`). After successful verification the script restores the
original node/replica counts and removes that PDB. Preferred affinity is
not strict separation and a PDB does not protect every form of disruption.

Microsoft warns that all node pools are reimaged simultaneously; migrating
individual pools independently is unsupported. Extra capacity can reduce
ordinary eviction impact but **does not guarantee uninterrupted service**.
The final one-node/one-replica application and Free control plane have no
production high-availability guarantee.

The Azure public retail-prices API returned an indicative West Europe Linux
`Standard_D2s_v5` consumption rate of **USD 0.115 per VM-hour** on the execution
date: approximately **USD 2.76/day** or **USD 83.95 per 730-hour month** for
one worker's compute alone. Two requested workers correspond to USD 0.23/hour
compute while both run. These are retail illustrations, **not the subscription's
contract price or an invoice**; discounts, currency, taxes, metering and
billing granularity can differ.

Managed 64 GiB OS disks, Standard Load Balancer, public IPs and outbound data
are additional billable resources. AKS-managed reimage/surge VMs can increase
temporary charges beyond the requested pool count. Additional replicas on
existing nodes do not themselves create a separately billed VM. Exact total
cost and transient resource billing were not measured. The Free support tier
does not make worker/network resources free.

Resources are intentionally left running; no deletion was requested.
The interval from the first preparation request to final verification was
**17:58:21–18:22:12 (23m 51s)**. If one extra worker were billed at the public
rate for that entire interval, its compute illustration would be about
**USD 0.046**, excluding surge and all other meters; this is not a measured
invoice amount. Up to three registered workers were actually observed, so
transient compute could exceed the two-worker illustration.

## Network-policy changes required when moving from Calico to Cilium

**Not every policy needs rewriting.** Cilium supports native
`networking.k8s.io/v1` `NetworkPolicy` resources, so compatible Kubernetes
policies can remain in place. However, preserving YAML does not prove that
all traffic paths retain the intended enforcement. Complete the inventory
and translation **before migration**, then validate enforcement **after
all node reimages finish**, before customer acceptance.

### Required review and conditional changes

| Existing policy or dependency | Required action |
|---|---|
| Native Kubernetes ingress/egress `NetworkPolicy` | Retain compatible manifests. Review pod/namespace labels, direction, protocols, ports and default-deny coverage; validate permitted and prohibited traffic after migration. Conversion to `CiliumNetworkPolicy` is not mandatory. |
| Calico-specific `NetworkPolicy`, `GlobalNetworkPolicy`, network sets or host endpoints | Do not assume automatic conversion. Identify the intended access controls and recreate them using native Kubernetes policies where sufficient, or supported Cilium policy resources. Calico CRDs are not enforced by the replacement Cilium engine. The demonstration script blocks custom Calico policy/set resources instead of translating them. |
| Calico rule ordering, tiers, explicit deny or host/pre-DNAT controls | Redesign rather than mechanically copy YAML. Kubernetes policies are additive allow rules; there is no equivalent ordered Calico rule list in a native `NetworkPolicy`. For advanced behavior, assess Cilium deny/clusterwide capabilities against AKS's supported feature set. Do not assume every Calico host or pre-DNAT feature has a supported one-to-one replacement. |
| `ipBlock` rules used to allow pod IPs or pod CIDRs | Change internal pod access to appropriate `namespaceSelector`/`podSelector` rules. Microsoft documents that Cilium's `ipBlock` cannot select pod or node IPs, even when the CIDR is `0.0.0.0/0`. Keep external CIDRs only where appropriate; do not broaden internal access to all pods merely to restore connectivity. |
| `ipBlock` rules used to allow node IPs | Do not retain these as an assumed node-access exception. Native `ipBlock` cannot express this allow path under AKS Cilium. Assess the specific node service and a supported host/entity or alternative network-control design; test the chosen solution before cutover. |
| Policies covering DNS and application dependencies | If egress isolation is enabled, explicitly allow the actual DNS path, including UDP/TCP 53 where required, and required backend/external destinations. Use namespace/pod selectors for CoreDNS pods. LocalDNS/node-local paths require separate review; do not assume an external-CIDR allow also permits node-local DNS. Adding egress isolation is not required simply because the engine changed. |
| LoadBalancer, NodePort or ingress-controller paths | Verify the source identity/address seen at the destination, service translation and `externalTrafficPolicy`. Explicitly allow the intended public or ingress-controller path where required and confirm unwanted sources remain denied. NPM-specific bypass behavior is not evidence of Calico behavior. |
| `hostNetwork: true` workloads | Do not assume ordinary pod policies protect these workloads. Microsoft documents that these pods use the host identity and are not covered by pod network-policy enforcement. Review host/network controls separately rather than silently relying on the old policy. |
| Named ports, port ranges (`endPort`), selectors and exceptions | Inventory their use and test against the deployed Cilium version and destination workloads. No blanket port-rule rewrite is established by this demonstration; its policy uses only numeric TCP 8080. Keep namespace-and-pod restrictions combined as intended; separate peer entries can broaden access through OR semantics. |
| FQDN or Layer-7 policies | These are not an automatic consequence of adopting Cilium. AKS supports L3/L4 `CiliumNetworkPolicy` and `CiliumClusterwideNetworkPolicy`; FQDN filtering and L7 policies require the applicable Advanced Container Networking Services configuration and eligibility. Review enablement and cost before using them as replacements. |

Update the policy source of truth in Git/IaC, deployment pipelines and
operational runbooks. Once translated policies are validated, retire custom
Calico manifests from automation so they are not reapplied after migration.
Do not bulk-delete managed system policies or CRDs simply because Calico has
been replaced; inventory ownership and dependencies first. Avoid unsupported
changes to `cilium-config` to imitate upstream features: Microsoft permits
label-exclusion configuration but does not generally support arbitrary
ConfigMap customization.

### What changed for this demonstration

- **No application-policy rewrite was necessary for the tested HTTP path.**
  The existing `sample-app/allow-http` native Kubernetes policy permits
  ingress TCP 8080 from any source to `app=sample-app`; the public service
  forwards port 80 to 8080. Its specification was preserved during both the
  networking migration and LTS enrollment.
- The app has **no egress policy**, so migration did not introduce DNS or
  outbound restrictions. This is the preserved demonstration behavior,
  not a recommended production least-privilege baseline.
- The exact AKS-managed Calico `aaa-allow-konnectivity-agent` rule was left
  for AKS-managed replacement. The native Kubernetes `konnectivity-agent`
  policy was inventoried. This managed exception must not be generalized to
  customer-created Calico policies.
- No custom Calico policies were translated and no Cilium-specific
  application policies, FQDN/L7 controls or host policies were introduced.
  Neither successful HTTP monitoring nor LTS enrollment verifies all
  security semantics.

### Customer acceptance checklist after migration

Use a representative nonproduction environment and record a test matrix
with **source, destination, port/protocol, expected allow/deny, and actual
result**, before and after migration:

1. Verify permitted traffic across namespaces/nodes to pods and ClusterIP
   services, and from public ingress to the intended application.
2. Verify prohibited sources cannot reach protected workloads. Use known
   listening destinations so an application refusing a connection is not
   mistaken for a network-policy deny.
3. Test DNS and every essential egress dependency; include any external
   CIDRs, node-local services, host-networked workloads and service paths.
4. Test selector boundaries, both TCP/UDP where used, named/ranged ports
   where present, and overlapping policies. Validate new connections after
   rollout as well as existing connections where continuity is required.
5. Correlate outcomes with available policy/drop telemetry, check for
   unintended broad allows and obtain application/security-owner sign-off.
   Keep external controls in place where continuous isolation is required.

**These additional enforcement tests were not executed in this demonstration.**
They are customer acceptance requirements/recommendations, not claimed
results. The recorded HTTP probes validate only the allowed public app path.
No live policy changes were made for this report update.

References reviewed 25 November 2026:
[Microsoft: Cilium limitations, `ipBlock`, supported policy resources and ACNS](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium)
and [Microsoft: policy engines and managed Calico support boundaries](https://learn.microsoft.com/azure/aks/use-network-policies).

## Security assessment and boundaries

The application uses a Kubernetes-native ingress NetworkPolicy allowing
TCP **8080** to pods labeled `app=sample-app` from any source. It has no
egress restriction, `ipBlock`, `endPort` or named-port policy rule. The public
Service exposes HTTP port 80 and forwards to pod port 8080.
The script inventories Kubernetes policies and rejects nonempty
custom Calico-specific policy/set objects rather than assuming automatic
translation. The fresh cluster also contained the exact AKS-managed
`aaa-allow-konnectivity-agent` GlobalNetworkPolicy (Eno-managed, order 0,
kube-system konnectivity-agent selector, allow-all egress). That specific
unchanged built-in is inventoried and left for AKS to replace; it is not
manually removed. Other or altered Calico-specific resources still block.
The baseline also contained the Kubernetes-native kube-system
`konnectivity-agent` egress policy alongside the sample application's policy.

Microsoft explicitly states **Cilium begins enforcing network policies only
after all nodes have been reimaged**. Plan for a transition interval in which
continuous or equivalent policy enforcement must not be assumed. A
healthy HTTP response only demonstrates that the allowed application path
worked; unchanged NetworkPolicy objects and healthy Cilium agents are **not
proof of deny-rule enforcement or complete security equivalence**.

No deliberate deny-traffic, DNS, pod-to-pod, node-access, egress, identity,
TLS, performance, load, failover or adversarial security tests were run.
The Microsoft NPM-to-Cilium guide describes compatibility differences that
help inform reviews; NPM-specific behavior must not be attributed to this
Calico baseline without separate evidence.

The demonstration remains publicly reachable over unencrypted,
unauthenticated HTTP, uses a public AKS API endpoint and local cluster
credentials, and retains the explicitly requested `SecurityControl=Ignore`
tag. That tag is not a security control. The container is non-root, drops
capabilities, disables privilege escalation and service-account-token
automount, and uses RuntimeDefault seccomp and resource/probe settings;
these settings are not a security certification.

## Challenges, remediation and validation

1. **ARM validation while deployment was active:** Azure returned
   `DeploymentActive` for the nested `aks-calico-cluster` deployment. No
   cancellation or deletion was attempted. Validation was rerun after initial
   deployment completed and returned **Succeeded**, with no error.
   A later Cilium-declaration validation attempted during final node-pool
   scale-down similarly returned `OperationNotAllowed` for the in-progress
   scale operation. It was retried after scale-down and **Succeeded**.
   No active operation was aborted.
2. **Initial preflight CLI-version query:** an incorrectly escaped JMESPath
   expression caused an immediate CLI argument error and exit 2 before any
   migration/scaling. The script now parses `az version -o json` with jq;
   its test stub was corrected and the preflight rerun.
3. **Fresh-cluster managed Calico policy:** the conservative initial
   custom-policy guard blocked the built-in
   `aaa-allow-konnectivity-agent`. Its complete metadata/specification and the
   corresponding native Kubernetes policy were inspected. The guard now
   recognizes only that exact managed specification while continuing to
   reject custom or modified policies. Focused positive and negative tests
   were added. No policy was manually deleted or loosened.
4. **Documented minimal command rejected by Azure:** the initial update with
   only `--network-dataplane cilium` ran **18:00:43–18:00:50** and returned
   `BadRequest: Cilium dataplane requires network policy cilium`
   (target `networkProfile.networkPolicy`). Azure still reported data plane
   `azure` and policy `calico`; two prepared nodes/replicas and the PDB
   remained. The installed CLI help explicitly supports
   `--network-policy cilium`. The implementation and retry therefore select
   both Cilium data plane and Cilium policy engine in one update, without
   changing IPAM. The leftover PDB's exact specification was checked and it
   was removed before the script recreated it. Recovery reused the already
   prepared capacity and explicitly requested final counts of one node and
   one replica. This documents a difference between the fetched Learn
   example and the actual CLI/service behavior; the underlying cause was not
   established.
5. **Bicep update advisory:** the installed compiler emitted an informational
   notice that a newer Bicep version was available. Compilation succeeded;
   no compiler upgrade was necessary.
6. **Declarative drift prevention:** the original template hard-coded
   Calico. A mandatory data-plane parameter and authoritative parameter file
   now describe the selected engine; the migration persists `cilium` after
   Azure reports the change, including after a CLI failure if Azure accepted
   it. Redeployment refuses an accidental Cilium-to-Calico reversion.

Shell syntax checks, Bicep compilation, post-deployment ARM validation and
server-side manifest dry-run passed. Nine focused mocked tests cover healthy
Calico check-only, Windows rejection, NAP rejection, CLI minimum, custom
Calico policy rejection, exact managed-policy acceptance, modified
managed-policy rejection, already-Cilium idempotent reconciliation and
deployment refusal to revert an existing Cilium cluster to Calico.
Mocks validate guards, not Azure migration behavior; live migration evidence
is reported separately above.
Final Cilium Bicep/ARM validation and manifest server-side dry-run also passed.
The final live check-only and already-Cilium rerun exited 0. The migration
script stopped its HTTP and state-sampling helpers; a process check found no
remaining migration/monitor helper. Test scratch directories were removed.

## Production recommendations

1. Schedule an approved maintenance window; test the supported migration on
   a representative nonproduction cluster and rehearse failure recovery.
   For strict continuity, consider a separate Cilium cluster and validated
   application cutover rather than relying on in-place pool reimages.
2. Provision durable multi-node, multi-replica capacity, enforce appropriate
   placement across fault domains, configure sensible PDBs and validate
   capacity/quotas, drain behavior, ingress reconvergence and rollback/cutover.
3. Translate Calico-specific policies and test an explicit allow/deny matrix
   before and after migration, including DNS, external LB/NodePort paths,
   namespace/pod selectors, egress, node IP access and connection persistence.
   Use external network controls where continuous isolation is mandatory.
4. Add TLS/authentication, restrict public exposure, adopt production identity
   and API-access controls, remove demonstration bypass tags through the
   relevant governance process, and secure local credentials.
5. Add independent synthetic monitoring, application/error metrics and
   network observability; compare multiple client locations and load levels.
6. Review version/support lifecycle, node-image updates and cost budgets.
   Cilium adoption does not itself purchase Premium/LTS or extend the
   `KubernetesOfficial` support period.

## Evidence locations and sources

- Deployment, validation, version, pricing and test records:
  `.local/run-20261124/`.
- Latest migration record directory:
  `.local/latest-cilium-records.txt`.
- Successful measured migration:
  `.local/cilium-20261124T180152Z-99608/`; contains `outcome.log`,
  `http.csv`, `http-summary.json`, `analyzed-summary.json`,
  `update-readiness-summary.json`, phase snapshots and during samples.
  `.local/run-20261124/successful-migration-records.txt` preserves this path.
  The “latest” pointer now identifies the subsequent idempotency verification,
  not the measured migration.
- Rejected first update and initial minimal baseline:
  `.local/cilium-20261124T175757Z-94055/`.
- The dedicated kubeconfig is `.local/kubeconfig` (credentials; do not share).
  Raw records remain local/ignored and should be reviewed before customer
  distribution. This report contains no kubeconfig or credential material.
- [Microsoft: supported data-plane migration, prerequisites and reimage/policy warnings](https://learn.microsoft.com/azure/aks/update-azure-cni#update-the-data-plane-to-azure-cni-powered-by-cilium)
- [Microsoft: Azure CNI powered by Cilium](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium)
- [Microsoft: NPM-to-Cilium policy review considerations](https://learn.microsoft.com/azure/aks/migrate-from-npm-to-cilium-network-policy)
- [Microsoft: AKS support policies](https://learn.microsoft.com/azure/aks/support-policies)
- [Azure retail-prices API](https://prices.azure.com/api/retail/prices)
