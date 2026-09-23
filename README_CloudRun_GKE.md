---
author: Gilbert Lau
date: "September 23, 2026"
versions:
  "Solo istio distro": 1.31.0
  "enterprise-agentgateway": v2026.9.0
title: "WIT Identity Propagation from a Real Google Cloud Run Workload (Dedicated Ztunnel Sidecar, GKE Multi-Cluster)"
---

# WIT Identity Propagation: workload-a1 (real Cloud Run) → Agentgateway Egress → Agentgateway PIG Gateway → Agentgateway Waypoint → workload-B

## Overview

This doc extends [README_GKE.md](./README_GKE.md): same three zonal GKE clusters on a shared VPC, same mesh and agentgateway setup, reused verbatim. The difference is **`workload-a1`**. Instead of an ambient pod in a cluster, it's an **actual Google Cloud Run Job** with a dedicated ztunnel sidecar container, running outside GKE entirely.

That change brings real constraints. An in-cluster pod is a `kubectl exec`-able process with a kubelet, a CNI, iptables capture and a pod IP on the cluster network. A Cloud Run instance has none of those. Read the constraints table below before running anything; it explains every place this doc's design differs from a normal in-cluster workload, and why.

> **Related:** for a local simulation of this setup on Kind (a pod standing in for Cloud Run), see [README_CloudRun_Kind.md](./README_CloudRun_Kind.md).

This design joins a real Cloud Run Job, with a dedicated ztunnel sidecar, to the ambient mesh via `remote: false` bootstrap registration. Routing uses mesh-internal DNS names (`*.mesh.internal`) resolved by name through the SOCKS5 proxy — no `ServiceEntry` needed — the same pattern our own `portfolio-b-pig.i-pig.mesh.internal` / `workload-b1.demo.mesh.internal` hostnames already use elsewhere in this doc series.

This configuration requires three non-default settings, each verified against a live run and described in §4.1, §4.2, §5.0 and [Troubleshooting](#troubleshooting):
  1. **`remote: false`** in the bootstrap JSON. `remote: true` forces double-HBONE through the east-west gateway, and agentgateway's HBONE listener rejects the hostname-addressed inner CONNECT that produces.
  2. **`ENABLE_WORKLOAD_CLAIMS=true`** on the ztunnel sidecar. Without it, traffic flows but `workload-a1` never attaches a WIT, so `wpt-cel-egress` becomes the chain's origin.
  3. **`solo.io/service-scope: global`** on `wpt-cel-egress`. Without it, there is no `wpt-cel-egress.i-peg.mesh.internal` name to resolve.

> **Status: verified end to end** on 2026-09-23 (Cloud Run execution `workload-a1-7sj7x`). `workload-b1` returned `200 OK`, `X-Forwarded-Workload-Identity` starts with `spiffe://cluster.local/ns/demo/sa/workload-a1`, and the `X-Original-Workload-Identity-Token` has `sub: spiffe://cluster.local/ns/demo/sa/workload-a1`.

**Full traffic path:**
```
workload-a1 (real Cloud Run Job, dedicated ztunnel sidecar) → (Direct VPC Egress, SOCKS5 → HBONE direct to pod IP) → wpt-cel-egress → (east-west) → portfolio-b-pig → (east-west) → demo-waypoint → workload-b1
```

**Cluster / project layout** (identical to README_GKE.md):
- Project: `field-engineering-us`, region `us-central1`, shared VPC `solo-vpc`
- `glau-cluster-1` (`us-central1-a`) — `portfolio-b-pig`, `i-pig` namespace
- `glau-cluster-2` (`us-central1-b`) — `wpt-cel-egress`, `demo`/`i-peg`/`i-pig` namespaces, **plus the existing `istio-eastwest` gateway this doc reuses**
- `glau-cluster-3` (`us-central1-c`) — `demo-waypoint`, `workload-b1`, `demo` namespace
- **New:** `workload-a1` — a Cloud Run Job in `us-central1`, connected via Direct VPC Egress, with no presence in any GKE cluster at all

### Real Cloud Run constraints, and how this lab adapts to them

| # | Constraint | What an in-cluster pod relies on | Adaptation in this doc |
|---|---|---|---|
| 1 | **No privileged containers, no `NET_ADMIN`/`NET_RAW`.** Confirmed in Cloud Run's own [container runtime contract](https://docs.cloud.google.com/run/docs/container-contract): "Cloud Run doesn't support privileged containers," full stop — even on the gen2 execution environment. | Traffic capture into ztunnel is done with iptables rules (set up by the Istio CNI, or by `iptables` init containers for a sidecar). That's impossible without `NET_ADMIN`. | The `app` container talks to the ztunnel sidecar **explicitly** instead of being transparently captured: it sets `ALL_PROXY=socks5h://127.0.0.1:15080`, ztunnel's own local SOCKS5 listener in dedicated mode (§4.2). No iptables involved at all. |
| 2 | **No kubelet, no projected `serviceAccountToken`.** Cloud Run has no Kubernetes control plane underneath it at all. | The workload's mesh identity comes from a kubelet-managed, auto-rotated projected token (`audience: istio-ca`) — a Kubernetes-only mechanism. | A `kubectl create token ... --audience=istio-ca` token (Kubernetes caps its actual lifetime at 48h regardless of the requested duration) gets folded into a single **bootstrap JSON** blob (URL, root CA cert, namespace, SA, network, token), double base64-encoded and stored as one Secret Manager secret, mounted into the ztunnel sidecar as `BOOTSTRAP_TOKEN` (§4.1). This is static and does **not** auto-rotate — regenerate and re-version it before 48h is up. |
| 3 | **No stable pod IP, no `kubectl exec`.** Cloud Run instances are ephemeral, autoscaled, and there is no shell to exec into. | istiod registers the pod by its IP, and you verify with `kubectl exec ... curl`. | `workload-a1` runs as a **Cloud Run Job** (2026 GA added multi-container/sidecar support to Jobs), not a Service — it runs to completion once per execution, which maps cleanly onto "run one curl, look at the output," the same role `kubectl exec` played before. No `WorkloadEntry` is created at all — see #5. |
| 4 | **No shared pod network with the GKE clusters.** Cloud Run and GKE are entirely separate compute planes. | The pod reaches `wpt-cel-egress` via plain in-cluster Kubernetes DNS/ClusterIP. | `workload-a1` connects through **Direct VPC Egress** into `solo-vpc` (§3.0), and uses two paths from there. **Control plane:** XDS and certificates go through cluster-2's existing `istio-eastwest` gateway on port 15012 (already provisioned by §1.0/§1.2, so no new load balancer is needed). **Data plane:** HBONE goes straight to the destination pod IP on `:15008`, not through the gateway (`remote: false`, §4.1). |
| 5 | **No `SO_ORIGINAL_DST` without iptables, no `WorkloadEntry`.** Ambient's normal client-side ztunnel decides whether to HBONE-wrap a connection by looking up the *original* destination the kernel redirected — that signal only exists because of the iptables `REDIRECT` rule, and normal ambient pods get auto-registered by the CNI, not manually. | Nothing redirects traffic into the dedicated ztunnel here, and there's no CNI to auto-register it. | Neither problem needs solving by hand: ztunnel's **local SOCKS5 proxy** takes the destination `host:port` directly from the SOCKS5 protocol (no `SO_ORIGINAL_DST` needed — the app names its target explicitly), resolving `*.mesh.internal` names against the workload registry it already gets from istiod's XDS. No `WorkloadEntry` is needed either: the bootstrap runs ztunnel against a synthetic local workload, and the bootstrap's `remote` field is deliberately `false` so ztunnel dials `wpt-cel-egress`'s pod IP directly over the shared VPC (see §4.1). |

The downstream chain (`wpt-cel-egress` → `portfolio-b-pig` → `demo-waypoint` → `workload-b1`) uses the same pattern and enforcement policies as [README_GKE.md](./README_GKE.md). Only `workload-a1` and how it joins the mesh differ.

**Key concepts (new in this doc):**
- **Bootstrap JSON:** the real off-cluster onboarding format `PROXY_MODE=dedicated` ztunnel actually consumes when there's no Kubernetes control plane underneath it — a single JSON document (`url`, `caCert`, `namespace`, `serviceAccount`, `network`, `remote: false`, `token`), double base64-encoded, delivered as one env var (`BOOTSTRAP_TOKEN`) rather than as separate mounted files.
- **Ztunnel's local SOCKS5 proxy (`127.0.0.1:15080`):** what a dedicated ztunnel exposes *instead of* transparent iptables capture. The app names its real destination explicitly (`ALL_PROXY=socks5h://...`, the trailing `h` meaning "resolve the hostname through the proxy, not locally") and ztunnel originates the authenticated HBONE connection on its behalf — this is the real answer to "how does a dedicated ztunnel know its destination without `SO_ORIGINAL_DST`."
- **Direct VPC Egress:** Cloud Run instances get an IP directly from a dedicated subnet (`solo-subnet-cloudrun`) and reach `solo-vpc` with no separate bridging resource — no managed instance pool to provision (3-5 minutes for a connector) or pay for while idle. This is a deliberate choice over the older **Serverless VPC Access connector** mechanism — functionally equivalent for this lab's purposes, with lower cost and no provisioning wait.
- **`istio-eastwest` gateway reuse:** the multicluster east-west gateway §1.0/§1.2 already stand up (to link the three GKE clusters) also exposes istiod's XDS/CA port (15012). Cloud Run uses it **only for the control plane**, so no second load balancer is needed. Data-plane traffic does *not* go through it: with `remote: false`, the Cloud Run ztunnel dials `wpt-cel-egress`'s pod IP on `:15008` directly over the shared VPC.
- **What the bootstrap sets for you:** `BOOTSTRAP_TOKEN` alone makes ztunnel set `PROXY_MODE=dedicated`, `PROXY_WORKLOAD_INFO`, `POD_NAMESPACE`, the XDS/CA addresses and root cert, and the SOCKS5 listener. None of them need to be set by hand (nor `PACKET_MARK`, which only matters with iptables capture). The one setting it does **not** turn on is `ENABLE_WORKLOAD_CLAIMS` (§4.2).
- Everything else (WIT, WPT, `SourceDelegation`, `PeerBound`) works as in [README_GKE.md](./README_GKE.md); see that doc's Key concepts for what this one builds on.

> **Alpha feature:** WIMSE WIT/WPT support is in alpha and not production-ready. See README_GKE.md's mode-correction note for `workloadIdentity.mode` — the same applies here.

---

## 1.0 Shared infrastructure (identical to README_GKE.md)

Everything through installing `enterprise-agentgateway` is unchanged from README_GKE.md. Run these exactly as written there before continuing.

**Additional tools needed for this doc:** `jq`, for building the bootstrap JSON in §4.1 (`brew install jq` / `apt-get install jq`); `crane`, for copying the ztunnel image into your own Artifact Registry in §4.2 (`brew install crane`, or see [go-containerregistry releases](https://github.com/google/go-containerregistry/releases)).

### 1.1 Create the GKE Clusters

Create three zonal GKE clusters in `us-central1` on a shared VPC:

```bash
./data/setup-3-3n-gke-clusters.sh
```

This creates `glau-cluster-1` (`us-central1-a`), `glau-cluster-2` (`us-central1-b`), and `glau-cluster-3` (`us-central1-c`), each with 3 worker nodes, on the shared VPC `solo-vpc` with pod CIDRs `10.10/16`, `10.20/16`, and `10.30/16`, plus the `solo-allow-cross-cluster` firewall rule permitting cross-cluster pod traffic.

### 1.2 Install the Ambient Mesh

```bash
./data/setup-ambient-mc-fn3-3-worker-node-gke.sh
```

### Initialize Environment Variables

```bash
export ISTIO_VERSION=1.31.0
export ISTIO_IMAGE=${ISTIO_VERSION}-solo
export REPO=us-docker.pkg.dev/soloio-img/istio
export HELM_REPO=us-docker.pkg.dev/soloio-img/istio-helm

export REMOTE_CLUSTER1="glau-cluster-1"
export REMOTE_CLUSTER2="glau-cluster-2"
export REMOTE_CLUSTER3="glau-cluster-3"
export PROJECT_ID="field-engineering-us"
export CLUSTER1_ZONE="us-central1-a"
export CLUSTER2_ZONE="us-central1-b"
export CLUSTER3_ZONE="us-central1-c"
export REGION="us-central1"
export REMOTE_CONTEXT1="gke_${PROJECT_ID}_${CLUSTER1_ZONE}_${REMOTE_CLUSTER1}"
export REMOTE_CONTEXT2="gke_${PROJECT_ID}_${CLUSTER2_ZONE}_${REMOTE_CLUSTER2}"
export REMOTE_CONTEXT3="gke_${PROJECT_ID}_${CLUSTER3_ZONE}_${REMOTE_CLUSTER3}"
export NETWORK="flat-network"
export VPC_NETWORK="solo-vpc"
```

### Verify Cluster Connectivity

```bash
export PATH=${HOME}/.istioctl/bin:${PATH}

istioctl multicluster check --contexts="$REMOTE_CONTEXT1,$REMOTE_CONTEXT2,$REMOTE_CONTEXT3"
```

### Create Namespaces

```bash
kubectl --context $REMOTE_CONTEXT1 create namespace i-pig
kubectl --context $REMOTE_CONTEXT1 label namespace i-pig istio.io/dataplane-mode=ambient

kubectl --context $REMOTE_CONTEXT2 create namespace demo
kubectl --context $REMOTE_CONTEXT2 label namespace demo istio.io/dataplane-mode=ambient

kubectl --context $REMOTE_CONTEXT3 create namespace demo
kubectl --context $REMOTE_CONTEXT3 label namespace demo istio.io/dataplane-mode=ambient
```

### 2.0 Install Enterprise Agentgateway

```bash
export AGENTGATEWAY_VERSION=v2026.9.0
```

**cluster-1** (portfolio-b-pig):
```bash
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT1} \
  -n agentgateway-system \
  --create-namespace

helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT1} \
  --set licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY} \
  --set istio.autoEnabled=true \
  --set istio.clusterId=${REMOTE_CLUSTER1} \
  --set istio.network=flat-network \
  -n agentgateway-system
```

**cluster-2** (wpt-cel-egress):
```bash
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT2} \
  -n agentgateway-system \
  --create-namespace

helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT2} \
  --set licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY} \
  --set istio.autoEnabled=true \
  --set istio.clusterId=${REMOTE_CLUSTER2} \
  --set istio.network=flat-network \
  -n agentgateway-system
```

**cluster-3** (demo-waypoint):
```bash
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT3} \
  -n agentgateway-system \
  --create-namespace

helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT3} \
  --set licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY} \
  --set istio.autoEnabled=true \
  --set istio.clusterId=${REMOTE_CLUSTER3} \
  --set istio.network=flat-network \
  -n agentgateway-system
```

Verify GatewayClasses on all three clusters:
```bash
kubectl --context $REMOTE_CONTEXT1 get gatewayclass | grep enterprise-agentgateway
kubectl --context $REMOTE_CONTEXT2 get gatewayclass | grep enterprise-agentgateway
kubectl --context $REMOTE_CONTEXT3 get gatewayclass | grep enterprise-agentgateway
```

Expected on each:
```
enterprise-agentgateway            solo.io/enterprise-agentgateway   True
enterprise-agentgateway-waypoint   solo.io/enterprise-agentgateway   True
```

---

## 2.0 Reuse the existing east-west gateway for Cloud Run reachability

The multicluster setup in §1.0/§1.2 already stood up an `istio-eastwest` gateway on every cluster (via `istioctl multicluster expose --namespace istio-eastwest`, see `data/setup-ambient-mc-fn3-3-worker-node-gke.sh`), exposing istiod's XDS (15012) and HBONE (15008) ports so the clusters can link to each other. Cloud Run can reuse it too, so no separate load balancer is required. In this doc, Cloud Run only uses its **15012** port (istiod XDS + CA, via the bootstrap `url`). Data-plane HBONE goes straight to the destination pod IP instead of through the gateway's 15008 port (see the `remote: false` note in §4.1).

**Get cluster-2's east-west gateway IP:**

```bash
kubectl --context $REMOTE_CONTEXT2 get gateway istio-eastwest -n istio-eastwest
kubectl --context $REMOTE_CONTEXT2 get pods -n istio-eastwest
kubectl --context $REMOTE_CONTEXT2 get svc -n istio-eastwest -o wide

export EW_GATEWAY_IP=$(kubectl --context $REMOTE_CONTEXT2 get svc -n istio-eastwest \
  -o jsonpath='{.items[?(@.metadata.labels.istio=="eastwest")].status.loadBalancer.ingress[0].ip}')

if [ -z "$EW_GATEWAY_IP" ]; then
  export EW_GATEWAY_IP=$(kubectl --context $REMOTE_CONTEXT2 get svc -n istio-eastwest \
    -o json | jq -r '.items[] | select(.metadata.name | contains("eastwest")) | .status.loadBalancer.ingress[0].ip' | head -1)
fi

echo "East-West Gateway IP (cluster-2): ${EW_GATEWAY_IP}"
```

`istioctl multicluster expose` provisions a standard (public) LoadBalancer by default, so this may well be a real external IP rather than an internal `10.x` one — that's fine, Cloud Run's Direct VPC Egress (§3.0) still routes to it privately through the VPC rather than over the public internet, regardless of whether the gateway happens to be internal or external.

---

## 3.0 Cloud Run networking prerequisites

**Create a dedicated Direct VPC Egress subnet**, in the same VPC and region as the GKE clusters, on a CIDR that doesn't overlap the pod/node/service ranges already in use (`10.10/16`–`10.30/16`, plus the `10.100–10.102.0.0/22` node ranges and `10.255.x.0/24` service ranges from `data/setup-3-3n-gke-clusters.sh`). Cloud Run instances draw their IPs directly from this subnet — there's no separate connector resource to provision:

```bash
gcloud compute networks subnets create solo-subnet-cloudrun \
  --project=${PROJECT_ID} \
  --network=${VPC_NETWORK} \
  --region=${REGION} \
  --range=10.103.0.0/26
```

**Allow that subnet to reach the GKE nodes** (matches every one of the three clusters' node network tags, or repeat per cluster if your node tags differ):

```bash
gcloud compute firewall-rules create solo-allow-cloudrun-to-mesh \
  --project=${PROJECT_ID} \
  --network=${VPC_NETWORK} \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp,udp,icmp \
  --source-ranges=10.103.0.0/26
```

**Allow cluster-2's istiod to accept the token type this bootstrap flow generates:**

```bash
kubectl --context $REMOTE_CONTEXT2 set env deployment/istiod -n istio-system REQUIRE_3P_TOKEN=false
kubectl --context $REMOTE_CONTEXT2 rollout status deployment/istiod -n istio-system
```

---

## 4.0 Deploy workloads

### 4.1 Bootstrap `workload-a1`'s mesh identity for Cloud Run

Unlike an in-cluster pod, there's no kubelet here to project a rotating token. The real mechanism is a single **bootstrap JSON** blob — not the separate `istio-token`/`root-cert.pem` files a genuine off-cluster VM would use — delivered to the ztunnel sidecar as one env var.

**`workload-a1`'s service account already exists** from README_GKE.md-style setup — it lives in the `demo` namespace on cluster-2, giving it the identity `spiffe://cluster.local/ns/demo/sa/workload-a1`, consistent with every other doc in this series. (`demo` fits this role since no Cloud Run pod ever actually runs inside the cluster — the namespace exists purely to provide identity.)

```bash
kubectl --context $REMOTE_CONTEXT2 create serviceaccount workload-a1 -n demo
```

**Generate a Kubernetes SA token with the `istio-ca` audience.** Kubernetes will cap the actual lifetime at 48h regardless of `--duration`:

```bash
export K8S_TOKEN=$(kubectl --context $REMOTE_CONTEXT2 create token workload-a1 \
  -n demo --audience=istio-ca --duration=87600h)

echo "Token generated (length: ${#K8S_TOKEN})"
```

**Build the bootstrap JSON**, pointed at cluster-2's east-west gateway from §2.0:

```bash
kubectl --context $REMOTE_CONTEXT2 get configmap istio-ca-root-cert -n istio-system -o json | \
jq --arg url "https://${EW_GATEWAY_IP}:15012" \
   --arg ns "demo" \
   --arg sa "workload-a1" \
   --arg network "flat-network" \
   --arg token "${K8S_TOKEN}" \
   '{
     url: $url,
     caCert: .data."root-cert.pem",
     namespace: $ns,
     serviceAccount: $sa,
     network: $network,
     remote: false,
     token: $token
   }' > bootstrap-workload-a1.json

cat bootstrap-workload-a1.json | jq '{url, namespace, serviceAccount, network, remote, token: (.token[:50] + "...")}'
```

**Double base64-encode it** — this must use `openssl base64 -A` (no trailing newlines), not plain `base64`:

```bash
export BOOTSTRAP_TOKEN=$(cat bootstrap-workload-a1.json | openssl base64 -A | openssl base64 -A)
echo "Bootstrap token length: ${#BOOTSTRAP_TOKEN}"
```

**Store it in Secret Manager** and grant the Cloud Run job's runtime service account access:

```bash
echo -n "${BOOTSTRAP_TOKEN}" | gcloud secrets create workload-a1-bootstrap-token \
  --project=${PROJECT_ID} --data-file=- --replication-policy=automatic

export CLOUDRUN_RUNTIME_SA=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')-compute@developer.gserviceaccount.com

gcloud secrets add-iam-policy-binding workload-a1-bootstrap-token \
  --project=${PROJECT_ID} \
  --member="serviceAccount:${CLOUDRUN_RUNTIME_SA}" \
  --role="roles/secretmanager.secretAccessor"
```

> **Rotation:** this token is static and Kubernetes caps it at 48h — it does **not** auto-refresh the way an in-cluster pod's kubelet-projected token does. Re-run this section and add a new secret version before it expires.
>
> **No `WorkloadEntry` is created, and none is expected.** With no `platform` field, ztunnel's bootstrap (`src/config/bootstrap.rs`) runs in dedicated mode against a *synthetic local* workload (`LOCAL_XDS`, uid `local`) built from the token's namespace/SA — istiod never registers it. Its absence is not a failure signal. `remote` does something else entirely. It is covered in the next note.
>
> **`remote` must be `false` here.** `remote: true` sets `ALWAYS_TRAVERSE_NETWORK_GATEWAY=true`, so every outbound request is double-HBONE'd through the east-west gateway. The inner CONNECT then carries a *hostname* (`wpt-cel-egress.i-peg.mesh.internal:8080`), and agentgateway's HBONE listener only accepts `IP:port` targets. It rejects the request with `hbone failed: hostname resolution not supported` (`crates/agentgateway/src/proxy/gateway.rs`), which the Cloud Run ztunnel reports as `error="http status: 400 Bad Request"` against `dst.workload="NetworkGateway/flat-network/..."`. Ordinary ambient pods' ztunnel inbound *does* accept hostnames, so this specific failure is unique to a Gateway-fronted destination reached via a dedicated Cloud Run ztunnel. The gateway detour isn't needed anyway: Cloud Run sits on `solo-vpc` via Direct VPC Egress, is on the same `flat-network`, and GKE pod IPs are VPC-routable. With `remote: false`, ztunnel sends single HBONE straight to the pod's `:15008` with an `IP:port` authority. XDS/CA still go through the east-west gateway's `:15012`, via `url`.

### 4.2 Deploy `workload-a1` as a real Cloud Run Job (dedicated ztunnel sidecar)

**Copy the mesh's ztunnel image into your own Artifact Registry.** Cloud Run needs to pull it from a registry in your project — don't assume Cloud Run can pull directly from Solo's registry:

```bash
export ZTUNNEL_TAG=1.31.0-solo-distroless
export ZTUNNEL_IMAGE=us-docker.pkg.dev/soloio-img/istio/ztunnel:${ZTUNNEL_TAG}
export CLOUDRUN_ZTUNNEL_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/istio-images/ztunnel:${ZTUNNEL_TAG}"

echo "copying ${ZTUNNEL_IMAGE} -> ${CLOUDRUN_ZTUNNEL_IMAGE}"
crane copy ${ZTUNNEL_IMAGE} ${CLOUDRUN_ZTUNNEL_IMAGE}
```

> **Why `crane`, not Cloud Build:** a registry-to-registry copy is all this step needs — `crane copy` (part of [`go-containerregistry`](https://github.com/google/go-containerregistry), `brew install crane`) does it directly over the registry API using your own `gcloud` credentials, no Cloud Build job required. It also only needs `artifactregistry.writer` (push/pull on an existing repo) — not `roles/cloudbuild.builds.editor`, and not `roles/artifactregistry.admin` unless the `istio-images` repo doesn't exist yet and the `create` above actually needs to succeed.

**Deploy the job.** Two containers share the job's network namespace over `localhost`, per Cloud Run's sidecar model. `run.googleapis.com/container-dependencies` starts `ztunnel` first; `app` never gets iptables-redirected (Cloud Run forbids that — see the constraints table above), so it reaches the mesh through ztunnel's local **SOCKS5 proxy** (`127.0.0.1:15080`) instead, naming its real destination explicitly via `ALL_PROXY`:

```bash
cat > workload-a1-job.yaml <<EOF
apiVersion: run.googleapis.com/v1
kind: Job
metadata:
  name: workload-a1
spec:
  template:
    metadata:
      annotations:
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/container-dependencies: '{"app":["ztunnel"]}'
        run.googleapis.com/network-interfaces: '[{"network":"${VPC_NETWORK}","subnetwork":"solo-subnet-cloudrun"}]'
        run.googleapis.com/vpc-access-egress: private-ranges-only
    spec:
      template:
        spec:
          containers:
          - name: app
            image: curlimages/curl:latest
            command: ["/bin/sh"]
            args:
            - -c
            - |
              echo "Testing workload-a1 -> wpt-cel-egress -> ... -> workload-b1"
              curl -si --max-time 15 http://wpt-cel-egress.i-peg.mesh.internal:8080/workload-b1/headers
            env:
            - name: ALL_PROXY
              value: "socks5h://127.0.0.1:15080"
          - name: ztunnel
            image: ${CLOUDRUN_ZTUNNEL_IMAGE}
            startupProbe:
              httpGet:
                path: /healthz/ready
                port: 15021
              initialDelaySeconds: 1
              periodSeconds: 2
              failureThreshold: 30
            env:
            - name: BOOTSTRAP_TOKEN
              valueFrom:
                secretKeyRef:
                  name: workload-a1-bootstrap-token
                  key: "latest"
            - name: RUST_LOG
              value: "info"
            - name: ENABLE_WORKLOAD_CLAIMS
              value: "true"
            resources:
              limits:
                cpu: "500m"
                memory: 512Mi
EOF

gcloud run jobs replace workload-a1-job.yaml --project=${PROJECT_ID} --region=${REGION}
```

> **Two real bugs fixed here, verified against the live API:**
> 1. **Schema nesting.** A Cloud Run **Job**'s container spec is one level deeper than a Cloud Run *Service*'s: `spec.template.spec.template.spec.containers`, not `spec.template.spec.containers` (only the outer `spec.template.metadata.annotations` sits where a Service's does). Using the Service-shaped nesting fails with `Failed to parse value(s) in protobuf [Job]: Job.spec.template.spec.containers`.
> 2. **`container-dependencies` requires a startup probe** on the container being depended on — without one, `gcloud run jobs replace` fails at deploy time with `Dependent container 'ztunnel' must have startup probe specified`. The `startupProbe` above reuses ztunnel's own readiness endpoint (`:15021/healthz/ready`).

> **`ENABLE_WORKLOAD_CLAIMS=true` is required for WIT propagation**, and it's easy to leave out if the sidecar's env is just `BOOTSTRAP_TOKEN` + `RUST_LOG`. It defaults to `false`, and the bootstrap doesn't set it. Without it, the request still succeeds with `200 OK`, but `workload-a1` never attaches a WIT to its HBONE connection. `wpt-cel-egress` then mints the first WIT itself, so `X-Forwarded-Workload-Identity` starts at `wpt-cel-egress` and `workload-a1` is missing from the chain. Check the ztunnel startup log for `enableWorkloadClaims: true`.

> This doc always sets `ALL_PROXY` on the `app` container, since without it `curl` has no way to reach anything through the sidecar at all.
>
> **"failed to set netns" in ztunnel logs is expected and harmless on Cloud Run** — ztunnel continues running in a mode compatible with Cloud Run's sandboxing constraints.

This only *registers* the job — don't execute it yet. Its `curl` target (`wpt-cel-egress.i-peg.mesh.internal:8080/workload-b1/headers`) exercises the full downstream chain, which doesn't exist until §5.0–§7.0 below are all applied; executing now would just fail or time out. Unlike an in-cluster pod, where `kubectl exec ... curl <anything>` lets you probe each intermediate hop on demand, this Cloud Run Job's request is fixed in its YAML — probing an intermediate hop means editing the `app` container's `args` and re-running `gcloud run jobs replace`. This doc validates the whole chain once, at the end of §7.0.

### 4.3 Deploy workload-b1 (cluster-3)

```bash
kubectl --context $REMOTE_CONTEXT3 apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-b1
  namespace: demo
---
apiVersion: v1
kind: Service
metadata:
  name: workload-b1
  namespace: demo
  labels:
    app: workload-b1
    service: workload-b1
    solo.io/service-scope: global
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 8080
  selector:
    app: workload-b1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workload-b1
  namespace: demo
  labels:
    app: workload-b1
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: workload-b1
      version: v1
  template:
    metadata:
      labels:
        app: workload-b1
        version: v1
    spec:
      serviceAccountName: workload-b1
      containers:
      - image: docker.io/mccutchen/go-httpbin:2.25.0
        imagePullPolicy: IfNotPresent
        name: workload-b1
        ports:
        - containerPort: 8080
        env:
        - name: SRV_MAX_HEADER_BYTES
          value: "131072"
EOF

kubectl --context $REMOTE_CONTEXT3 wait --for=condition=available deploy/workload-b1 -n demo --timeout=90s
```

---

## 5.0 Stand up `wpt-cel-egress`

```bash
kubectl --context $REMOTE_CONTEXT2 create namespace i-peg

kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: wpt-cel-egress-params
  namespace: i-peg
spec:
  workloadClaims:
    enabled: true
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: wpt-cel-egress-emit
  namespace: i-peg
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: wpt-cel-egress
  backend:
    workloadIdentity:
      mode: SourceDelegation
      emitProof: true
      proofLifetime: 60s
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: wpt-cel-egress
  namespace: i-peg
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    labels:
      networking.istio.io/tunnel: "http"
      solo.io/service-scope: global
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: wpt-cel-egress-params
  listeners:
  - name: hbone
    port: 15008
    protocol: HBONE
  - name: http
    port: 8080
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF
```

> **`solo.io/service-scope: global` is required here**, not optional. Only global-scoped services get a `<name>.<namespace>.mesh.internal` hostname; without the label, ztunnel only knows this service as `wpt-cel-egress.i-peg.svc.cluster.local`, and the Cloud Run sidecar's SOCKS5 lookup fails with `HostUnreachable: dns lookup: ... no records found for Query { name: Name("wpt-cel-egress.i-peg.mesh.internal.") ... }`. (README_GKE.md never needed it because their clients used plain cluster DNS.) Setting it via `infrastructure.labels` makes agentgateway stamp it onto the generated Service.

No load balancer is needed for `wpt-cel-egress` itself: once it exists, cluster-2's istiod publishes it to every workload's XDS view (including `workload-a1`'s dedicated ztunnel, once it connects via §4.1's bootstrap), and `workload-a1`'s `curl` reaches it by its mesh-internal DNS name (`wpt-cel-egress.i-peg.mesh.internal:8080`) through ztunnel's SOCKS5 proxy — the same `<name>.<namespace>.mesh.internal` convention already used for `portfolio-b-pig.i-pig.mesh.internal` and `workload-b1.demo.mesh.internal` in §6.0 below. Its actual route to `workload-b1` is added there, once `portfolio-b-pig` exists to route to.

---

## 6.0 Set up `workload-a1 (real Cloud Run) → wpt-cel-egress → portfolio-b-pig → workload-b1`

Create dummy `demo` namespace to allow backendRefs to `kind: Hostname` (`workload-b1.demo.mesh.internal`) to resolve in the HTTPRoute above:
```bash
kubectl --context $REMOTE_CONTEXT1 create namespace demo
kubectl --context $REMOTE_CONTEXT1 label namespace demo istio.io/dataplane-mode=ambient
```

```bash
kubectl --context $REMOTE_CONTEXT1 create namespace i-pig

kubectl --context $REMOTE_CONTEXT1 label namespace i-pig istio.io/dataplane-mode=ambient --overwrite

kubectl --context $REMOTE_CONTEXT1 apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: portfolio-b-pig-params
  namespace: i-pig
spec:
  workloadClaims:
    enabled: true
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: portfolio-b-pig
  namespace: i-pig
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    labels:
      security.istio.io/tlsMode: "istio"
      solo.io/service-scope: global
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: portfolio-b-pig-params
  listeners:
  - name: hbone
    port: 15008
    protocol: HBONE
  - name: mtls
    port: 8080
    protocol: HTTPS
    tls:
      mode: Terminate
      options:
        gateway.istio.io/tls-terminate-mode: ISTIO_MUTUAL
    allowedRoutes:
      namespaces:
        from: All
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: portfolio-b-pig-enforce
  namespace: i-pig
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: portfolio-b-pig
  traffic:
    entWptEnforcement:
      mode: "PeerBound"
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: portfolio-b-pig-emit
  namespace: i-pig
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: portfolio-b-pig
  backend:
    workloadIdentity:
      mode: SourceDelegation
      emitProof: true
      proofLifetime: 60s
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: portfolio-b-pig-h2
  namespace: i-pig
spec:
  targetRefs:
  - {group: gateway.networking.k8s.io, kind: Gateway, name: portfolio-b-pig}
  frontend:
    http: {http2MaxHeaderSize: 64Ki}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: portfolio-b-pig-to-workload-b1
  namespace: demo
spec:
  parentRefs:
  - name: portfolio-b-pig
    namespace: i-pig
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /workload-b1
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - group: networking.istio.io
      kind: Hostname
      name: workload-b1.demo.mesh.internal
      port: 8000
EOF
```

Create a matching `i-pig` namespace on cluster-2 (the consuming side, where `wpt-cel-egress` lives) and point its route at `portfolio-b-pig` via its cross-cluster mesh-internal hostname:
```bash
kubectl --context $REMOTE_CONTEXT2 create namespace i-pig
kubectl --context $REMOTE_CONTEXT2 label namespace i-pig istio.io/dataplane-mode=ambient

kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wpt-cel-egress-to-workload-b
  namespace: i-pig
spec:
  parentRefs:
  - name: wpt-cel-egress
    namespace: i-peg
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /workload-b1
    backendRefs:
    - group: networking.istio.io
      kind: Hostname
      name: portfolio-b-pig.i-pig.mesh.internal
      port: 8080
EOF
```

---

## 7.0 Set up `workload-a1 (real Cloud Run) → wpt-cel-egress → portfolio-b-pig → demo-waypoint → workload-b1`

```bash
kubectl --context $REMOTE_CONTEXT3 apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: demo-waypoint-params
  namespace: demo
spec:
  workloadClaims:
    enabled: true
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo-waypoint
  namespace: demo
  labels:
    istio.io/waypoint-for: all
spec:
  gatewayClassName: enterprise-agentgateway-waypoint
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: demo-waypoint-params
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: demo-waypoint-emit
  namespace: demo
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: demo-waypoint
  backend:
    workloadIdentity:
      mode: SourceDelegation
      emitProof: true
      proofLifetime: 60s
EOF

kubectl --context $REMOTE_CONTEXT3 label namespace demo istio.io/use-waypoint=demo-waypoint --overwrite
kubectl --context $REMOTE_CONTEXT3 label namespace demo istio.io/ingress-use-waypoint=true --overwrite
```

**Run `workload-a1` and check the full chain** — re-executing the same Cloud Run Job from §4.2 now exercises the complete path:

```bash
gcloud run jobs execute workload-a1 --project=${PROJECT_ID} --region=${REGION} --wait

# The execution that just ran (newest first)
export EXECUTION=$(gcloud run jobs executions list --job=workload-a1 \
  --project=${PROJECT_ID} --region=${REGION} --limit=1 --format='value(metadata.name)')
echo "Execution: ${EXECUTION}"

# The app container's output (curl response) for that execution only.
# Logs can land a few seconds after --wait returns; re-run if it comes back empty.
gcloud logging read \
  "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"workload-a1\" AND labels.\"run.googleapis.com/execution_name\"=\"${EXECUTION}\" AND labels.container_name=\"app\"" \
  --project=${PROJECT_ID} --freshness=1d --limit=200 --order=asc --format='value(textPayload)' \
  | grep -A2 '"X-Forwarded-Workload-Identity"' 
```
```
HTTP/1.1 200 OK
access-control-allow-credentials: true
access-control-allow-origin: *
content-type: application/json; charset=utf-8
date: Wed, 23 Sep 2026 04:21:42 GMT
transfer-encoding: chunked

{
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/i-pig/sa/portfolio-b-pig, spiffe://cluster.local/ns/demo/sa/demo-waypoint"
    ],
}
```

(Real output, captured from execution `workload-a1-7sj7x` — JWT values truncated to placeholders above; every other field, including the full `X-Forwarded-Workload-Identity` chain, is verbatim. The identity of `workload-a1` — a real Cloud Run Job with no GKE presence at all — survives all four hops, ending at `spiffe://cluster.local/ns/demo/sa/workload-a1` as `workloadIdentity.chain.origin`, exactly matching the shape of every other doc in this series.)

**What to confirm in the logs.** A `200 OK` alone doesn't prove identity propagation, because it also succeeds without `ENABLE_WORKLOAD_CLAIMS`. Check all three of these:
- `X-Forwarded-Workload-Identity` **starts with** `spiffe://cluster.local/ns/demo/sa/workload-a1`.
- The payload of `X-Original-Workload-Identity-Token` has `"sub": "spiffe://cluster.local/ns/demo/sa/workload-a1"`, not `.../i-peg/sa/wpt-cel-egress`.
- The ztunnel sidecar's access log shows a **direct** hop to the pod, not the east-west gateway:
  ```
  info access connection complete ... src.identity="spiffe://cluster.local/ns/demo/sa/workload-a1" dst.addr=10.20.1.16:15008 dst.hbone_addr=10.20.1.16:8080 dst.service="wpt-cel-egress.i-peg.mesh.internal" dst.workload="wpt-cel-egress-..." direction="outbound"
  ```

To look at a single execution, filter on `labels."run.googleapis.com/execution_name"="<execution>"` and `labels.container_name="ztunnel"` (or `"app"`).

---

## Troubleshooting

Each symptom below was hit for real while bringing this doc up. They're listed in the order you'd hit them.

| Symptom (Cloud Run `ztunnel` / `app` logs) | Cause | Fix |
|---|---|---|
| `failed to negotiate socks connection: HostUnreachable: dns lookup: ... no records found for Query { name: Name("wpt-cel-egress.i-peg.mesh.internal.") ... }` | `wpt-cel-egress` isn't global-scoped, so no `*.mesh.internal` name exists for it. | Add `solo.io/service-scope: global` to the Gateway's `infrastructure.labels` (§5.0). Confirm with `kubectl -n i-peg get svc wpt-cel-egress --show-labels`. |
| `error access connection complete ... dst.workload="NetworkGateway/flat-network/<EW IP>/15008" ... error="http status: 400 Bad Request"`, and `hbone failed: hostname resolution not supported` in `wpt-cel-egress`'s own logs | `remote: true` in the bootstrap (ztunnel log: `alwaysTraverseNetworkGateway: true`). Double-HBONE sends the inner CONNECT to a *hostname*, and agentgateway's HBONE listener only accepts `IP:port`. | Set `remote: false` in the bootstrap JSON, re-encode it, `gcloud secrets versions add`, and re-execute (§4.1). Decode the live secret to be sure it took effect: `gcloud secrets versions access latest --secret workload-a1-bootstrap-token \| base64 -d \| base64 -d \| jq .remote` |
| `200 OK`, but `X-Forwarded-Workload-Identity` starts at `wpt-cel-egress` and the original WIT's `sub` is `wpt-cel-egress` | `ENABLE_WORKLOAD_CLAIMS` isn't set on the sidecar (ztunnel log: `enableWorkloadClaims: false`). | Add it (§4.2), or on an existing job: `gcloud run jobs update workload-a1 --region=${REGION} --container ztunnel --update-env-vars ENABLE_WORKLOAD_CLAIMS=true` |
| No `WorkloadEntry` for `workload-a1` in any cluster | Expected, not a bug. With no `platform` in the bootstrap, ztunnel runs against a synthetic local workload that istiod never registers. | None. Don't chase it. |
| `failed to set netns` | Expected on Cloud Run's sandbox. | None. |

---

## Cleanup

Run these in order. They permanently delete real Google Cloud resources in `${PROJECT_ID}`.

**1. Cloud Run resources:**

```bash
export CLOUDRUN_ZTUNNEL_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/istio-images/ztunnel:1.31.0-solo-distroless"

# Deletes the job and all of its executions
gcloud run jobs delete workload-a1 --project=${PROJECT_ID} --region=${REGION} --quiet

# Deletes all versions, and the runtime SA's secretAccessor binding with it
gcloud secrets delete workload-a1-bootstrap-token --project=${PROJECT_ID} --quiet

gcloud artifacts docker images delete ${CLOUDRUN_ZTUNNEL_IMAGE} \
  --project=${PROJECT_ID} --delete-tags --quiet
# Only if nothing else uses the istio-images repository:
# gcloud artifacts repositories delete istio-images --project=${PROJECT_ID} --location=${REGION} --quiet
```

**2. Delete LoadBalancer Services *before* deleting the clusters.** The east-west gateways (all three clusters) and `wpt-cel-egress` (cluster-2) are `type: LoadBalancer` with public IPs. Deleting the Services first lets GKE tear down their forwarding rules, IPs and `k8s-*` firewall rules. If you delete the cluster first, those can be left behind and keep billing.

```bash
for ctx in $REMOTE_CONTEXT1 $REMOTE_CONTEXT2 $REMOTE_CONTEXT3; do
  kubectl --context $ctx get svc -A --field-selector spec.type=LoadBalancer -o json \
    | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read ns name; do kubectl --context $ctx delete svc $name -n $ns --wait=true; done
done
```

**3. GKE clusters and their networking** (clusters, cluster subnets, `solo-allow-cross-cluster`; `solo-vpc` itself is kept, since it's shared):

```bash
./data/cleanup-3-3n-gke-clusters.sh
```

If you're keeping the clusters, skip this step and just undo the cluster-side changes instead:

```bash
kubectl --context $REMOTE_CONTEXT2 set env deployment/istiod -n istio-system REQUIRE_3P_TOKEN-
kubectl --context $REMOTE_CONTEXT2 delete serviceaccount workload-a1 -n demo
```

**4. Cloud Run networking.** Run this last. Cloud Run can keep Direct VPC Egress IPs reserved in `solo-subnet-cloudrun` for **1–2 hours** after the job is deleted, so the subnet delete fails with a "resource is in use" error until they're released. Retry it later if it fails:

```bash
gcloud compute firewall-rules delete solo-allow-cloudrun-to-mesh --project=${PROJECT_ID} --quiet
gcloud compute networks subnets delete solo-subnet-cloudrun --project=${PROJECT_ID} --region=${REGION} --quiet
```

**5. Check for leftovers:**

```bash
gcloud run jobs list --project=${PROJECT_ID} --region=${REGION} --filter="metadata.name=workload-a1"
gcloud secrets list --project=${PROJECT_ID} --filter="name~workload-a1"
gcloud compute forwarding-rules list --project=${PROJECT_ID} --filter="description~(istio-eastwest|wpt-cel-egress)"
gcloud compute firewall-rules list --project=${PROJECT_ID} --filter="network~solo-vpc AND name~(solo-allow-cloudrun|k8s-)"
gcloud compute networks subnets list --project=${PROJECT_ID} --network=solo-vpc
```

**6. Local files:**

```bash
rm -f bootstrap-workload-a1.json workload-a1-job.yaml
```
