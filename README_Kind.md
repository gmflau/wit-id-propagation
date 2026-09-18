---
author: Gilbert Lau
date: "September 17, 2026"
versions:
  "Solo istio distro": 1.31.0
  "enterprise-agentgateway": v2026.9.0
title: "WIT Identity Propagation with Enterprise Agentgateway (Local Kind Multi-Cluster)"
---

# WIT Identity Propagation: workload-A → Agentgateway Egress Waypoint → Agentgateway PIG Gateway → Agentgateway Waypoint → workload-B

## Overview

This is the local, three-Kind-cluster version of [README_GKE.md](./README_GKE.md). It reproduces the exact same lab — native WIMSE Workload Identity Token (WIT) propagation using `enterprise-agentgateway` across three clusters connected over an east-west network — entirely on your own machine with Docker + [Kind](https://kind.sigs.k8s.io/), no cloud project required. Only the infrastructure layer (§1.1/§1.2 below) differs from the GKE version; every Istio, agentgateway, and workload manifest is unchanged.

**Full traffic path:**
```
workload-A → (ztunnel) → demo-egress-waypoint → (east-west) → pig-kgateway → (east-west) → demo-waypoint → workload-B
```

![Architecture Diagram](./img/wit-wpt-id-propagation)

**Cluster layout:**
- `cluster-1` — `pig-kgateway` (agentgateway), `i-pig` namespace
- `cluster-2` — `demo-egress-waypoint` (agentgateway), `workload-A` (netshoot), `source-demo` namespace
- `cluster-3` — `demo-waypoint` (agentgateway), `workload-B` (go-httpbin), `i-pig` namespace

**How this works:**
- `pig-kgateway` runs `enterprise-agentgateway` — no separate `pig-waypoint` component needed
- `demo-egress-waypoint` (agentgateway) is deployed on cluster-2 as an **egress waypoint** for workload-A
- workload-A sends plain HTTP requests — **zero application changes needed**
- workload-A's own ztunnel embeds workload-A's SPIFFE identity claims (from its istiod-issued cert SAN) into a WIT and forwards it on the outbound HBONE connection to `demo-egress-waypoint` — this is what `ENABLE_WORKLOAD_CLAIMS=true` on ztunnel enables, with zero application involvement
- `demo-egress-waypoint` (`SourceDelegation`) forwards that inbound WIT and emits a WPT, binding the chain to its verified HBONE connection with workload-A's ztunnel
- `pig-kgateway` (`SourceDelegation`) forwards the hoisted WIT and emits a fresh WPT, binding the chain to its verified connection with the egress waypoint
- `demo-waypoint` (`PeerBound` enforcement) validates the WPT chain and authorizes using `workloadIdentity.chain.origin` = `workload-a-sa`

**Identity propagation comparison:**

| Aspect |  EnvoyFilter + XFCC | WIMSE WIT + WPT |
|---|---|---|
| Identity carrier | Custom `X-Caller-Identity` + XFCC chain | Standard `Workload-Identity-Token` (IETF WIMSE) |
| Proof of possession | None — header can be spoofed | WPT: short-lived JWS bound to WIT + audience |
| Replay protection | None | WPT `jti` replay cache, bounded expiry (60 s) |
| Config required | Two EnvoyFilters | `EnterpriseAgentgatewayParameters` + `EnterpriseAgentgatewayPolicy` |
| PIG gateway | `enterprise-kgateway` + `pig-waypoint` | `enterprise-agentgateway` only — SourceDelegation built in |
| App changes | None | **None** — workload-A's ztunnel hoists its WIT transparently, egress waypoint forwards it |
| Authorization | `source.identity.*` (mTLS peer only) | `workloadIdentity.chain.origin` = `workload-a-sa` (original caller preserved) |
| Telemetry resource | Required for waypoint access log | Not required — agentgateway logs natively |

**Key concepts:**
- **WIT (Workload Identity Token):** A structured token encoding workload identity claims, carried as an HTTP header. Propagates identity through multi-hop paths independently of the mTLS transport layer.
- **WPT (Workload Proof Token):** A short-lived JWS proving the sender possesses the key bound to a WIT. Prevents replay — a stolen WIT cannot be replayed without the proof.
- **Ztunnel SAN-claim forwarding:** istiod embeds workload identity claims in the SAN of each workload's mTLS certificate. Ztunnel reads those claims and forwards a WIT on the outbound HBONE connection (enabled via `ENABLE_WORKLOAD_CLAIMS=true`) — this is how workload-A's identity enters the WIT chain even though the application sends a plain HTTP request with no WIT header of its own.
- **SourceDelegation:** the `workloadIdentity.mode` used by both `demo-egress-waypoint` and `pig-kgateway`. Each forwards the inbound WIT from its verified upstream connection and emits a new WPT binding the chain to that connection — `demo-egress-waypoint` forwards the WIT ztunnel attached for workload-A; `pig-kgateway` forwards the WIT `demo-egress-waypoint` hoisted. Because both are agentgateway, no separate waypoint proxy is needed at either hop.
- **PeerBound enforcement:** `demo-waypoint` validates the WPT chain and populates `workloadIdentity.chain.origin` with the original caller's identity.
- **`workloadIdentity.chain.origin`:** CEL attribute at `demo-waypoint` = `workload-a-sa` — workload-A's identity is preserved end-to-end even though workload-A never touched a WIT header.

Reference: [https://docs.solo.io/istio/1.31.x/security/workload-identity/wimse/](https://docs.solo.io/istio/1.31.x/security/workload-identity/wimse/)

> **Alpha feature:** WIMSE WIT/WPT support is in alpha and not production-ready.
>
> **Mode correction:** an earlier draft of this lab assumed a `PeerIdentification` mode on `EnterpriseAgentgatewayPolicy` for the egress waypoint. That mode doesn't exist — confirmed against the live `enterpriseagentgatewaypolicies.enterpriseagentgateway.solo.io` CRD schema (`workloadIdentity.mode` enum is `SourceDelegation` | `SelfIdentification` only, as of the latest published `enterprise-agentgateway-crds` chart, v2026.9.0). The correct mode is `SourceDelegation`: workload-A's own ztunnel already forwards a WIT on the outbound HBONE connection (see [Ztunnel SAN-claim forwarding](#key-concepts) above), so the egress waypoint only needs to forward it, not mint one from scratch.

---

## 1.1 Create the Kind Clusters

Create three single-node Kind clusters on your machine, flat-routed to each other so pod IPs are directly reachable cluster-to-cluster — the local equivalent of GKE's VPC-native pod routing:

```bash
./data/setup-3-kind-clusters.sh
```

This script creates `cluster-1`, `cluster-2`, and `cluster-3` (one control-plane node each) with non-overlapping pod CIDRs `10.10/16`, `10.20/16`, and `10.30/16` (matching the GKE version's ranges). All three Kind clusters share Kind's default `kind` Docker bridge network, so their node containers can already reach each other by Docker IP; the script adds one `ip route` per (node, remote pod CIDR) pair so pod traffic actually gets there — this is the manual step GCP VPC-native routing does for you automatically on GKE.

It also installs [MetalLB](https://metallb.universe.tf/) on all three clusters, since Kind has no built-in `LoadBalancer` provider and the east-west gateway Services created below need real IPs. **Use MetalLB, not `cloud-provider-kind`** — `cloud-provider-kind` is the usual fix for a single Kind cluster, but it always publishes a LoadBalancer Service's ports straight onto the host at their literal port numbers. Istio's east-west gateway uses the same fixed ports (`15021`/`15008`/`15012`) in every cluster, so with three clusters running simultaneously on one Docker host, only the first cluster's proxy container can ever bind those host ports — the other two fail with "port already allocated". MetalLB sidesteps this entirely: it hands out IPs via L2/ARP directly inside the shared Docker network and never touches host ports, so all three clusters get their own east-west gateway address at the same time. The script gives each cluster its own address pool carved out of the shared `kind` Docker network (`172.18.253.200-240`, `172.18.254.200-240`, `172.18.255.200-240`) — the same pattern used by Istio's own [`samples/kind-lb/setupkind.sh`](https://github.com/istio/istio/blob/master/samples/kind-lb/setupkind.sh).

### 1.2 Install the Ambient Mesh

Install Solo Istio ambient mesh across all three clusters and link them as a flat-network multicluster mesh:

```bash
./data/setup-ambient-mc-fn3-kind.sh
```

Requires `SOLO_LICENSE_KEY` and `GLOO_MESH_LICENSE_KEY` in your environment (same as the GKE version).

### Initialize Environment Variables

```bash
export ISTIO_VERSION=1.31.0
export ISTIO_IMAGE=${ISTIO_VERSION}-solo
export REPO=us-docker.pkg.dev/soloio-img/istio
export HELM_REPO=us-docker.pkg.dev/soloio-img/istio-helm

export REMOTE_CLUSTER1="cluster-1"
export REMOTE_CLUSTER2="cluster-2"
export REMOTE_CLUSTER3="cluster-3"
export REMOTE_CONTEXT1="kind-${REMOTE_CLUSTER1}"
export REMOTE_CONTEXT2="kind-${REMOTE_CLUSTER2}"
export REMOTE_CONTEXT3="kind-${REMOTE_CLUSTER3}"
export NETWORK="flat-network"
```

### Verify Cluster Connectivity

```bash
export PATH=${HOME}/.istioctl/bin:${PATH}

istioctl multicluster check --contexts="$REMOTE_CONTEXT1,$REMOTE_CONTEXT2,$REMOTE_CONTEXT3"
```

---

### 1.1 Create Namespaces

```bash
kubectl --context $REMOTE_CONTEXT1 create namespace i-pig
kubectl --context $REMOTE_CONTEXT1 label namespace i-pig istio.io/dataplane-mode=ambient

kubectl --context $REMOTE_CONTEXT2 create namespace demo
kubectl --context $REMOTE_CONTEXT2 label namespace demo istio.io/dataplane-mode=ambient

kubectl --context $REMOTE_CONTEXT3 create namespace demo
kubectl --context $REMOTE_CONTEXT3 label namespace demo istio.io/dataplane-mode=ambient
```

---

## 2.0 Install Enterprise Agentgateway

`enterprise-agentgateway` is not bundled with Solo Istio. Install the controller on all three clusters: cluster-1 (`pig-kgateway`), cluster-2 (`demo-egress-waypoint`), and cluster-3 (`demo-waypoint`). `istio.clusterId` must match the `multiCluster.clusterName` set by the setup script for each cluster.

```bash
export AGENTGATEWAY_VERSION=v2026.9.0
```

**cluster-1** (pig-kgateway):
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

**cluster-2** (demo-egress-waypoint):
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

## 3.0 Deploy workloads

Deploy workload-a1
```bash
kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-a1
  namespace: demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workload-a1
  namespace: demo
  labels:
    app: workload-a1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: workload-a1
  template:
    metadata:
      labels:
        app: workload-a1
    spec:
      serviceAccountName: workload-a1
      containers:
      - name: workload-a1
        image: curlimages/curl
        command: ["/bin/sleep", "3650d"]
        imagePullPolicy: IfNotPresent
EOF

kubectl --context $REMOTE_CONTEXT2 wait --for=condition=available deploy/workload-a1 -n demo --timeout=90s
```

Deploy workload-a2
```bash
kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-a2
  namespace: demo
---
apiVersion: v1
kind: Service
metadata:
  name: workload-a2
  namespace: demo
  labels:
    app: workload-a2
    service: workload-a2
    solo.io/service-scope: global
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 8080
  selector:
    app: workload-a2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workload-a2
  namespace: demo
  labels:
    app: workload-a2
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: workload-a2
      version: v1
  template:
    metadata:
      labels:
        app: workload-a2
        version: v1
    spec:
      serviceAccountName: workload-a2
      containers:
      - image: docker.io/mccutchen/go-httpbin:2.25.0
        imagePullPolicy: IfNotPresent
        name: workload-a2
        ports:
        - containerPort: 8080
        env:
        - name: SRV_MAX_HEADER_BYTES
          value: "131072"
EOF

kubectl --context $REMOTE_CONTEXT2 wait --for=condition=available deploy/workload-a2 -n demo --timeout=90s
```

Deploy workload-b1
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

## 4.0 Set up `workload-a1 → wpt-cel-egress → workload-a2`:

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
```bash
kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wpt-cel-egress-to-workload-a
  namespace: demo
spec:
  parentRefs:
  - name: wpt-cel-egress
    namespace: i-peg
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /workload-a2
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - group: ""
      kind: Service
      name: workload-a2
      port: 8000
EOF
```

Verify `workload-a1 → wpt-cel-egress → workload-a2`:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-a2/headers'
```

```
HTTP/1.1 200 OK
Access-Control-Allow-Credentials: true
Access-Control-Allow-Origin: *
Content-Type: application/json; charset=utf-8
Date: Thu, 17 Sep 2026 18:13:35 GMT
Transfer-Encoding: chunked

{
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Host": [
      "wpt-cel-egress.i-peg.svc.cluster.local:8080"
    ],
    "User-Agent": [
      "curl/8.22.0"
    ],
    "Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWt3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE56RTJOVE13TTFvWERUTTJNRGt4TkRFMk5UTXdNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFEYU5oNEsxZUVScW8wTkxJSHB5M1k1SXhUbngycU43REJDTXJNZW43NnpBYytjTUovMGg2WE5yZGdDbmVjRnZzdk9iaXFtSmQrWXJUeDRUVHI0R09oR0hidVB0WnlSSUhSVnVKWFJtVUZzUlhHZGtDcE9uRkMvUlRVWkxMV1NpS3JTQlo5MnJMNFQvaHgvZVlSS2ljUkNEaE10NEFxaENNbjA4WlpSWW9hc1B4dExTZ05PRUJFdUIycHp6YTR5UHRpQVQ4Z28wZlV2RGM1R0tzMi9PK3JRUHNxTUNmbGJVNkpXdytyNThpdWRXdTlpakMrQzVLcWFtRXJaRFdnVlZCSDlYcms4a1lCZlROVnRURG43dGo1QjhOWWVTck41SjhKQjI5dmxOLzk1MlhLUFJmUysyK2gxUFNwQndSVjZza2V3QnV4K0xqVEQzalNsdVBMbXlGWUNmT3IwRjUwaVVBRURSNEtETUIycXFRMmRUWkVPbUNyTnlyeXErVllUNk5QWGduSWVvOHpzS0Y4Y0pacDJSRlpFaHhac2xtdEtBRUR5WXZib0t2YWx5TzIzMGlFK1RYWXJaSWpqbWdsVmhHNmx2cUVXL2l2L1hyZkRnV3FnUE0vcXUrY0cvd040Nk80bFdueEt0U2dBLy9iSHhYcFdKMDlIU0EzTE1YLytwWXVXWFgwMHVaeUZWdzBORHFHZmY1Yk1kcXlVbHB5QWxpT0dLaHFscG1aYUFFdDhmNkZnamg3RHNBTCtJUGxyaUZTamhROGx0aUJoTnhmWkRSRDd5UllCMmNqL1k1M2FqbW5PK2ZWeFBoREY4K0N0N2Vlc0FINERuVWNJK2hTRFo1MWVPWEhQY3NzQkh2bnJHNHBjZUs1SEJuZUhnTGVmRlA1U3ltTmNYZDJMNndJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZFN3U5SnQyMFBpUlBWemlRSGVsNzY4VzRQcXNNQjhHQTFVZEl3UVlNQmFBRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQmhNZXBVWFFrc3lTUm5qNnNTYUlUOEJ3ajhJWThRYlV3THFvRlhiaytWY1hhUnVNaUJlQXUxb2ZkaWFVU0dxclQ1dHZMa1NJVjlNWXpCeVZXODVuQmFTdjV6MVVKeVZ5UVlsQ0ZONjZ1NXZGUUJMV0h3VlJYTjhTc2xYTlJhdVpxcW5mWXE4eHVjTHVGb2JvbVMrc25XWjdhTEo3M1ZTTFB6NjdSRjg2UDRaTTVSdW83NkQwNTBrVmxFTS8yb0M3d3VJOGtHUXcyZkRRRUFwZTVWeExnUFNZTmNkUWtVYWF5L2EzdmlNVHBveWZGbzJZSjdpV2xkVWxWZ1BWbTdIcnBabkhtTG85TzcvaGZhMG5ueGo4MmFSbUdxblNud2VJakRNeEFkYlZ6RXB2aHhFMlVwVURER1lsS0VkbmtrYzQyRlQwdUhnK3NKa0taUVJVVE1aU1BtQ000YjE5UFZHeVBRdzk5dEUxdjQzZExDVmx4eU1WVGhMSmUwaEhrVkx5N1RVRHNMdTN6SWRGQURyZTJnNWVEaGFRbnZGSEpiVnVaREdZOW54dmdMVEpHL1lMUHZneXRORTd4bTBUZm1YSlNuM3FNdExLYm9FQi9YaEZiUXJLUXJ4MXQxNHRlYmpjVGxQMTJHY1YvdXh2eVpSdW90aXpXek5jWlJDb1VCWTFjMHFvOWZ1WjA5L1BTMzVTZVFXbFd2VVFlQ09VYk9vTFlKWGZmMVVrOFU1dFdRWGFpSGVnQzIvOERhNDY2WEZiWEZUOTlPRFNydnRYZ01rajc2UTdIMStVMVpPSE9yNHpiRTlXazRRRXhRNGdwVk5mMnIyOXQwSlRkMlBDUDUvVS9SdXdIUkJWTU5hRjlTNEdQemltZ0Y3aHNLUjY3NXVtbFF0ZFQyUlVGNkh3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5a3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUURhTmg0SzFlRVJxbzBOTElIcHkzWTVJeFRueDJxTjdEQkNNck1lbjc2ekFjK2NNSi8waDZYTnJkZ0NuZWNGdnN2T2JpcW1KZCtZclR4NFRUcjRHT2hHSGJ1UHRaeVJJSFJWdUpYUm1VRnNSWEdka0NwT25GQy9SVFVaTExXU2lLclNCWjkyckw0VC9oeC9lWVJLaWNSQ0RoTXQ0QXFoQ01uMDhaWlJZb2FzUHh0TFNnTk9FQkV1QjJwenphNHlQdGlBVDhnbzBmVXZEYzVHS3MyL08rclFQc3FNQ2ZsYlU2Sld3K3I1OGl1ZFd1OWlqQytDNUtxYW1FclpEV2dWVkJIOVhyazhrWUJmVE5WdFREbjd0ajVCOE5ZZVNyTjVKOEpCMjl2bE4vOTUyWEtQUmZTKzIraDFQU3BCd1JWNnNrZXdCdXgrTGpURDNqU2x1UExteUZZQ2ZPcjBGNTBpVUFFRFI0S0RNQjJxcVEyZFRaRU9tQ3JOeXJ5cStWWVQ2TlBYZ25JZW84enNLRjhjSlpwMlJGWkVoeFpzbG10S0FFRHlZdmJvS3ZhbHlPMjMwaUUrVFhZclpJamptZ2xWaEc2bHZxRVcvaXYvWHJmRGdXcWdQTS9xdStjRy93TjQ2TzRsV254S3RTZ0EvL2JIeFhwV0owOUhTQTNMTVgvK3BZdVdYWDAwdVp5RlZ3ME5EcUdmZjViTWRxeVVscHlBbGlPR0tocWxwbVphQUV0OGY2RmdqaDdEc0FMK0lQbHJpRlNqaFE4bHRpQmhOeGZaRFJEN3lSWUIyY2ovWTUzYWptbk8rZlZ4UGhERjgrQ3Q3ZWVzQUg0RG5VY0kraFNEWjUxZU9YSFBjc3NCSHZuckc0cGNlSzVIQm5lSGdMZWZGUDVTeW1OY1hkMkw2d0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRkU3dTlKdDIwUGlSUFZ6aVFIZWw3NjhXNFBxc01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFCaE1lcFVYUWtzeVNSbmo2c1NhSVQ4QndqOElZOFFiVXdMcW9GWGJrK1ZjWGFSdU1pQmVBdTFvZmRpYVVTR3FyVDV0dkxrU0lWOU1ZekJ5Vlc4NW5CYVN2NXoxVUp5VnlRWWxDRk42NnU1dkZRQkxXSHdWUlhOOFNzbFhOUmF1WnFxbmZZcTh4dWNMdUZvYm9tUytzbldaN2FMSjczVlNMUHo2N1JGODZQNFpNNVJ1bzc2RDA1MGtWbEVNLzJvQzd3dUk4a0dRdzJmRFFFQXBlNVZ4TGdQU1lOY2RRa1VhYXkvYTN2aU1UcG95ZkZvMllKN2lXbGRVbFZnUFZtN0hycFpuSG1MbzlPNy9oZmEwbm54ajgyYVJtR3FuU253ZUlqRE14QWRiVnpFcHZoeEUyVXBVRERHWWxLRWRua2tjNDJGVDB1SGcrc0prS1pRUlVUTVpTUG1DTTRiMTlQVkd5UFF3OTl0RTF2NDNkTENWbHh5TVZUaExKZTBoSGtWTHk3VFVEc0x1M3pJZEZBRHJlMmc1ZURoYVFudkZISmJWdVpER1k5bnh2Z0xUSkcvWUxQdmd5dE5FN3htMFRmbVhKU24zcU10TEtib0VCL1hoRmJRcktRcngxdDE0dGViamNUbFAxMkdjVi91eHZ5WlJ1b3Rpeld6TmNaUkNvVUJZMWMwcW85ZnVaMDkvUFMzNVNlUVdsV3ZVUWVDT1ViT29MWUpYZmYxVWs4VTV0V1FYYWlIZWdDMi84RGE0NjZYRmJYRlQ5OU9EU3J2dFhnTWtqNzZRN0gxK1UxWk9IT3I0emJFOVdrNFFFeFE0Z3BWTmYycjI5dDBKVGQyUENQNS9VL1J1d0hSQlZNTmFGOVM0R1B6aW1nRjdoc0tSNjc1dW1sUXRkVDJSVUY2SHc9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVVzFvVEQzb25SRVFTamhCUUNyR2lBMGNDdndnd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOekUyTlRNd00xb1hEVE0yTURreE5ERTJOVE13TTFvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUF3T3ZhUnhHS3FhR2lMK1gzeHV2U2tnM2dlSVBWK25Gei9HcHl0eXlHYU1wT25QSEVBWHZIMmZHOVZZck8xMW9HRU5PcG1BcEJaUWN4U1hsSUlNcDNCaHVzOXNIVDFHNXRyK0lXRHI3dXE0eGQ2bFdvbGYvVDd1amNES1I0RnMwMzlMSXNNTnBhMzd3eTlKeldKVnlzMWxvSnJseUNNeldtZ1Jvb3NQWmpXQ0MzMmFwOU1hcU5WUzMxaVF3ODVVNlhEbnlnYUhOR2hoRGp1elIyd0U1NlEyaS92ZWxlaDV6R3dHSVB5N3FDQkZUVW5hSS8wYy9lV1RTYmFZNXU4SVRqSUZlL2FIZEF4WWloL0FWbFhXSVQ2SVM0UEQrRmZLQnRiRUc1ZTVGeFR4NE9qVERDUTlQMFNhRUhZdVU1eDZTTGRIeFhMR081cnlVY2Nvdi9lUXMrMS9LOG0rR3ZYcEhFTmdZeE9qenRBRFJ2aUFqWURYMng5VWlRaFpXSjZFb2pyUTJNV1dzOCtEUGZ0enRCY1Q1V01VWStNM244YlFCUjRyZEk0ZGdteHFacFpLM2ttbjhMdUpYZWhFeWhBdzc1NHJ5VHBiM2lNamFyTkNjNHpoay8wSGhWd0JLN1pGS0srME42c3NGVmV2aUd6Y0NjN0dqRmg1MDFIZWVrUmRYUlVJcUJUdWZ0ZDRDNGJxRDkrOEx0UWdqN3gxRTh1NkVlOGwwZ1hPUS9BdVRuSEJ2L2FlaWlFOSt3ejF6YTNmbzkzdGp6dmVNR3o5aEJma3hYamRBQmdLZG42cmxmT0V4Z2lrWW44emNZejFhemJ2U2xQbWxwenh3VVMzZGhLZWdrcFEzQVQvYTFKU2xKQ2RaUHFxYmgyNS9BM2ZZOVdsYWhnSmJMYXZ6ZTNqa0NBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUI4R0ExVWRJd1FZTUJhQUZPK2hIK21jb1hLRzdBcWc0aEM3OHNCdFI5R0dNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBR1I0OVo0VEpnNEVsaTl3RkhIaGttekJCODNzbVEyMjRPdGduUHlENmtEMElLRGg2KzBqaUJ5cEk3QUZ1RU91SENVU29IK0c3UTRZWFZSeWVTZmdkM3FBbUdKRHhHMVFNcVpLQ3c3YTRzelBsRXEwOGRISEZNTUtXZXY2YURpdjhQNDNiekRRSWF6L2dtVXpONlN1aEszeWpIRWxVRzJJTkdMcXlCUTNLSm9OTW5yWmdGcmpMeW5sU2tRQzdJR3hHa3lnb251NHNXeTkzaGRHY0FDb0pBaG9IdDNUcGw2MThJS3kzSGF3S2pIY3ZncFJmMVAwdjR3dllOdzZzMXB5RnA5cnVoZEdRb0g3eDJrRFJvMFUxNm5wakxpMjVoVFltUDZ3Q044OFJzQ00xS0tnSHMyRW1rd1pQWHhBU3hsVFFzRDlRdVNsdHROWjNzeWFTcUMzby9yajF4MkVrUDZ6WXE2cWp4VllIZy9uMDcwUTZRRkgvTk8vVkh6RVo1UkJKL2hkNFR5b2Z0dG1VN2FpaUMrdWFoQmFsWnpjVk1HNG5IZ3U5WmpLbWlNclBzUkh0Vzl4MlhHRG9VZGdQczMzczc5R21BbEFZKzdBMndNRHFFZVVHMHZwY0kyU0dEbzNHVEVmbS9XeHlMczR6R2hrdy9mN1laeSt2dFdXWE9kM2tRSXZCeXRxcTkyYTlzTjFUZmswaXFuQ003VlBYUEhFaTZCZHZGd090NVk2eUVzQUFvY1c5MjhFdDdyQWJmMXNkRUVDdmVQaHBPc0ZZK3ZNS0REQUlaaStGWS9paDEzNzIrNGN2b3Fra0lwWHNQd3UrRzlHZndybVRMQUtpR0VyNnlRTkMvdktBR2xDSkdJc29rTFBSSkMxTzh0NEsydEZkOFhmL2s5VERFVm0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVVcxb1REM29uUkVRU2poQlFDckdpQTBjQ3Z3Z3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBd092YVJ4R0txYUdpTCtYM3h1dlNrZzNnZUlQVituRnovR3B5dHl5R2FNcE9uUEhFQVh2SDJmRzlWWXJPMTFvR0VOT3BtQXBCWlFjeFNYbElJTXAzQmh1czlzSFQxRzV0citJV0RyN3VxNHhkNmxXb2xmL1Q3dWpjREtSNEZzMDM5TElzTU5wYTM3d3k5SnpXSlZ5czFsb0pybHlDTXpXbWdSb29zUFpqV0NDMzJhcDlNYXFOVlMzMWlRdzg1VTZYRG55Z2FITkdoaERqdXpSMndFNTZRMmkvdmVsZWg1ekd3R0lQeTdxQ0JGVFVuYUkvMGMvZVdUU2JhWTV1OElUaklGZS9hSGRBeFlpaC9BVmxYV0lUNklTNFBEK0ZmS0J0YkVHNWU1RnhUeDRPalREQ1E5UDBTYUVIWXVVNXg2U0xkSHhYTEdPNXJ5VWNjb3YvZVFzKzEvSzhtK0d2WHBIRU5nWXhPanp0QURSdmlBallEWDJ4OVVpUWhaV0o2RW9qclEyTVdXczgrRFBmdHp0QmNUNVdNVVkrTTNuOGJRQlI0cmRJNGRnbXhxWnBaSzNrbW44THVKWGVoRXloQXc3NTRyeVRwYjNpTWphck5DYzR6aGsvMEhoVndCSzdaRktLKzBONnNzRlZldmlHemNDYzdHakZoNTAxSGVla1JkWFJVSXFCVHVmdGQ0QzRicUQ5KzhMdFFnajd4MUU4dTZFZThsMGdYT1EvQXVUbkhCdi9hZWlpRTkrd3oxemEzZm85M3RqenZlTUd6OWhCZmt4WGpkQUJnS2RuNnJsZk9FeGdpa1luOHpjWXoxYXpidlNsUG1scHp4d1VTM2RoS2Vna3BRM0FUL2ExSlNsSkNkWlBxcWJoMjUvQTNmWTlXbGFoZ0piTGF2emUzamtDQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQUdSNDlaNFRKZzRFbGk5d0ZISGhrbXpCQjgzc21RMjI0T3RnblB5RDZrRDBJS0RoNiswamlCeXBJN0FGdUVPdUhDVVNvSCtHN1E0WVhWUnllU2ZnZDNxQW1HSkR4RzFRTXFaS0N3N2E0c3pQbEVxMDhkSEhGTU1LV2V2NmFEaXY4UDQzYnpEUUlhei9nbVV6TjZTdWhLM3lqSEVsVUcySU5HTHF5QlEzS0pvTk1uclpnRnJqTHlubFNrUUM3SUd4R2t5Z29udTRzV3k5M2hkR2NBQ29KQWhvSHQzVHBsNjE4SUt5M0hhd0tqSGN2Z3BSZjFQMHY0d3ZZTnc2czFweUZwOXJ1aGRHUW9IN3gya0RSbzBVMTZucGpMaTI1aFRZbVA2d0NOODhSc0NNMUtLZ0hzMkVta3daUFh4QVN4bFRRc0Q5UXVTbHR0Tlozc3lhU3FDM28vcmoxeDJFa1A2ellxNnFqeFZZSGcvbjA3MFE2UUZIL05PL1ZIekVaNVJCSi9oZDRUeW9mdHRtVTdhaWlDK3VhaEJhbFp6Y1ZNRzRuSGd1OVpqS21pTXJQc1JIdFc5eDJYR0RvVWRnUHMzM3M3OUdtQWxBWSs3QTJ3TURxRWVVRzB2cGNJMlNHRG8zR1RFZm0vV3h5THM0ekdoa3cvZjdZWnkrdnRXV1hPZDNrUUl2Qnl0cXE5MmE5c04xVGZrMGlxbkNNN1ZQWFBIRWk2QmR2RndPdDVZNnlFc0FBb2NXOTI4RXQ3ckFiZjFzZEVFQ3ZlUGhwT3NGWSt2TUtEREFJWmkrRlkvaWgxMzcyKzRjdm9xa2tJcFhzUHd1K0c5R2Z3cm1UTEFLaUdFcjZ5UU5DL3ZLQUdsQ0pHSXNva0xQUkpDMU84dDRLMnRGZDhYZi9rOVRERVZtIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2ktcGVnL3NhL3dwdC1jZWwtZWdyZXNzIiwiZXhwIjoxNzg5NzU1MTk2LCJpYXQiOjE3ODk2Njg3OTYsImlzdGlvLmlvIjp7InRydXN0X2RvbWFpbiI6ImNsdXN0ZXIubG9jYWwiLCJ3b3JrbG9hZCI6eyJuYW1lIjoid3B0LWNlbC1lZ3Jlc3MiLCJuYW1lc3BhY2UiOiJpLXBlZyIsInBvZCI6IndwdC1jZWwtZWdyZXNzLWQ4NGY5NWM5Ny1menZsdiJ9fSwianRpIjoiMTMxOWRmM2Y4Nzk4YWY5YTVhZTg4ODg5Mjg0NGRmOTEiLCJjbmYiOnsiandrIjp7Imt0eSI6IkVDIiwiY3J2IjoiUC0yNTYiLCJ4IjoiV2JlTXZiWFRoVGNjYUZOSGRtdzBhOTJ0OE1sUEgyTGtCR0ljc2d0OFY0SSIsInkiOiJFX2pZMjBpUlVDVkhFbWstWENJNTFGbm5mQ3c2VGJ4Zk5ScUV4dk12ZlU4In19fQ.Ans-ayYF7LvsKUwacIzTag_ArnOgj3k_YS_XQOBDoRcUSkmZemT4apiQqkg44dFE3WPmGzbCSHigkdAlJ4enzPEG57Y__A0fiB-zcpLKmH72XX2_xPmW1CDSukBDk8dG570rYkz_jAbU_ADACtnWZUCUYPNptHRE9J-XD5GrIFm-pOzED2ZoyYMs2fJO74s94oydiZH4PqHPorFZlxUT6EUFV-KSkC_aMnHfu8521jKP6_arDVL-MAWgkL7RgsL7J78Yg72lN_pANx5PjkrjnBuozCEpODeS6sPPz4WOQX8iQJ1nlF0TohyQFrqieLo2xGgwpyKJh4JBDAwuQMeOsY-hr5PneFKxpGHQMrlq1NVUdVgY2MESbZ4Idxhv-epG1D5yXlkkhhYsl5_SCFc3ReC6LKrPmKegGsPhU9YB1SZfbXRBucA-auMf7NP1c5iIoq6a4vrP8VfYutILXyeGczGV8XPBdnvokjVKHGJEwPncd46II6LztnSbiO1QCveGBfOhRDoB0FsqMzLJulmH3oH3bLx7VBihgr4S9bk6oU0CtuU97lqZtLXCKHBhE7icPm2BIz0ZN3az9tM_Yqesa56WKXmDZyjnfSRvfBss9bFdMFeHq6tC_PdttiqVHJneCdI5X9dPRvpqlJ8dWXTA_1I4UVjLxhPLawbLzRs2Doo"
    ],
    "Workload-Proof-Token": [
      "eyJ0eXAiOiJhcHBsaWNhdGlvbi93cHQrand0IiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2ktcGVnL3NhL3dwdC1jZWwtZWdyZXNzIiwiYXVkIjoiaHR0cHM6Ly93b3JrbG9hZC1hMi5kZW1vLnN2Yy5jbHVzdGVyLmxvY2FsIiwiZXhwIjoxNzg5NjY4ODc1LCJpYXQiOjE3ODk2Njg4MTUsImp0aSI6IjA1ZWVlMmI3LTFjZjEtNDhiZC1iOWVjLTA4MDMyN2UzNDJhNCIsInd0aCI6InN0VGh5TVFMZy1JRFg3RWZVejhsZXo4VTQ5c0JGenFnSWpnc1haU0dnZGciLCJvdGgiOnsieC1mb3J3YXJkZWQtd29ya2xvYWQtaWRlbnRpdHkiOiJ5YlhacThheTJPTVhfaHJPNm5iRkczRXkxbWZtMW1EVEFZSjRYd1lSeXJNIiwieC1vcmlnaW5hbC13b3JrbG9hZC1pZGVudGl0eS10b2tlbiI6IkpDb1RYcUc1WndPLXpmN25GZU13d1FlOW5rTnZrTE4yamcyOEQxT2ozbUUifX0.ebArTavnRJ3PLRYEhxDdirxQuhyLxNaGDB7qvnyMzwZe-y_MzN7oo1CKfv80HrgypYh_0RMSQGqQcYSnttv4Fw"
    ],
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress"
    ],
    "X-Original-Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWt3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE56RTJOVE13TTFvWERUTTJNRGt4TkRFMk5UTXdNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFEYU5oNEsxZUVScW8wTkxJSHB5M1k1SXhUbngycU43REJDTXJNZW43NnpBYytjTUovMGg2WE5yZGdDbmVjRnZzdk9iaXFtSmQrWXJUeDRUVHI0R09oR0hidVB0WnlSSUhSVnVKWFJtVUZzUlhHZGtDcE9uRkMvUlRVWkxMV1NpS3JTQlo5MnJMNFQvaHgvZVlSS2ljUkNEaE10NEFxaENNbjA4WlpSWW9hc1B4dExTZ05PRUJFdUIycHp6YTR5UHRpQVQ4Z28wZlV2RGM1R0tzMi9PK3JRUHNxTUNmbGJVNkpXdytyNThpdWRXdTlpakMrQzVLcWFtRXJaRFdnVlZCSDlYcms4a1lCZlROVnRURG43dGo1QjhOWWVTck41SjhKQjI5dmxOLzk1MlhLUFJmUysyK2gxUFNwQndSVjZza2V3QnV4K0xqVEQzalNsdVBMbXlGWUNmT3IwRjUwaVVBRURSNEtETUIycXFRMmRUWkVPbUNyTnlyeXErVllUNk5QWGduSWVvOHpzS0Y4Y0pacDJSRlpFaHhac2xtdEtBRUR5WXZib0t2YWx5TzIzMGlFK1RYWXJaSWpqbWdsVmhHNmx2cUVXL2l2L1hyZkRnV3FnUE0vcXUrY0cvd040Nk80bFdueEt0U2dBLy9iSHhYcFdKMDlIU0EzTE1YLytwWXVXWFgwMHVaeUZWdzBORHFHZmY1Yk1kcXlVbHB5QWxpT0dLaHFscG1aYUFFdDhmNkZnamg3RHNBTCtJUGxyaUZTamhROGx0aUJoTnhmWkRSRDd5UllCMmNqL1k1M2FqbW5PK2ZWeFBoREY4K0N0N2Vlc0FINERuVWNJK2hTRFo1MWVPWEhQY3NzQkh2bnJHNHBjZUs1SEJuZUhnTGVmRlA1U3ltTmNYZDJMNndJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZFN3U5SnQyMFBpUlBWemlRSGVsNzY4VzRQcXNNQjhHQTFVZEl3UVlNQmFBRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQmhNZXBVWFFrc3lTUm5qNnNTYUlUOEJ3ajhJWThRYlV3THFvRlhiaytWY1hhUnVNaUJlQXUxb2ZkaWFVU0dxclQ1dHZMa1NJVjlNWXpCeVZXODVuQmFTdjV6MVVKeVZ5UVlsQ0ZONjZ1NXZGUUJMV0h3VlJYTjhTc2xYTlJhdVpxcW5mWXE4eHVjTHVGb2JvbVMrc25XWjdhTEo3M1ZTTFB6NjdSRjg2UDRaTTVSdW83NkQwNTBrVmxFTS8yb0M3d3VJOGtHUXcyZkRRRUFwZTVWeExnUFNZTmNkUWtVYWF5L2EzdmlNVHBveWZGbzJZSjdpV2xkVWxWZ1BWbTdIcnBabkhtTG85TzcvaGZhMG5ueGo4MmFSbUdxblNud2VJakRNeEFkYlZ6RXB2aHhFMlVwVURER1lsS0VkbmtrYzQyRlQwdUhnK3NKa0taUVJVVE1aU1BtQ000YjE5UFZHeVBRdzk5dEUxdjQzZExDVmx4eU1WVGhMSmUwaEhrVkx5N1RVRHNMdTN6SWRGQURyZTJnNWVEaGFRbnZGSEpiVnVaREdZOW54dmdMVEpHL1lMUHZneXRORTd4bTBUZm1YSlNuM3FNdExLYm9FQi9YaEZiUXJLUXJ4MXQxNHRlYmpjVGxQMTJHY1YvdXh2eVpSdW90aXpXek5jWlJDb1VCWTFjMHFvOWZ1WjA5L1BTMzVTZVFXbFd2VVFlQ09VYk9vTFlKWGZmMVVrOFU1dFdRWGFpSGVnQzIvOERhNDY2WEZiWEZUOTlPRFNydnRYZ01rajc2UTdIMStVMVpPSE9yNHpiRTlXazRRRXhRNGdwVk5mMnIyOXQwSlRkMlBDUDUvVS9SdXdIUkJWTU5hRjlTNEdQemltZ0Y3aHNLUjY3NXVtbFF0ZFQyUlVGNkh3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5a3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUURhTmg0SzFlRVJxbzBOTElIcHkzWTVJeFRueDJxTjdEQkNNck1lbjc2ekFjK2NNSi8waDZYTnJkZ0NuZWNGdnN2T2JpcW1KZCtZclR4NFRUcjRHT2hHSGJ1UHRaeVJJSFJWdUpYUm1VRnNSWEdka0NwT25GQy9SVFVaTExXU2lLclNCWjkyckw0VC9oeC9lWVJLaWNSQ0RoTXQ0QXFoQ01uMDhaWlJZb2FzUHh0TFNnTk9FQkV1QjJwenphNHlQdGlBVDhnbzBmVXZEYzVHS3MyL08rclFQc3FNQ2ZsYlU2Sld3K3I1OGl1ZFd1OWlqQytDNUtxYW1FclpEV2dWVkJIOVhyazhrWUJmVE5WdFREbjd0ajVCOE5ZZVNyTjVKOEpCMjl2bE4vOTUyWEtQUmZTKzIraDFQU3BCd1JWNnNrZXdCdXgrTGpURDNqU2x1UExteUZZQ2ZPcjBGNTBpVUFFRFI0S0RNQjJxcVEyZFRaRU9tQ3JOeXJ5cStWWVQ2TlBYZ25JZW84enNLRjhjSlpwMlJGWkVoeFpzbG10S0FFRHlZdmJvS3ZhbHlPMjMwaUUrVFhZclpJamptZ2xWaEc2bHZxRVcvaXYvWHJmRGdXcWdQTS9xdStjRy93TjQ2TzRsV254S3RTZ0EvL2JIeFhwV0owOUhTQTNMTVgvK3BZdVdYWDAwdVp5RlZ3ME5EcUdmZjViTWRxeVVscHlBbGlPR0tocWxwbVphQUV0OGY2RmdqaDdEc0FMK0lQbHJpRlNqaFE4bHRpQmhOeGZaRFJEN3lSWUIyY2ovWTUzYWptbk8rZlZ4UGhERjgrQ3Q3ZWVzQUg0RG5VY0kraFNEWjUxZU9YSFBjc3NCSHZuckc0cGNlSzVIQm5lSGdMZWZGUDVTeW1OY1hkMkw2d0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRkU3dTlKdDIwUGlSUFZ6aVFIZWw3NjhXNFBxc01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFCaE1lcFVYUWtzeVNSbmo2c1NhSVQ4QndqOElZOFFiVXdMcW9GWGJrK1ZjWGFSdU1pQmVBdTFvZmRpYVVTR3FyVDV0dkxrU0lWOU1ZekJ5Vlc4NW5CYVN2NXoxVUp5VnlRWWxDRk42NnU1dkZRQkxXSHdWUlhOOFNzbFhOUmF1WnFxbmZZcTh4dWNMdUZvYm9tUytzbldaN2FMSjczVlNMUHo2N1JGODZQNFpNNVJ1bzc2RDA1MGtWbEVNLzJvQzd3dUk4a0dRdzJmRFFFQXBlNVZ4TGdQU1lOY2RRa1VhYXkvYTN2aU1UcG95ZkZvMllKN2lXbGRVbFZnUFZtN0hycFpuSG1MbzlPNy9oZmEwbm54ajgyYVJtR3FuU253ZUlqRE14QWRiVnpFcHZoeEUyVXBVRERHWWxLRWRua2tjNDJGVDB1SGcrc0prS1pRUlVUTVpTUG1DTTRiMTlQVkd5UFF3OTl0RTF2NDNkTENWbHh5TVZUaExKZTBoSGtWTHk3VFVEc0x1M3pJZEZBRHJlMmc1ZURoYVFudkZISmJWdVpER1k5bnh2Z0xUSkcvWUxQdmd5dE5FN3htMFRmbVhKU24zcU10TEtib0VCL1hoRmJRcktRcngxdDE0dGViamNUbFAxMkdjVi91eHZ5WlJ1b3Rpeld6TmNaUkNvVUJZMWMwcW85ZnVaMDkvUFMzNVNlUVdsV3ZVUWVDT1ViT29MWUpYZmYxVWs4VTV0V1FYYWlIZWdDMi84RGE0NjZYRmJYRlQ5OU9EU3J2dFhnTWtqNzZRN0gxK1UxWk9IT3I0emJFOVdrNFFFeFE0Z3BWTmYycjI5dDBKVGQyUENQNS9VL1J1d0hSQlZNTmFGOVM0R1B6aW1nRjdoc0tSNjc1dW1sUXRkVDJSVUY2SHc9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVVzFvVEQzb25SRVFTamhCUUNyR2lBMGNDdndnd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOekUyTlRNd00xb1hEVE0yTURreE5ERTJOVE13TTFvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUF3T3ZhUnhHS3FhR2lMK1gzeHV2U2tnM2dlSVBWK25Gei9HcHl0eXlHYU1wT25QSEVBWHZIMmZHOVZZck8xMW9HRU5PcG1BcEJaUWN4U1hsSUlNcDNCaHVzOXNIVDFHNXRyK0lXRHI3dXE0eGQ2bFdvbGYvVDd1amNES1I0RnMwMzlMSXNNTnBhMzd3eTlKeldKVnlzMWxvSnJseUNNeldtZ1Jvb3NQWmpXQ0MzMmFwOU1hcU5WUzMxaVF3ODVVNlhEbnlnYUhOR2hoRGp1elIyd0U1NlEyaS92ZWxlaDV6R3dHSVB5N3FDQkZUVW5hSS8wYy9lV1RTYmFZNXU4SVRqSUZlL2FIZEF4WWloL0FWbFhXSVQ2SVM0UEQrRmZLQnRiRUc1ZTVGeFR4NE9qVERDUTlQMFNhRUhZdVU1eDZTTGRIeFhMR081cnlVY2Nvdi9lUXMrMS9LOG0rR3ZYcEhFTmdZeE9qenRBRFJ2aUFqWURYMng5VWlRaFpXSjZFb2pyUTJNV1dzOCtEUGZ0enRCY1Q1V01VWStNM244YlFCUjRyZEk0ZGdteHFacFpLM2ttbjhMdUpYZWhFeWhBdzc1NHJ5VHBiM2lNamFyTkNjNHpoay8wSGhWd0JLN1pGS0srME42c3NGVmV2aUd6Y0NjN0dqRmg1MDFIZWVrUmRYUlVJcUJUdWZ0ZDRDNGJxRDkrOEx0UWdqN3gxRTh1NkVlOGwwZ1hPUS9BdVRuSEJ2L2FlaWlFOSt3ejF6YTNmbzkzdGp6dmVNR3o5aEJma3hYamRBQmdLZG42cmxmT0V4Z2lrWW44emNZejFhemJ2U2xQbWxwenh3VVMzZGhLZWdrcFEzQVQvYTFKU2xKQ2RaUHFxYmgyNS9BM2ZZOVdsYWhnSmJMYXZ6ZTNqa0NBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUI4R0ExVWRJd1FZTUJhQUZPK2hIK21jb1hLRzdBcWc0aEM3OHNCdFI5R0dNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBR1I0OVo0VEpnNEVsaTl3RkhIaGttekJCODNzbVEyMjRPdGduUHlENmtEMElLRGg2KzBqaUJ5cEk3QUZ1RU91SENVU29IK0c3UTRZWFZSeWVTZmdkM3FBbUdKRHhHMVFNcVpLQ3c3YTRzelBsRXEwOGRISEZNTUtXZXY2YURpdjhQNDNiekRRSWF6L2dtVXpONlN1aEszeWpIRWxVRzJJTkdMcXlCUTNLSm9OTW5yWmdGcmpMeW5sU2tRQzdJR3hHa3lnb251NHNXeTkzaGRHY0FDb0pBaG9IdDNUcGw2MThJS3kzSGF3S2pIY3ZncFJmMVAwdjR3dllOdzZzMXB5RnA5cnVoZEdRb0g3eDJrRFJvMFUxNm5wakxpMjVoVFltUDZ3Q044OFJzQ00xS0tnSHMyRW1rd1pQWHhBU3hsVFFzRDlRdVNsdHROWjNzeWFTcUMzby9yajF4MkVrUDZ6WXE2cWp4VllIZy9uMDcwUTZRRkgvTk8vVkh6RVo1UkJKL2hkNFR5b2Z0dG1VN2FpaUMrdWFoQmFsWnpjVk1HNG5IZ3U5WmpLbWlNclBzUkh0Vzl4MlhHRG9VZGdQczMzczc5R21BbEFZKzdBMndNRHFFZVVHMHZwY0kyU0dEbzNHVEVmbS9XeHlMczR6R2hrdy9mN1laeSt2dFdXWE9kM2tRSXZCeXRxcTkyYTlzTjFUZmswaXFuQ003VlBYUEhFaTZCZHZGd090NVk2eUVzQUFvY1c5MjhFdDdyQWJmMXNkRUVDdmVQaHBPc0ZZK3ZNS0REQUlaaStGWS9paDEzNzIrNGN2b3Fra0lwWHNQd3UrRzlHZndybVRMQUtpR0VyNnlRTkMvdktBR2xDSkdJc29rTFBSSkMxTzh0NEsydEZkOFhmL2s5VERFVm0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVVcxb1REM29uUkVRU2poQlFDckdpQTBjQ3Z3Z3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBd092YVJ4R0txYUdpTCtYM3h1dlNrZzNnZUlQVituRnovR3B5dHl5R2FNcE9uUEhFQVh2SDJmRzlWWXJPMTFvR0VOT3BtQXBCWlFjeFNYbElJTXAzQmh1czlzSFQxRzV0citJV0RyN3VxNHhkNmxXb2xmL1Q3dWpjREtSNEZzMDM5TElzTU5wYTM3d3k5SnpXSlZ5czFsb0pybHlDTXpXbWdSb29zUFpqV0NDMzJhcDlNYXFOVlMzMWlRdzg1VTZYRG55Z2FITkdoaERqdXpSMndFNTZRMmkvdmVsZWg1ekd3R0lQeTdxQ0JGVFVuYUkvMGMvZVdUU2JhWTV1OElUaklGZS9hSGRBeFlpaC9BVmxYV0lUNklTNFBEK0ZmS0J0YkVHNWU1RnhUeDRPalREQ1E5UDBTYUVIWXVVNXg2U0xkSHhYTEdPNXJ5VWNjb3YvZVFzKzEvSzhtK0d2WHBIRU5nWXhPanp0QURSdmlBallEWDJ4OVVpUWhaV0o2RW9qclEyTVdXczgrRFBmdHp0QmNUNVdNVVkrTTNuOGJRQlI0cmRJNGRnbXhxWnBaSzNrbW44THVKWGVoRXloQXc3NTRyeVRwYjNpTWphck5DYzR6aGsvMEhoVndCSzdaRktLKzBONnNzRlZldmlHemNDYzdHakZoNTAxSGVla1JkWFJVSXFCVHVmdGQ0QzRicUQ5KzhMdFFnajd4MUU4dTZFZThsMGdYT1EvQXVUbkhCdi9hZWlpRTkrd3oxemEzZm85M3RqenZlTUd6OWhCZmt4WGpkQUJnS2RuNnJsZk9FeGdpa1luOHpjWXoxYXpidlNsUG1scHp4d1VTM2RoS2Vna3BRM0FUL2ExSlNsSkNkWlBxcWJoMjUvQTNmWTlXbGFoZ0piTGF2emUzamtDQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQUdSNDlaNFRKZzRFbGk5d0ZISGhrbXpCQjgzc21RMjI0T3RnblB5RDZrRDBJS0RoNiswamlCeXBJN0FGdUVPdUhDVVNvSCtHN1E0WVhWUnllU2ZnZDNxQW1HSkR4RzFRTXFaS0N3N2E0c3pQbEVxMDhkSEhGTU1LV2V2NmFEaXY4UDQzYnpEUUlhei9nbVV6TjZTdWhLM3lqSEVsVUcySU5HTHF5QlEzS0pvTk1uclpnRnJqTHlubFNrUUM3SUd4R2t5Z29udTRzV3k5M2hkR2NBQ29KQWhvSHQzVHBsNjE4SUt5M0hhd0tqSGN2Z3BSZjFQMHY0d3ZZTnc2czFweUZwOXJ1aGRHUW9IN3gya0RSbzBVMTZucGpMaTI1aFRZbVA2d0NOODhSc0NNMUtLZ0hzMkVta3daUFh4QVN4bFRRc0Q5UXVTbHR0Tlozc3lhU3FDM28vcmoxeDJFa1A2ellxNnFqeFZZSGcvbjA3MFE2UUZIL05PL1ZIekVaNVJCSi9oZDRUeW9mdHRtVTdhaWlDK3VhaEJhbFp6Y1ZNRzRuSGd1OVpqS21pTXJQc1JIdFc5eDJYR0RvVWRnUHMzM3M3OUdtQWxBWSs3QTJ3TURxRWVVRzB2cGNJMlNHRG8zR1RFZm0vV3h5THM0ekdoa3cvZjdZWnkrdnRXV1hPZDNrUUl2Qnl0cXE5MmE5c04xVGZrMGlxbkNNN1ZQWFBIRWk2QmR2RndPdDVZNnlFc0FBb2NXOTI4RXQ3ckFiZjFzZEVFQ3ZlUGhwT3NGWSt2TUtEREFJWmkrRlkvaWgxMzcyKzRjdm9xa2tJcFhzUHd1K0c5R2Z3cm1UTEFLaUdFcjZ5UU5DL3ZLQUdsQ0pHSXNva0xQUkpDMU84dDRLMnRGZDhYZi9rOVRERVZtIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2RlbW8vc2Evd29ya2xvYWQtYTEiLCJleHAiOjE3ODk3NTUxNDksImlhdCI6MTc4OTY2ODc0OSwiaXN0aW8uaW8iOnsidHJ1c3RfZG9tYWluIjoiY2x1c3Rlci5sb2NhbCIsIndvcmtsb2FkIjp7Im5hbWUiOiJ3b3JrbG9hZC1hMSIsIm5hbWVzcGFjZSI6ImRlbW8iLCJwb2QiOiJ3b3JrbG9hZC1hMS03N2JmOWZiZmQtZ3AyMjUifX0sImp0aSI6IjRhNTU5MGI0ODE0MDQ3NDIyYWUwMzE1ODU1YTI3NzcyIiwiY25mIjp7Imp3ayI6eyJrdHkiOiJFQyIsImNydiI6IlAtMjU2IiwieCI6ImNlTzNsZ2pXTDlweGVOaTJnNXBXNUdHY2MweVQ0X0tPQ1lXTmFMUW5NX0EiLCJ5IjoiSGxaQXFub0FlYzdlamxIZFFiUVF4RUJBTDJpYWU5RTdDM0tWdTRJd3VsWSJ9fX0.RduuUyFKv2NLGXGtq6TJuiYDkV6g3QyKnKZHxZ-DJ__KvXirM84SWs2sgDo-vB7SZHZf-Q2WMuIZCkSbyoZMpstiSFzJsS9TkCJTCCVDZfC7ov7GrdArRlbl6OzjtHIxdoTK9nTAPOGTbIXc8EhYAJbNI-TeiW4W4a2aS-1APHFMmOX7HroIrse7yebvhds0tYci-_u7m8RK6-PCbyCqR0T-wgT6NdGNziWH03xy0_kPvqFjHKxgqzDy28T9ncp5IWS7pL8hzknaslDAEsb7K0xqf9dydzuLzQ9VqqjoUPOHOCxQZ-39RX-PyWo14tytAqeeKqFUfLv8HConHL1Fp4_ui6ZlfP-YX20whtzvAwhJ5ibxU64eQL-oD8fm1ymbvs_gq8RGaSgJzXju4_5I3FPZLL3UFDj6BVKcTSZ2Wxpo92MLWK6G27OA2FrmVzgk2TsQB1rBDMIQswY3jaf-6LmhRi94zVybFwRUpIcyoEM35hspHhWFL2hMvy7YsyX1txSPRVjWmMR0jysqoV6smvhmtD-8unJscS5yqHTZC4kjy4JdUIGOSnoC7i5zegTc8WqJcGW27zLUG8eV5yg5H1KbdZuvdm1HMPktHVoGFv8f3VYSaegyk_Mau1HJSxoty4YTeFbv-_8xoGT6bQS6nOAa7PKwtZS6yBIGjvd-gYM"
    ]
  }
}
```

Verify `X-Forwarded-Workload-Identity`:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-a2/headers' | grep -A2 "X-Forwarded-Workload-Identity"
```

```
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress"
    ],
```

---

## 5.0 Set up `workload-a1 → wpt-cel-egress → demo-waypoint → workload-a2`:

```bash
kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
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

kubectl --context $REMOTE_CONTEXT2 label namespace demo istio.io/use-waypoint=demo-waypoint --overwrite
kubectl --context $REMOTE_CONTEXT2 label namespace demo istio.io/ingress-use-waypoint=true --overwrite
```

Verify `workload-a1 → wpt-cel-egress → demo-waypoint → workload-a2`:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-a2/headers'
```

```
HTTP/1.1 200 OK
Access-Control-Allow-Credentials: true
Access-Control-Allow-Origin: *
Content-Type: application/json; charset=utf-8
Date: Thu, 17 Sep 2026 18:13:57 GMT
Transfer-Encoding: chunked

{
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Host": [
      "workload-a2.demo.svc.cluster.local"
    ],
    "User-Agent": [
      "curl/8.22.0"
    ],
    "Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWt3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE56RTJOVE13TTFvWERUTTJNRGt4TkRFMk5UTXdNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFEYU5oNEsxZUVScW8wTkxJSHB5M1k1SXhUbngycU43REJDTXJNZW43NnpBYytjTUovMGg2WE5yZGdDbmVjRnZzdk9iaXFtSmQrWXJUeDRUVHI0R09oR0hidVB0WnlSSUhSVnVKWFJtVUZzUlhHZGtDcE9uRkMvUlRVWkxMV1NpS3JTQlo5MnJMNFQvaHgvZVlSS2ljUkNEaE10NEFxaENNbjA4WlpSWW9hc1B4dExTZ05PRUJFdUIycHp6YTR5UHRpQVQ4Z28wZlV2RGM1R0tzMi9PK3JRUHNxTUNmbGJVNkpXdytyNThpdWRXdTlpakMrQzVLcWFtRXJaRFdnVlZCSDlYcms4a1lCZlROVnRURG43dGo1QjhOWWVTck41SjhKQjI5dmxOLzk1MlhLUFJmUysyK2gxUFNwQndSVjZza2V3QnV4K0xqVEQzalNsdVBMbXlGWUNmT3IwRjUwaVVBRURSNEtETUIycXFRMmRUWkVPbUNyTnlyeXErVllUNk5QWGduSWVvOHpzS0Y4Y0pacDJSRlpFaHhac2xtdEtBRUR5WXZib0t2YWx5TzIzMGlFK1RYWXJaSWpqbWdsVmhHNmx2cUVXL2l2L1hyZkRnV3FnUE0vcXUrY0cvd040Nk80bFdueEt0U2dBLy9iSHhYcFdKMDlIU0EzTE1YLytwWXVXWFgwMHVaeUZWdzBORHFHZmY1Yk1kcXlVbHB5QWxpT0dLaHFscG1aYUFFdDhmNkZnamg3RHNBTCtJUGxyaUZTamhROGx0aUJoTnhmWkRSRDd5UllCMmNqL1k1M2FqbW5PK2ZWeFBoREY4K0N0N2Vlc0FINERuVWNJK2hTRFo1MWVPWEhQY3NzQkh2bnJHNHBjZUs1SEJuZUhnTGVmRlA1U3ltTmNYZDJMNndJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZFN3U5SnQyMFBpUlBWemlRSGVsNzY4VzRQcXNNQjhHQTFVZEl3UVlNQmFBRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQmhNZXBVWFFrc3lTUm5qNnNTYUlUOEJ3ajhJWThRYlV3THFvRlhiaytWY1hhUnVNaUJlQXUxb2ZkaWFVU0dxclQ1dHZMa1NJVjlNWXpCeVZXODVuQmFTdjV6MVVKeVZ5UVlsQ0ZONjZ1NXZGUUJMV0h3VlJYTjhTc2xYTlJhdVpxcW5mWXE4eHVjTHVGb2JvbVMrc25XWjdhTEo3M1ZTTFB6NjdSRjg2UDRaTTVSdW83NkQwNTBrVmxFTS8yb0M3d3VJOGtHUXcyZkRRRUFwZTVWeExnUFNZTmNkUWtVYWF5L2EzdmlNVHBveWZGbzJZSjdpV2xkVWxWZ1BWbTdIcnBabkhtTG85TzcvaGZhMG5ueGo4MmFSbUdxblNud2VJakRNeEFkYlZ6RXB2aHhFMlVwVURER1lsS0VkbmtrYzQyRlQwdUhnK3NKa0taUVJVVE1aU1BtQ000YjE5UFZHeVBRdzk5dEUxdjQzZExDVmx4eU1WVGhMSmUwaEhrVkx5N1RVRHNMdTN6SWRGQURyZTJnNWVEaGFRbnZGSEpiVnVaREdZOW54dmdMVEpHL1lMUHZneXRORTd4bTBUZm1YSlNuM3FNdExLYm9FQi9YaEZiUXJLUXJ4MXQxNHRlYmpjVGxQMTJHY1YvdXh2eVpSdW90aXpXek5jWlJDb1VCWTFjMHFvOWZ1WjA5L1BTMzVTZVFXbFd2VVFlQ09VYk9vTFlKWGZmMVVrOFU1dFdRWGFpSGVnQzIvOERhNDY2WEZiWEZUOTlPRFNydnRYZ01rajc2UTdIMStVMVpPSE9yNHpiRTlXazRRRXhRNGdwVk5mMnIyOXQwSlRkMlBDUDUvVS9SdXdIUkJWTU5hRjlTNEdQemltZ0Y3aHNLUjY3NXVtbFF0ZFQyUlVGNkh3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5a3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUURhTmg0SzFlRVJxbzBOTElIcHkzWTVJeFRueDJxTjdEQkNNck1lbjc2ekFjK2NNSi8waDZYTnJkZ0NuZWNGdnN2T2JpcW1KZCtZclR4NFRUcjRHT2hHSGJ1UHRaeVJJSFJWdUpYUm1VRnNSWEdka0NwT25GQy9SVFVaTExXU2lLclNCWjkyckw0VC9oeC9lWVJLaWNSQ0RoTXQ0QXFoQ01uMDhaWlJZb2FzUHh0TFNnTk9FQkV1QjJwenphNHlQdGlBVDhnbzBmVXZEYzVHS3MyL08rclFQc3FNQ2ZsYlU2Sld3K3I1OGl1ZFd1OWlqQytDNUtxYW1FclpEV2dWVkJIOVhyazhrWUJmVE5WdFREbjd0ajVCOE5ZZVNyTjVKOEpCMjl2bE4vOTUyWEtQUmZTKzIraDFQU3BCd1JWNnNrZXdCdXgrTGpURDNqU2x1UExteUZZQ2ZPcjBGNTBpVUFFRFI0S0RNQjJxcVEyZFRaRU9tQ3JOeXJ5cStWWVQ2TlBYZ25JZW84enNLRjhjSlpwMlJGWkVoeFpzbG10S0FFRHlZdmJvS3ZhbHlPMjMwaUUrVFhZclpJamptZ2xWaEc2bHZxRVcvaXYvWHJmRGdXcWdQTS9xdStjRy93TjQ2TzRsV254S3RTZ0EvL2JIeFhwV0owOUhTQTNMTVgvK3BZdVdYWDAwdVp5RlZ3ME5EcUdmZjViTWRxeVVscHlBbGlPR0tocWxwbVphQUV0OGY2RmdqaDdEc0FMK0lQbHJpRlNqaFE4bHRpQmhOeGZaRFJEN3lSWUIyY2ovWTUzYWptbk8rZlZ4UGhERjgrQ3Q3ZWVzQUg0RG5VY0kraFNEWjUxZU9YSFBjc3NCSHZuckc0cGNlSzVIQm5lSGdMZWZGUDVTeW1OY1hkMkw2d0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRkU3dTlKdDIwUGlSUFZ6aVFIZWw3NjhXNFBxc01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFCaE1lcFVYUWtzeVNSbmo2c1NhSVQ4QndqOElZOFFiVXdMcW9GWGJrK1ZjWGFSdU1pQmVBdTFvZmRpYVVTR3FyVDV0dkxrU0lWOU1ZekJ5Vlc4NW5CYVN2NXoxVUp5VnlRWWxDRk42NnU1dkZRQkxXSHdWUlhOOFNzbFhOUmF1WnFxbmZZcTh4dWNMdUZvYm9tUytzbldaN2FMSjczVlNMUHo2N1JGODZQNFpNNVJ1bzc2RDA1MGtWbEVNLzJvQzd3dUk4a0dRdzJmRFFFQXBlNVZ4TGdQU1lOY2RRa1VhYXkvYTN2aU1UcG95ZkZvMllKN2lXbGRVbFZnUFZtN0hycFpuSG1MbzlPNy9oZmEwbm54ajgyYVJtR3FuU253ZUlqRE14QWRiVnpFcHZoeEUyVXBVRERHWWxLRWRua2tjNDJGVDB1SGcrc0prS1pRUlVUTVpTUG1DTTRiMTlQVkd5UFF3OTl0RTF2NDNkTENWbHh5TVZUaExKZTBoSGtWTHk3VFVEc0x1M3pJZEZBRHJlMmc1ZURoYVFudkZISmJWdVpER1k5bnh2Z0xUSkcvWUxQdmd5dE5FN3htMFRmbVhKU24zcU10TEtib0VCL1hoRmJRcktRcngxdDE0dGViamNUbFAxMkdjVi91eHZ5WlJ1b3Rpeld6TmNaUkNvVUJZMWMwcW85ZnVaMDkvUFMzNVNlUVdsV3ZVUWVDT1ViT29MWUpYZmYxVWs4VTV0V1FYYWlIZWdDMi84RGE0NjZYRmJYRlQ5OU9EU3J2dFhnTWtqNzZRN0gxK1UxWk9IT3I0emJFOVdrNFFFeFE0Z3BWTmYycjI5dDBKVGQyUENQNS9VL1J1d0hSQlZNTmFGOVM0R1B6aW1nRjdoc0tSNjc1dW1sUXRkVDJSVUY2SHc9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVVzFvVEQzb25SRVFTamhCUUNyR2lBMGNDdndnd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOekUyTlRNd00xb1hEVE0yTURreE5ERTJOVE13TTFvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUF3T3ZhUnhHS3FhR2lMK1gzeHV2U2tnM2dlSVBWK25Gei9HcHl0eXlHYU1wT25QSEVBWHZIMmZHOVZZck8xMW9HRU5PcG1BcEJaUWN4U1hsSUlNcDNCaHVzOXNIVDFHNXRyK0lXRHI3dXE0eGQ2bFdvbGYvVDd1amNES1I0RnMwMzlMSXNNTnBhMzd3eTlKeldKVnlzMWxvSnJseUNNeldtZ1Jvb3NQWmpXQ0MzMmFwOU1hcU5WUzMxaVF3ODVVNlhEbnlnYUhOR2hoRGp1elIyd0U1NlEyaS92ZWxlaDV6R3dHSVB5N3FDQkZUVW5hSS8wYy9lV1RTYmFZNXU4SVRqSUZlL2FIZEF4WWloL0FWbFhXSVQ2SVM0UEQrRmZLQnRiRUc1ZTVGeFR4NE9qVERDUTlQMFNhRUhZdVU1eDZTTGRIeFhMR081cnlVY2Nvdi9lUXMrMS9LOG0rR3ZYcEhFTmdZeE9qenRBRFJ2aUFqWURYMng5VWlRaFpXSjZFb2pyUTJNV1dzOCtEUGZ0enRCY1Q1V01VWStNM244YlFCUjRyZEk0ZGdteHFacFpLM2ttbjhMdUpYZWhFeWhBdzc1NHJ5VHBiM2lNamFyTkNjNHpoay8wSGhWd0JLN1pGS0srME42c3NGVmV2aUd6Y0NjN0dqRmg1MDFIZWVrUmRYUlVJcUJUdWZ0ZDRDNGJxRDkrOEx0UWdqN3gxRTh1NkVlOGwwZ1hPUS9BdVRuSEJ2L2FlaWlFOSt3ejF6YTNmbzkzdGp6dmVNR3o5aEJma3hYamRBQmdLZG42cmxmT0V4Z2lrWW44emNZejFhemJ2U2xQbWxwenh3VVMzZGhLZWdrcFEzQVQvYTFKU2xKQ2RaUHFxYmgyNS9BM2ZZOVdsYWhnSmJMYXZ6ZTNqa0NBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUI4R0ExVWRJd1FZTUJhQUZPK2hIK21jb1hLRzdBcWc0aEM3OHNCdFI5R0dNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBR1I0OVo0VEpnNEVsaTl3RkhIaGttekJCODNzbVEyMjRPdGduUHlENmtEMElLRGg2KzBqaUJ5cEk3QUZ1RU91SENVU29IK0c3UTRZWFZSeWVTZmdkM3FBbUdKRHhHMVFNcVpLQ3c3YTRzelBsRXEwOGRISEZNTUtXZXY2YURpdjhQNDNiekRRSWF6L2dtVXpONlN1aEszeWpIRWxVRzJJTkdMcXlCUTNLSm9OTW5yWmdGcmpMeW5sU2tRQzdJR3hHa3lnb251NHNXeTkzaGRHY0FDb0pBaG9IdDNUcGw2MThJS3kzSGF3S2pIY3ZncFJmMVAwdjR3dllOdzZzMXB5RnA5cnVoZEdRb0g3eDJrRFJvMFUxNm5wakxpMjVoVFltUDZ3Q044OFJzQ00xS0tnSHMyRW1rd1pQWHhBU3hsVFFzRDlRdVNsdHROWjNzeWFTcUMzby9yajF4MkVrUDZ6WXE2cWp4VllIZy9uMDcwUTZRRkgvTk8vVkh6RVo1UkJKL2hkNFR5b2Z0dG1VN2FpaUMrdWFoQmFsWnpjVk1HNG5IZ3U5WmpLbWlNclBzUkh0Vzl4MlhHRG9VZGdQczMzczc5R21BbEFZKzdBMndNRHFFZVVHMHZwY0kyU0dEbzNHVEVmbS9XeHlMczR6R2hrdy9mN1laeSt2dFdXWE9kM2tRSXZCeXRxcTkyYTlzTjFUZmswaXFuQ003VlBYUEhFaTZCZHZGd090NVk2eUVzQUFvY1c5MjhFdDdyQWJmMXNkRUVDdmVQaHBPc0ZZK3ZNS0REQUlaaStGWS9paDEzNzIrNGN2b3Fra0lwWHNQd3UrRzlHZndybVRMQUtpR0VyNnlRTkMvdktBR2xDSkdJc29rTFBSSkMxTzh0NEsydEZkOFhmL2s5VERFVm0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVVcxb1REM29uUkVRU2poQlFDckdpQTBjQ3Z3Z3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBd092YVJ4R0txYUdpTCtYM3h1dlNrZzNnZUlQVituRnovR3B5dHl5R2FNcE9uUEhFQVh2SDJmRzlWWXJPMTFvR0VOT3BtQXBCWlFjeFNYbElJTXAzQmh1czlzSFQxRzV0citJV0RyN3VxNHhkNmxXb2xmL1Q3dWpjREtSNEZzMDM5TElzTU5wYTM3d3k5SnpXSlZ5czFsb0pybHlDTXpXbWdSb29zUFpqV0NDMzJhcDlNYXFOVlMzMWlRdzg1VTZYRG55Z2FITkdoaERqdXpSMndFNTZRMmkvdmVsZWg1ekd3R0lQeTdxQ0JGVFVuYUkvMGMvZVdUU2JhWTV1OElUaklGZS9hSGRBeFlpaC9BVmxYV0lUNklTNFBEK0ZmS0J0YkVHNWU1RnhUeDRPalREQ1E5UDBTYUVIWXVVNXg2U0xkSHhYTEdPNXJ5VWNjb3YvZVFzKzEvSzhtK0d2WHBIRU5nWXhPanp0QURSdmlBallEWDJ4OVVpUWhaV0o2RW9qclEyTVdXczgrRFBmdHp0QmNUNVdNVVkrTTNuOGJRQlI0cmRJNGRnbXhxWnBaSzNrbW44THVKWGVoRXloQXc3NTRyeVRwYjNpTWphck5DYzR6aGsvMEhoVndCSzdaRktLKzBONnNzRlZldmlHemNDYzdHakZoNTAxSGVla1JkWFJVSXFCVHVmdGQ0QzRicUQ5KzhMdFFnajd4MUU4dTZFZThsMGdYT1EvQXVUbkhCdi9hZWlpRTkrd3oxemEzZm85M3RqenZlTUd6OWhCZmt4WGpkQUJnS2RuNnJsZk9FeGdpa1luOHpjWXoxYXpidlNsUG1scHp4d1VTM2RoS2Vna3BRM0FUL2ExSlNsSkNkWlBxcWJoMjUvQTNmWTlXbGFoZ0piTGF2emUzamtDQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQUdSNDlaNFRKZzRFbGk5d0ZISGhrbXpCQjgzc21RMjI0T3RnblB5RDZrRDBJS0RoNiswamlCeXBJN0FGdUVPdUhDVVNvSCtHN1E0WVhWUnllU2ZnZDNxQW1HSkR4RzFRTXFaS0N3N2E0c3pQbEVxMDhkSEhGTU1LV2V2NmFEaXY4UDQzYnpEUUlhei9nbVV6TjZTdWhLM3lqSEVsVUcySU5HTHF5QlEzS0pvTk1uclpnRnJqTHlubFNrUUM3SUd4R2t5Z29udTRzV3k5M2hkR2NBQ29KQWhvSHQzVHBsNjE4SUt5M0hhd0tqSGN2Z3BSZjFQMHY0d3ZZTnc2czFweUZwOXJ1aGRHUW9IN3gya0RSbzBVMTZucGpMaTI1aFRZbVA2d0NOODhSc0NNMUtLZ0hzMkVta3daUFh4QVN4bFRRc0Q5UXVTbHR0Tlozc3lhU3FDM28vcmoxeDJFa1A2ellxNnFqeFZZSGcvbjA3MFE2UUZIL05PL1ZIekVaNVJCSi9oZDRUeW9mdHRtVTdhaWlDK3VhaEJhbFp6Y1ZNRzRuSGd1OVpqS21pTXJQc1JIdFc5eDJYR0RvVWRnUHMzM3M3OUdtQWxBWSs3QTJ3TURxRWVVRzB2cGNJMlNHRG8zR1RFZm0vV3h5THM0ekdoa3cvZjdZWnkrdnRXV1hPZDNrUUl2Qnl0cXE5MmE5c04xVGZrMGlxbkNNN1ZQWFBIRWk2QmR2RndPdDVZNnlFc0FBb2NXOTI4RXQ3ckFiZjFzZEVFQ3ZlUGhwT3NGWSt2TUtEREFJWmkrRlkvaWgxMzcyKzRjdm9xa2tJcFhzUHd1K0c5R2Z3cm1UTEFLaUdFcjZ5UU5DL3ZLQUdsQ0pHSXNva0xQUkpDMU84dDRLMnRGZDhYZi9rOVRERVZtIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2RlbW8vc2EvZGVtby13YXlwb2ludCIsImV4cCI6MTc4OTc1NTIyNSwiaWF0IjoxNzg5NjY4ODI1LCJpc3Rpby5pbyI6eyJ0cnVzdF9kb21haW4iOiJjbHVzdGVyLmxvY2FsIiwid29ya2xvYWQiOnsibmFtZSI6ImRlbW8td2F5cG9pbnQiLCJuYW1lc3BhY2UiOiJkZW1vIiwicG9kIjoiZGVtby13YXlwb2ludC02ZjRiNzVkNDk1LXNoendzIn19LCJqdGkiOiI5NWIxMmY1ZDg3ZGFiNzg3N2MxZDFjN2NhMjE0ZmQ1OCIsImNuZiI6eyJqd2siOnsia3R5IjoiRUMiLCJjcnYiOiJQLTI1NiIsIngiOiI4ZFFnNEpxbkhmVURsanU3dlJqLXdldUxXSVpKUnY0dTFOVEVubUtNWFlJIiwieSI6ImNYTnVMeUZReWhENUM5bEdSMUNMM2RyVEtZWW11WTB2c3VwNlJHQ2M1eWMifX19.dPz371W7xJovo10kjAQK7qxmuXKD9ATk9tM4DFo0Pq6XaecmE1a9mFFYiE_3un-ItsHQToaoq-zzoKKXa2QlmrJZJ81t16N9QGm6bHx4gQUUyS0-6w4whWLggtlSAfQIeXmljY1oi9tdRF6VB0ePUtMpssNCl2PK4sHvaZGE_Ivk-Urm8KnamJgo4dswn2iQFDUVq7PFxabV9w77haf3dZzUHcrPxlX4Qr8xfy51wb0imN6BncfFpKWvpaA66YhKck51DvUvTlrVcup7wNpv-f0b_DTlPMMJM2D6gOvTGMojJ1ywYxoi9sZF6djHoLp39zUj2AzHjOV90nJirYf4L5pxdo--riWkT4DANv7Vxu-Z0i0HawrDG5lfJfVHiYlqS-tpZaVHrS66j4cnMezcGWKCD5y_QAnf4N0ierKqW5iWgimXr1jaF4fjMcDxqwYC4S0yvFiAWNJYP3GZaHDpys2UlqYajVq3ftUPkApLAcrBFQ-BXrmIn_kS6ZAv5eYHiWchaNlnKrE7ZC0SHwrH9SxUhiutbbkrTvSGtFLbhzms1SAP0HTrHcRqMuatT705gK0RvpSWh7g2CdfNiki12M6yE8qjKU4VDR1B9ujyO3c1J2BoJ-yRDBC59jtKb00kEoV_0RijLGJCymx7ZjZD_SzCd-oz-ypu60dC_u5ClFo"
    ],
    "Workload-Proof-Token": [
      "eyJ0eXAiOiJhcHBsaWNhdGlvbi93cHQrand0IiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2RlbW8vc2EvZGVtby13YXlwb2ludCIsImF1ZCI6Imh0dHBzOi8vd29ya2xvYWQtYTIuZGVtby5zdmMuY2x1c3Rlci5sb2NhbCIsImV4cCI6MTc4OTY2ODg5NywiaWF0IjoxNzg5NjY4ODM3LCJqdGkiOiJiOGMwNmNhMS03MjEzLTQwZDUtOTIxOC1lOTFkMmEwNmY4YjMiLCJ3dGgiOiJQZG1OM0VTUm45dmpDb1ppS003S1IwaFAwakx1bGdzRkVqRnNUQ0xLTnFZIiwib3RoIjp7IngtZm9yd2FyZGVkLXdvcmtsb2FkLWlkZW50aXR5IjoiOU5ZWV9XR2ZKR3RSbWJUTHpQYjltbDAxc3JoSXRYUDZoZGQyRnFtZWM5USIsIngtb3JpZ2luYWwtd29ya2xvYWQtaWRlbnRpdHktdG9rZW4iOiJKQ29UWHFHNVp3Ty16ZjduRmVNd3dRZTlua052a0xOMmpnMjhEMU9qM21FIn19.geiTgd4qvyocyy_aW1fwu39gJy5WwoMRUOasg2U3wfOWUqrYVeDsuYzJ8qKlH_eU__t98o-B-ebGFxCyvj1s6Q"
    ],
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/demo/sa/demo-waypoint"
    ],
    "X-Original-Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWt3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE56RTJOVE13TTFvWERUTTJNRGt4TkRFMk5UTXdNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFEYU5oNEsxZUVScW8wTkxJSHB5M1k1SXhUbngycU43REJDTXJNZW43NnpBYytjTUovMGg2WE5yZGdDbmVjRnZzdk9iaXFtSmQrWXJUeDRUVHI0R09oR0hidVB0WnlSSUhSVnVKWFJtVUZzUlhHZGtDcE9uRkMvUlRVWkxMV1NpS3JTQlo5MnJMNFQvaHgvZVlSS2ljUkNEaE10NEFxaENNbjA4WlpSWW9hc1B4dExTZ05PRUJFdUIycHp6YTR5UHRpQVQ4Z28wZlV2RGM1R0tzMi9PK3JRUHNxTUNmbGJVNkpXdytyNThpdWRXdTlpakMrQzVLcWFtRXJaRFdnVlZCSDlYcms4a1lCZlROVnRURG43dGo1QjhOWWVTck41SjhKQjI5dmxOLzk1MlhLUFJmUysyK2gxUFNwQndSVjZza2V3QnV4K0xqVEQzalNsdVBMbXlGWUNmT3IwRjUwaVVBRURSNEtETUIycXFRMmRUWkVPbUNyTnlyeXErVllUNk5QWGduSWVvOHpzS0Y4Y0pacDJSRlpFaHhac2xtdEtBRUR5WXZib0t2YWx5TzIzMGlFK1RYWXJaSWpqbWdsVmhHNmx2cUVXL2l2L1hyZkRnV3FnUE0vcXUrY0cvd040Nk80bFdueEt0U2dBLy9iSHhYcFdKMDlIU0EzTE1YLytwWXVXWFgwMHVaeUZWdzBORHFHZmY1Yk1kcXlVbHB5QWxpT0dLaHFscG1aYUFFdDhmNkZnamg3RHNBTCtJUGxyaUZTamhROGx0aUJoTnhmWkRSRDd5UllCMmNqL1k1M2FqbW5PK2ZWeFBoREY4K0N0N2Vlc0FINERuVWNJK2hTRFo1MWVPWEhQY3NzQkh2bnJHNHBjZUs1SEJuZUhnTGVmRlA1U3ltTmNYZDJMNndJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZFN3U5SnQyMFBpUlBWemlRSGVsNzY4VzRQcXNNQjhHQTFVZEl3UVlNQmFBRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQmhNZXBVWFFrc3lTUm5qNnNTYUlUOEJ3ajhJWThRYlV3THFvRlhiaytWY1hhUnVNaUJlQXUxb2ZkaWFVU0dxclQ1dHZMa1NJVjlNWXpCeVZXODVuQmFTdjV6MVVKeVZ5UVlsQ0ZONjZ1NXZGUUJMV0h3VlJYTjhTc2xYTlJhdVpxcW5mWXE4eHVjTHVGb2JvbVMrc25XWjdhTEo3M1ZTTFB6NjdSRjg2UDRaTTVSdW83NkQwNTBrVmxFTS8yb0M3d3VJOGtHUXcyZkRRRUFwZTVWeExnUFNZTmNkUWtVYWF5L2EzdmlNVHBveWZGbzJZSjdpV2xkVWxWZ1BWbTdIcnBabkhtTG85TzcvaGZhMG5ueGo4MmFSbUdxblNud2VJakRNeEFkYlZ6RXB2aHhFMlVwVURER1lsS0VkbmtrYzQyRlQwdUhnK3NKa0taUVJVVE1aU1BtQ000YjE5UFZHeVBRdzk5dEUxdjQzZExDVmx4eU1WVGhMSmUwaEhrVkx5N1RVRHNMdTN6SWRGQURyZTJnNWVEaGFRbnZGSEpiVnVaREdZOW54dmdMVEpHL1lMUHZneXRORTd4bTBUZm1YSlNuM3FNdExLYm9FQi9YaEZiUXJLUXJ4MXQxNHRlYmpjVGxQMTJHY1YvdXh2eVpSdW90aXpXek5jWlJDb1VCWTFjMHFvOWZ1WjA5L1BTMzVTZVFXbFd2VVFlQ09VYk9vTFlKWGZmMVVrOFU1dFdRWGFpSGVnQzIvOERhNDY2WEZiWEZUOTlPRFNydnRYZ01rajc2UTdIMStVMVpPSE9yNHpiRTlXazRRRXhRNGdwVk5mMnIyOXQwSlRkMlBDUDUvVS9SdXdIUkJWTU5hRjlTNEdQemltZ0Y3aHNLUjY3NXVtbFF0ZFQyUlVGNkh3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5a3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUURhTmg0SzFlRVJxbzBOTElIcHkzWTVJeFRueDJxTjdEQkNNck1lbjc2ekFjK2NNSi8waDZYTnJkZ0NuZWNGdnN2T2JpcW1KZCtZclR4NFRUcjRHT2hHSGJ1UHRaeVJJSFJWdUpYUm1VRnNSWEdka0NwT25GQy9SVFVaTExXU2lLclNCWjkyckw0VC9oeC9lWVJLaWNSQ0RoTXQ0QXFoQ01uMDhaWlJZb2FzUHh0TFNnTk9FQkV1QjJwenphNHlQdGlBVDhnbzBmVXZEYzVHS3MyL08rclFQc3FNQ2ZsYlU2Sld3K3I1OGl1ZFd1OWlqQytDNUtxYW1FclpEV2dWVkJIOVhyazhrWUJmVE5WdFREbjd0ajVCOE5ZZVNyTjVKOEpCMjl2bE4vOTUyWEtQUmZTKzIraDFQU3BCd1JWNnNrZXdCdXgrTGpURDNqU2x1UExteUZZQ2ZPcjBGNTBpVUFFRFI0S0RNQjJxcVEyZFRaRU9tQ3JOeXJ5cStWWVQ2TlBYZ25JZW84enNLRjhjSlpwMlJGWkVoeFpzbG10S0FFRHlZdmJvS3ZhbHlPMjMwaUUrVFhZclpJamptZ2xWaEc2bHZxRVcvaXYvWHJmRGdXcWdQTS9xdStjRy93TjQ2TzRsV254S3RTZ0EvL2JIeFhwV0owOUhTQTNMTVgvK3BZdVdYWDAwdVp5RlZ3ME5EcUdmZjViTWRxeVVscHlBbGlPR0tocWxwbVphQUV0OGY2RmdqaDdEc0FMK0lQbHJpRlNqaFE4bHRpQmhOeGZaRFJEN3lSWUIyY2ovWTUzYWptbk8rZlZ4UGhERjgrQ3Q3ZWVzQUg0RG5VY0kraFNEWjUxZU9YSFBjc3NCSHZuckc0cGNlSzVIQm5lSGdMZWZGUDVTeW1OY1hkMkw2d0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRkU3dTlKdDIwUGlSUFZ6aVFIZWw3NjhXNFBxc01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFCaE1lcFVYUWtzeVNSbmo2c1NhSVQ4QndqOElZOFFiVXdMcW9GWGJrK1ZjWGFSdU1pQmVBdTFvZmRpYVVTR3FyVDV0dkxrU0lWOU1ZekJ5Vlc4NW5CYVN2NXoxVUp5VnlRWWxDRk42NnU1dkZRQkxXSHdWUlhOOFNzbFhOUmF1WnFxbmZZcTh4dWNMdUZvYm9tUytzbldaN2FMSjczVlNMUHo2N1JGODZQNFpNNVJ1bzc2RDA1MGtWbEVNLzJvQzd3dUk4a0dRdzJmRFFFQXBlNVZ4TGdQU1lOY2RRa1VhYXkvYTN2aU1UcG95ZkZvMllKN2lXbGRVbFZnUFZtN0hycFpuSG1MbzlPNy9oZmEwbm54ajgyYVJtR3FuU253ZUlqRE14QWRiVnpFcHZoeEUyVXBVRERHWWxLRWRua2tjNDJGVDB1SGcrc0prS1pRUlVUTVpTUG1DTTRiMTlQVkd5UFF3OTl0RTF2NDNkTENWbHh5TVZUaExKZTBoSGtWTHk3VFVEc0x1M3pJZEZBRHJlMmc1ZURoYVFudkZISmJWdVpER1k5bnh2Z0xUSkcvWUxQdmd5dE5FN3htMFRmbVhKU24zcU10TEtib0VCL1hoRmJRcktRcngxdDE0dGViamNUbFAxMkdjVi91eHZ5WlJ1b3Rpeld6TmNaUkNvVUJZMWMwcW85ZnVaMDkvUFMzNVNlUVdsV3ZVUWVDT1ViT29MWUpYZmYxVWs4VTV0V1FYYWlIZWdDMi84RGE0NjZYRmJYRlQ5OU9EU3J2dFhnTWtqNzZRN0gxK1UxWk9IT3I0emJFOVdrNFFFeFE0Z3BWTmYycjI5dDBKVGQyUENQNS9VL1J1d0hSQlZNTmFGOVM0R1B6aW1nRjdoc0tSNjc1dW1sUXRkVDJSVUY2SHc9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVVzFvVEQzb25SRVFTamhCUUNyR2lBMGNDdndnd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOekUyTlRNd00xb1hEVE0yTURreE5ERTJOVE13TTFvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUF3T3ZhUnhHS3FhR2lMK1gzeHV2U2tnM2dlSVBWK25Gei9HcHl0eXlHYU1wT25QSEVBWHZIMmZHOVZZck8xMW9HRU5PcG1BcEJaUWN4U1hsSUlNcDNCaHVzOXNIVDFHNXRyK0lXRHI3dXE0eGQ2bFdvbGYvVDd1amNES1I0RnMwMzlMSXNNTnBhMzd3eTlKeldKVnlzMWxvSnJseUNNeldtZ1Jvb3NQWmpXQ0MzMmFwOU1hcU5WUzMxaVF3ODVVNlhEbnlnYUhOR2hoRGp1elIyd0U1NlEyaS92ZWxlaDV6R3dHSVB5N3FDQkZUVW5hSS8wYy9lV1RTYmFZNXU4SVRqSUZlL2FIZEF4WWloL0FWbFhXSVQ2SVM0UEQrRmZLQnRiRUc1ZTVGeFR4NE9qVERDUTlQMFNhRUhZdVU1eDZTTGRIeFhMR081cnlVY2Nvdi9lUXMrMS9LOG0rR3ZYcEhFTmdZeE9qenRBRFJ2aUFqWURYMng5VWlRaFpXSjZFb2pyUTJNV1dzOCtEUGZ0enRCY1Q1V01VWStNM244YlFCUjRyZEk0ZGdteHFacFpLM2ttbjhMdUpYZWhFeWhBdzc1NHJ5VHBiM2lNamFyTkNjNHpoay8wSGhWd0JLN1pGS0srME42c3NGVmV2aUd6Y0NjN0dqRmg1MDFIZWVrUmRYUlVJcUJUdWZ0ZDRDNGJxRDkrOEx0UWdqN3gxRTh1NkVlOGwwZ1hPUS9BdVRuSEJ2L2FlaWlFOSt3ejF6YTNmbzkzdGp6dmVNR3o5aEJma3hYamRBQmdLZG42cmxmT0V4Z2lrWW44emNZejFhemJ2U2xQbWxwenh3VVMzZGhLZWdrcFEzQVQvYTFKU2xKQ2RaUHFxYmgyNS9BM2ZZOVdsYWhnSmJMYXZ6ZTNqa0NBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUI4R0ExVWRJd1FZTUJhQUZPK2hIK21jb1hLRzdBcWc0aEM3OHNCdFI5R0dNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBR1I0OVo0VEpnNEVsaTl3RkhIaGttekJCODNzbVEyMjRPdGduUHlENmtEMElLRGg2KzBqaUJ5cEk3QUZ1RU91SENVU29IK0c3UTRZWFZSeWVTZmdkM3FBbUdKRHhHMVFNcVpLQ3c3YTRzelBsRXEwOGRISEZNTUtXZXY2YURpdjhQNDNiekRRSWF6L2dtVXpONlN1aEszeWpIRWxVRzJJTkdMcXlCUTNLSm9OTW5yWmdGcmpMeW5sU2tRQzdJR3hHa3lnb251NHNXeTkzaGRHY0FDb0pBaG9IdDNUcGw2MThJS3kzSGF3S2pIY3ZncFJmMVAwdjR3dllOdzZzMXB5RnA5cnVoZEdRb0g3eDJrRFJvMFUxNm5wakxpMjVoVFltUDZ3Q044OFJzQ00xS0tnSHMyRW1rd1pQWHhBU3hsVFFzRDlRdVNsdHROWjNzeWFTcUMzby9yajF4MkVrUDZ6WXE2cWp4VllIZy9uMDcwUTZRRkgvTk8vVkh6RVo1UkJKL2hkNFR5b2Z0dG1VN2FpaUMrdWFoQmFsWnpjVk1HNG5IZ3U5WmpLbWlNclBzUkh0Vzl4MlhHRG9VZGdQczMzczc5R21BbEFZKzdBMndNRHFFZVVHMHZwY0kyU0dEbzNHVEVmbS9XeHlMczR6R2hrdy9mN1laeSt2dFdXWE9kM2tRSXZCeXRxcTkyYTlzTjFUZmswaXFuQ003VlBYUEhFaTZCZHZGd090NVk2eUVzQUFvY1c5MjhFdDdyQWJmMXNkRUVDdmVQaHBPc0ZZK3ZNS0REQUlaaStGWS9paDEzNzIrNGN2b3Fra0lwWHNQd3UrRzlHZndybVRMQUtpR0VyNnlRTkMvdktBR2xDSkdJc29rTFBSSkMxTzh0NEsydEZkOFhmL2s5VERFVm0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVVcxb1REM29uUkVRU2poQlFDckdpQTBjQ3Z3Z3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBd092YVJ4R0txYUdpTCtYM3h1dlNrZzNnZUlQVituRnovR3B5dHl5R2FNcE9uUEhFQVh2SDJmRzlWWXJPMTFvR0VOT3BtQXBCWlFjeFNYbElJTXAzQmh1czlzSFQxRzV0citJV0RyN3VxNHhkNmxXb2xmL1Q3dWpjREtSNEZzMDM5TElzTU5wYTM3d3k5SnpXSlZ5czFsb0pybHlDTXpXbWdSb29zUFpqV0NDMzJhcDlNYXFOVlMzMWlRdzg1VTZYRG55Z2FITkdoaERqdXpSMndFNTZRMmkvdmVsZWg1ekd3R0lQeTdxQ0JGVFVuYUkvMGMvZVdUU2JhWTV1OElUaklGZS9hSGRBeFlpaC9BVmxYV0lUNklTNFBEK0ZmS0J0YkVHNWU1RnhUeDRPalREQ1E5UDBTYUVIWXVVNXg2U0xkSHhYTEdPNXJ5VWNjb3YvZVFzKzEvSzhtK0d2WHBIRU5nWXhPanp0QURSdmlBallEWDJ4OVVpUWhaV0o2RW9qclEyTVdXczgrRFBmdHp0QmNUNVdNVVkrTTNuOGJRQlI0cmRJNGRnbXhxWnBaSzNrbW44THVKWGVoRXloQXc3NTRyeVRwYjNpTWphck5DYzR6aGsvMEhoVndCSzdaRktLKzBONnNzRlZldmlHemNDYzdHakZoNTAxSGVla1JkWFJVSXFCVHVmdGQ0QzRicUQ5KzhMdFFnajd4MUU4dTZFZThsMGdYT1EvQXVUbkhCdi9hZWlpRTkrd3oxemEzZm85M3RqenZlTUd6OWhCZmt4WGpkQUJnS2RuNnJsZk9FeGdpa1luOHpjWXoxYXpidlNsUG1scHp4d1VTM2RoS2Vna3BRM0FUL2ExSlNsSkNkWlBxcWJoMjUvQTNmWTlXbGFoZ0piTGF2emUzamtDQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQUdSNDlaNFRKZzRFbGk5d0ZISGhrbXpCQjgzc21RMjI0T3RnblB5RDZrRDBJS0RoNiswamlCeXBJN0FGdUVPdUhDVVNvSCtHN1E0WVhWUnllU2ZnZDNxQW1HSkR4RzFRTXFaS0N3N2E0c3pQbEVxMDhkSEhGTU1LV2V2NmFEaXY4UDQzYnpEUUlhei9nbVV6TjZTdWhLM3lqSEVsVUcySU5HTHF5QlEzS0pvTk1uclpnRnJqTHlubFNrUUM3SUd4R2t5Z29udTRzV3k5M2hkR2NBQ29KQWhvSHQzVHBsNjE4SUt5M0hhd0tqSGN2Z3BSZjFQMHY0d3ZZTnc2czFweUZwOXJ1aGRHUW9IN3gya0RSbzBVMTZucGpMaTI1aFRZbVA2d0NOODhSc0NNMUtLZ0hzMkVta3daUFh4QVN4bFRRc0Q5UXVTbHR0Tlozc3lhU3FDM28vcmoxeDJFa1A2ellxNnFqeFZZSGcvbjA3MFE2UUZIL05PL1ZIekVaNVJCSi9oZDRUeW9mdHRtVTdhaWlDK3VhaEJhbFp6Y1ZNRzRuSGd1OVpqS21pTXJQc1JIdFc5eDJYR0RvVWRnUHMzM3M3OUdtQWxBWSs3QTJ3TURxRWVVRzB2cGNJMlNHRG8zR1RFZm0vV3h5THM0ekdoa3cvZjdZWnkrdnRXV1hPZDNrUUl2Qnl0cXE5MmE5c04xVGZrMGlxbkNNN1ZQWFBIRWk2QmR2RndPdDVZNnlFc0FBb2NXOTI4RXQ3ckFiZjFzZEVFQ3ZlUGhwT3NGWSt2TUtEREFJWmkrRlkvaWgxMzcyKzRjdm9xa2tJcFhzUHd1K0c5R2Z3cm1UTEFLaUdFcjZ5UU5DL3ZLQUdsQ0pHSXNva0xQUkpDMU84dDRLMnRGZDhYZi9rOVRERVZtIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2RlbW8vc2Evd29ya2xvYWQtYTEiLCJleHAiOjE3ODk3NTUxNDksImlhdCI6MTc4OTY2ODc0OSwiaXN0aW8uaW8iOnsidHJ1c3RfZG9tYWluIjoiY2x1c3Rlci5sb2NhbCIsIndvcmtsb2FkIjp7Im5hbWUiOiJ3b3JrbG9hZC1hMSIsIm5hbWVzcGFjZSI6ImRlbW8iLCJwb2QiOiJ3b3JrbG9hZC1hMS03N2JmOWZiZmQtZ3AyMjUifX0sImp0aSI6IjRhNTU5MGI0ODE0MDQ3NDIyYWUwMzE1ODU1YTI3NzcyIiwiY25mIjp7Imp3ayI6eyJrdHkiOiJFQyIsImNydiI6IlAtMjU2IiwieCI6ImNlTzNsZ2pXTDlweGVOaTJnNXBXNUdHY2MweVQ0X0tPQ1lXTmFMUW5NX0EiLCJ5IjoiSGxaQXFub0FlYzdlamxIZFFiUVF4RUJBTDJpYWU5RTdDM0tWdTRJd3VsWSJ9fX0.RduuUyFKv2NLGXGtq6TJuiYDkV6g3QyKnKZHxZ-DJ__KvXirM84SWs2sgDo-vB7SZHZf-Q2WMuIZCkSbyoZMpstiSFzJsS9TkCJTCCVDZfC7ov7GrdArRlbl6OzjtHIxdoTK9nTAPOGTbIXc8EhYAJbNI-TeiW4W4a2aS-1APHFMmOX7HroIrse7yebvhds0tYci-_u7m8RK6-PCbyCqR0T-wgT6NdGNziWH03xy0_kPvqFjHKxgqzDy28T9ncp5IWS7pL8hzknaslDAEsb7K0xqf9dydzuLzQ9VqqjoUPOHOCxQZ-39RX-PyWo14tytAqeeKqFUfLv8HConHL1Fp4_ui6ZlfP-YX20whtzvAwhJ5ibxU64eQL-oD8fm1ymbvs_gq8RGaSgJzXju4_5I3FPZLL3UFDj6BVKcTSZ2Wxpo92MLWK6G27OA2FrmVzgk2TsQB1rBDMIQswY3jaf-6LmhRi94zVybFwRUpIcyoEM35hspHhWFL2hMvy7YsyX1txSPRVjWmMR0jysqoV6smvhmtD-8unJscS5yqHTZC4kjy4JdUIGOSnoC7i5zegTc8WqJcGW27zLUG8eV5yg5H1KbdZuvdm1HMPktHVoGFv8f3VYSaegyk_Mau1HJSxoty4YTeFbv-_8xoGT6bQS6nOAa7PKwtZS6yBIGjvd-gYM"
    ]
  }
}
```

Verify `X-Forwarded-Workload-Identity`:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-a2/headers' | grep -A2 "X-Forwarded-Workload-Identity"
```

```
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/demo/sa/demo-waypoint"
    ],
```

---

## 6.0 Set up `workload-a1 → wpt-cel-egress → portfolio-b-pig → workload-b1`:

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
      # networking.istio.io/tunnel: "http"
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
  # - name: http
  - name: mtls
    port: 8080
    # protocol: HTTP
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
      # mode: "RequireProof"
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

Creaet dummy `demo` namespace to allow backendRefs to kind: Hostname (workload-b1.demo.mesh.internal) to resolve in HTTPRoute (portfolio-b-pig-to-workload-b1)
```bash
kubectl --context $REMOTE_CONTEXT1 create namespace demo
kubectl --context $REMOTE_CONTEXT1 label namespace demo istio.io/dataplane-mode=ambient
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

Verify `workload-a1 → wpt-cel-egress → portfolio-b-pig → workload-b1`:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-b1/headers'
```

```
HTTP/1.1 200 OK
access-control-allow-credentials: true
access-control-allow-origin: *
content-type: application/json; charset=utf-8
date: Thu, 17 Sep 2026 18:14:59 GMT
transfer-encoding: chunked

{
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Host": [
      "wpt-cel-egress.i-peg.svc.cluster.local:8080"
    ],
    "User-Agent": [
      "curl/8.22.0"
    ],
    "Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWt3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE56RTJOVE13TTFvWERUTTJNRGt4TkRFMk5UTXdNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFEYU5oNEsxZUVScW8wTkxJSHB5M1k1SXhUbngycU43REJDTXJNZW43NnpBYytjTUovMGg2WE5yZGdDbmVjRnZzdk9iaXFtSmQrWXJUeDRUVHI0R09oR0hidVB0WnlSSUhSVnVKWFJtVUZzUlhHZGtDcE9uRkMvUlRVWkxMV1NpS3JTQlo5MnJMNFQvaHgvZVlSS2ljUkNEaE10NEFxaENNbjA4WlpSWW9hc1B4dExTZ05PRUJFdUIycHp6YTR5UHRpQVQ4Z28wZlV2RGM1R0tzMi9PK3JRUHNxTUNmbGJVNkpXdytyNThpdWRXdTlpakMrQzVLcWFtRXJaRFdnVlZCSDlYcms4a1lCZlROVnRURG43dGo1QjhOWWVTck41SjhKQjI5dmxOLzk1MlhLUFJmUysyK2gxUFNwQndSVjZza2V3QnV4K0xqVEQzalNsdVBMbXlGWUNmT3IwRjUwaVVBRURSNEtETUIycXFRMmRUWkVPbUNyTnlyeXErVllUNk5QWGduSWVvOHpzS0Y4Y0pacDJSRlpFaHhac2xtdEtBRUR5WXZib0t2YWx5TzIzMGlFK1RYWXJaSWpqbWdsVmhHNmx2cUVXL2l2L1hyZkRnV3FnUE0vcXUrY0cvd040Nk80bFdueEt0U2dBLy9iSHhYcFdKMDlIU0EzTE1YLytwWXVXWFgwMHVaeUZWdzBORHFHZmY1Yk1kcXlVbHB5QWxpT0dLaHFscG1aYUFFdDhmNkZnamg3RHNBTCtJUGxyaUZTamhROGx0aUJoTnhmWkRSRDd5UllCMmNqL1k1M2FqbW5PK2ZWeFBoREY4K0N0N2Vlc0FINERuVWNJK2hTRFo1MWVPWEhQY3NzQkh2bnJHNHBjZUs1SEJuZUhnTGVmRlA1U3ltTmNYZDJMNndJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZFN3U5SnQyMFBpUlBWemlRSGVsNzY4VzRQcXNNQjhHQTFVZEl3UVlNQmFBRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQmhNZXBVWFFrc3lTUm5qNnNTYUlUOEJ3ajhJWThRYlV3THFvRlhiaytWY1hhUnVNaUJlQXUxb2ZkaWFVU0dxclQ1dHZMa1NJVjlNWXpCeVZXODVuQmFTdjV6MVVKeVZ5UVlsQ0ZONjZ1NXZGUUJMV0h3VlJYTjhTc2xYTlJhdVpxcW5mWXE4eHVjTHVGb2JvbVMrc25XWjdhTEo3M1ZTTFB6NjdSRjg2UDRaTTVSdW83NkQwNTBrVmxFTS8yb0M3d3VJOGtHUXcyZkRRRUFwZTVWeExnUFNZTmNkUWtVYWF5L2EzdmlNVHBveWZGbzJZSjdpV2xkVWxWZ1BWbTdIcnBabkhtTG85TzcvaGZhMG5ueGo4MmFSbUdxblNud2VJakRNeEFkYlZ6RXB2aHhFMlVwVURER1lsS0VkbmtrYzQyRlQwdUhnK3NKa0taUVJVVE1aU1BtQ000YjE5UFZHeVBRdzk5dEUxdjQzZExDVmx4eU1WVGhMSmUwaEhrVkx5N1RVRHNMdTN6SWRGQURyZTJnNWVEaGFRbnZGSEpiVnVaREdZOW54dmdMVEpHL1lMUHZneXRORTd4bTBUZm1YSlNuM3FNdExLYm9FQi9YaEZiUXJLUXJ4MXQxNHRlYmpjVGxQMTJHY1YvdXh2eVpSdW90aXpXek5jWlJDb1VCWTFjMHFvOWZ1WjA5L1BTMzVTZVFXbFd2VVFlQ09VYk9vTFlKWGZmMVVrOFU1dFdRWGFpSGVnQzIvOERhNDY2WEZiWEZUOTlPRFNydnRYZ01rajc2UTdIMStVMVpPSE9yNHpiRTlXazRRRXhRNGdwVk5mMnIyOXQwSlRkMlBDUDUvVS9SdXdIUkJWTU5hRjlTNEdQemltZ0Y3aHNLUjY3NXVtbFF0ZFQyUlVGNkh3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5a3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUURhTmg0SzFlRVJxbzBOTElIcHkzWTVJeFRueDJxTjdEQkNNck1lbjc2ekFjK2NNSi8waDZYTnJkZ0NuZWNGdnN2T2JpcW1KZCtZclR4NFRUcjRHT2hHSGJ1UHRaeVJJSFJWdUpYUm1VRnNSWEdka0NwT25GQy9SVFVaTExXU2lLclNCWjkyckw0VC9oeC9lWVJLaWNSQ0RoTXQ0QXFoQ01uMDhaWlJZb2FzUHh0TFNnTk9FQkV1QjJwenphNHlQdGlBVDhnbzBmVXZEYzVHS3MyL08rclFQc3FNQ2ZsYlU2Sld3K3I1OGl1ZFd1OWlqQytDNUtxYW1FclpEV2dWVkJIOVhyazhrWUJmVE5WdFREbjd0ajVCOE5ZZVNyTjVKOEpCMjl2bE4vOTUyWEtQUmZTKzIraDFQU3BCd1JWNnNrZXdCdXgrTGpURDNqU2x1UExteUZZQ2ZPcjBGNTBpVUFFRFI0S0RNQjJxcVEyZFRaRU9tQ3JOeXJ5cStWWVQ2TlBYZ25JZW84enNLRjhjSlpwMlJGWkVoeFpzbG10S0FFRHlZdmJvS3ZhbHlPMjMwaUUrVFhZclpJamptZ2xWaEc2bHZxRVcvaXYvWHJmRGdXcWdQTS9xdStjRy93TjQ2TzRsV254S3RTZ0EvL2JIeFhwV0owOUhTQTNMTVgvK3BZdVdYWDAwdVp5RlZ3ME5EcUdmZjViTWRxeVVscHlBbGlPR0tocWxwbVphQUV0OGY2RmdqaDdEc0FMK0lQbHJpRlNqaFE4bHRpQmhOeGZaRFJEN3lSWUIyY2ovWTUzYWptbk8rZlZ4UGhERjgrQ3Q3ZWVzQUg0RG5VY0kraFNEWjUxZU9YSFBjc3NCSHZuckc0cGNlSzVIQm5lSGdMZWZGUDVTeW1OY1hkMkw2d0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRkU3dTlKdDIwUGlSUFZ6aVFIZWw3NjhXNFBxc01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFCaE1lcFVYUWtzeVNSbmo2c1NhSVQ4QndqOElZOFFiVXdMcW9GWGJrK1ZjWGFSdU1pQmVBdTFvZmRpYVVTR3FyVDV0dkxrU0lWOU1ZekJ5Vlc4NW5CYVN2NXoxVUp5VnlRWWxDRk42NnU1dkZRQkxXSHdWUlhOOFNzbFhOUmF1WnFxbmZZcTh4dWNMdUZvYm9tUytzbldaN2FMSjczVlNMUHo2N1JGODZQNFpNNVJ1bzc2RDA1MGtWbEVNLzJvQzd3dUk4a0dRdzJmRFFFQXBlNVZ4TGdQU1lOY2RRa1VhYXkvYTN2aU1UcG95ZkZvMllKN2lXbGRVbFZnUFZtN0hycFpuSG1MbzlPNy9oZmEwbm54ajgyYVJtR3FuU253ZUlqRE14QWRiVnpFcHZoeEUyVXBVRERHWWxLRWRua2tjNDJGVDB1SGcrc0prS1pRUlVUTVpTUG1DTTRiMTlQVkd5UFF3OTl0RTF2NDNkTENWbHh5TVZUaExKZTBoSGtWTHk3VFVEc0x1M3pJZEZBRHJlMmc1ZURoYVFudkZISmJWdVpER1k5bnh2Z0xUSkcvWUxQdmd5dE5FN3htMFRmbVhKU24zcU10TEtib0VCL1hoRmJRcktRcngxdDE0dGViamNUbFAxMkdjVi91eHZ5WlJ1b3Rpeld6TmNaUkNvVUJZMWMwcW85ZnVaMDkvUFMzNVNlUVdsV3ZVUWVDT1ViT29MWUpYZmYxVWs4VTV0V1FYYWlIZWdDMi84RGE0NjZYRmJYRlQ5OU9EU3J2dFhnTWtqNzZRN0gxK1UxWk9IT3I0emJFOVdrNFFFeFE0Z3BWTmYycjI5dDBKVGQyUENQNS9VL1J1d0hSQlZNTmFGOVM0R1B6aW1nRjdoc0tSNjc1dW1sUXRkVDJSVUY2SHc9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVVzFvVEQzb25SRVFTamhCUUNyR2lBMGNDdndnd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOekUyTlRNd00xb1hEVE0yTURreE5ERTJOVE13TTFvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUF3T3ZhUnhHS3FhR2lMK1gzeHV2U2tnM2dlSVBWK25Gei9HcHl0eXlHYU1wT25QSEVBWHZIMmZHOVZZck8xMW9HRU5PcG1BcEJaUWN4U1hsSUlNcDNCaHVzOXNIVDFHNXRyK0lXRHI3dXE0eGQ2bFdvbGYvVDd1amNES1I0RnMwMzlMSXNNTnBhMzd3eTlKeldKVnlzMWxvSnJseUNNeldtZ1Jvb3NQWmpXQ0MzMmFwOU1hcU5WUzMxaVF3ODVVNlhEbnlnYUhOR2hoRGp1elIyd0U1NlEyaS92ZWxlaDV6R3dHSVB5N3FDQkZUVW5hSS8wYy9lV1RTYmFZNXU4SVRqSUZlL2FIZEF4WWloL0FWbFhXSVQ2SVM0UEQrRmZLQnRiRUc1ZTVGeFR4NE9qVERDUTlQMFNhRUhZdVU1eDZTTGRIeFhMR081cnlVY2Nvdi9lUXMrMS9LOG0rR3ZYcEhFTmdZeE9qenRBRFJ2aUFqWURYMng5VWlRaFpXSjZFb2pyUTJNV1dzOCtEUGZ0enRCY1Q1V01VWStNM244YlFCUjRyZEk0ZGdteHFacFpLM2ttbjhMdUpYZWhFeWhBdzc1NHJ5VHBiM2lNamFyTkNjNHpoay8wSGhWd0JLN1pGS0srME42c3NGVmV2aUd6Y0NjN0dqRmg1MDFIZWVrUmRYUlVJcUJUdWZ0ZDRDNGJxRDkrOEx0UWdqN3gxRTh1NkVlOGwwZ1hPUS9BdVRuSEJ2L2FlaWlFOSt3ejF6YTNmbzkzdGp6dmVNR3o5aEJma3hYamRBQmdLZG42cmxmT0V4Z2lrWW44emNZejFhemJ2U2xQbWxwenh3VVMzZGhLZWdrcFEzQVQvYTFKU2xKQ2RaUHFxYmgyNS9BM2ZZOVdsYWhnSmJMYXZ6ZTNqa0NBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUI4R0ExVWRJd1FZTUJhQUZPK2hIK21jb1hLRzdBcWc0aEM3OHNCdFI5R0dNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBR1I0OVo0VEpnNEVsaTl3RkhIaGttekJCODNzbVEyMjRPdGduUHlENmtEMElLRGg2KzBqaUJ5cEk3QUZ1RU91SENVU29IK0c3UTRZWFZSeWVTZmdkM3FBbUdKRHhHMVFNcVpLQ3c3YTRzelBsRXEwOGRISEZNTUtXZXY2YURpdjhQNDNiekRRSWF6L2dtVXpONlN1aEszeWpIRWxVRzJJTkdMcXlCUTNLSm9OTW5yWmdGcmpMeW5sU2tRQzdJR3hHa3lnb251NHNXeTkzaGRHY0FDb0pBaG9IdDNUcGw2MThJS3kzSGF3S2pIY3ZncFJmMVAwdjR3dllOdzZzMXB5RnA5cnVoZEdRb0g3eDJrRFJvMFUxNm5wakxpMjVoVFltUDZ3Q044OFJzQ00xS0tnSHMyRW1rd1pQWHhBU3hsVFFzRDlRdVNsdHROWjNzeWFTcUMzby9yajF4MkVrUDZ6WXE2cWp4VllIZy9uMDcwUTZRRkgvTk8vVkh6RVo1UkJKL2hkNFR5b2Z0dG1VN2FpaUMrdWFoQmFsWnpjVk1HNG5IZ3U5WmpLbWlNclBzUkh0Vzl4MlhHRG9VZGdQczMzczc5R21BbEFZKzdBMndNRHFFZVVHMHZwY0kyU0dEbzNHVEVmbS9XeHlMczR6R2hrdy9mN1laeSt2dFdXWE9kM2tRSXZCeXRxcTkyYTlzTjFUZmswaXFuQ003VlBYUEhFaTZCZHZGd090NVk2eUVzQUFvY1c5MjhFdDdyQWJmMXNkRUVDdmVQaHBPc0ZZK3ZNS0REQUlaaStGWS9paDEzNzIrNGN2b3Fra0lwWHNQd3UrRzlHZndybVRMQUtpR0VyNnlRTkMvdktBR2xDSkdJc29rTFBSSkMxTzh0NEsydEZkOFhmL2s5VERFVm0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVVcxb1REM29uUkVRU2poQlFDckdpQTBjQ3Z3Z3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBd092YVJ4R0txYUdpTCtYM3h1dlNrZzNnZUlQVituRnovR3B5dHl5R2FNcE9uUEhFQVh2SDJmRzlWWXJPMTFvR0VOT3BtQXBCWlFjeFNYbElJTXAzQmh1czlzSFQxRzV0citJV0RyN3VxNHhkNmxXb2xmL1Q3dWpjREtSNEZzMDM5TElzTU5wYTM3d3k5SnpXSlZ5czFsb0pybHlDTXpXbWdSb29zUFpqV0NDMzJhcDlNYXFOVlMzMWlRdzg1VTZYRG55Z2FITkdoaERqdXpSMndFNTZRMmkvdmVsZWg1ekd3R0lQeTdxQ0JGVFVuYUkvMGMvZVdUU2JhWTV1OElUaklGZS9hSGRBeFlpaC9BVmxYV0lUNklTNFBEK0ZmS0J0YkVHNWU1RnhUeDRPalREQ1E5UDBTYUVIWXVVNXg2U0xkSHhYTEdPNXJ5VWNjb3YvZVFzKzEvSzhtK0d2WHBIRU5nWXhPanp0QURSdmlBallEWDJ4OVVpUWhaV0o2RW9qclEyTVdXczgrRFBmdHp0QmNUNVdNVVkrTTNuOGJRQlI0cmRJNGRnbXhxWnBaSzNrbW44THVKWGVoRXloQXc3NTRyeVRwYjNpTWphck5DYzR6aGsvMEhoVndCSzdaRktLKzBONnNzRlZldmlHemNDYzdHakZoNTAxSGVla1JkWFJVSXFCVHVmdGQ0QzRicUQ5KzhMdFFnajd4MUU4dTZFZThsMGdYT1EvQXVUbkhCdi9hZWlpRTkrd3oxemEzZm85M3RqenZlTUd6OWhCZmt4WGpkQUJnS2RuNnJsZk9FeGdpa1luOHpjWXoxYXpidlNsUG1scHp4d1VTM2RoS2Vna3BRM0FUL2ExSlNsSkNkWlBxcWJoMjUvQTNmWTlXbGFoZ0piTGF2emUzamtDQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQUdSNDlaNFRKZzRFbGk5d0ZISGhrbXpCQjgzc21RMjI0T3RnblB5RDZrRDBJS0RoNiswamlCeXBJN0FGdUVPdUhDVVNvSCtHN1E0WVhWUnllU2ZnZDNxQW1HSkR4RzFRTXFaS0N3N2E0c3pQbEVxMDhkSEhGTU1LV2V2NmFEaXY4UDQzYnpEUUlhei9nbVV6TjZTdWhLM3lqSEVsVUcySU5HTHF5QlEzS0pvTk1uclpnRnJqTHlubFNrUUM3SUd4R2t5Z29udTRzV3k5M2hkR2NBQ29KQWhvSHQzVHBsNjE4SUt5M0hhd0tqSGN2Z3BSZjFQMHY0d3ZZTnc2czFweUZwOXJ1aGRHUW9IN3gya0RSbzBVMTZucGpMaTI1aFRZbVA2d0NOODhSc0NNMUtLZ0hzMkVta3daUFh4QVN4bFRRc0Q5UXVTbHR0Tlozc3lhU3FDM28vcmoxeDJFa1A2ellxNnFqeFZZSGcvbjA3MFE2UUZIL05PL1ZIekVaNVJCSi9oZDRUeW9mdHRtVTdhaWlDK3VhaEJhbFp6Y1ZNRzRuSGd1OVpqS21pTXJQc1JIdFc5eDJYR0RvVWRnUHMzM3M3OUdtQWxBWSs3QTJ3TURxRWVVRzB2cGNJMlNHRG8zR1RFZm0vV3h5THM0ekdoa3cvZjdZWnkrdnRXV1hPZDNrUUl2Qnl0cXE5MmE5c04xVGZrMGlxbkNNN1ZQWFBIRWk2QmR2RndPdDVZNnlFc0FBb2NXOTI4RXQ3ckFiZjFzZEVFQ3ZlUGhwT3NGWSt2TUtEREFJWmkrRlkvaWgxMzcyKzRjdm9xa2tJcFhzUHd1K0c5R2Z3cm1UTEFLaUdFcjZ5UU5DL3ZLQUdsQ0pHSXNva0xQUkpDMU84dDRLMnRGZDhYZi9rOVRERVZtIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2ktcGlnL3NhL3BvcnRmb2xpby1iLXBpZyIsImV4cCI6MTc4OTc1NTI5MywiaWF0IjoxNzg5NjY4ODkzLCJpc3Rpby5pbyI6eyJ0cnVzdF9kb21haW4iOiJjbHVzdGVyLmxvY2FsIiwid29ya2xvYWQiOnsibmFtZSI6InBvcnRmb2xpby1iLXBpZyIsIm5hbWVzcGFjZSI6ImktcGlnIiwicG9kIjoicG9ydGZvbGlvLWItcGlnLWI3YjliZDZkLWc0YzdsIn19LCJqdGkiOiJmMzI3MjA2MWQwNDRlOWM5ZjMzNDg3OGU0MGUwMjVhMSIsImNuZiI6eyJqd2siOnsia3R5IjoiRUMiLCJjcnYiOiJQLTI1NiIsIngiOiJGWEJxSlZMWVdfU3I4ZElNV0xBZnlBcGJ0M3hkOG5NWm95LThWbWJyVi1vIiwieSI6IjFuUUduT0NveEhoSldJaFlCMFlpTVllTk9VOUNXV2pmNzN6WExfV2dwVEEifX19.uhH11JbNsnzgOvBh1LyoW-tp3CxxW85mESt97vHeDFjf1jTDoB493FQwmwgL9DoLB53yOMoyq4bYxWyRE4EFjE3HdxyJX1i65sgXDw2U96YahJNv4bXSK4VD50BBLnMXsGhtYr9Blxa087GURCdEiapr4-UDEbw_6VzLDjJf77lfwrA4nv5iEYR8lBMe6EXHgYFqAgw9LWgk04-WyBNUnAlbvcBfgQH9Lcky_VeX__rfn3QSrPk5AkWuPWO9A54mda_-QIGjvL-8Loe_PDCFmsTmrXGvKra44uLIZ39ObQaFDpXTbxT81NRW3D443R-Ht_IdYsGH7CJ5k_rjlmVglrn6b1bNwTUdVDepPLlzKcQVry8-QheKgJWHWxdbZTo6xP1KAq96qR_nACyebRyyM8K6jXdWmFwCes-jjh5D22JAAUbxyXybRDDLIJH6ZQ8lJ9hTxTPtgtdYzYG93ms3wQZ-fEtEX53TF0DUYlAH2Znp_Z69yu2PffciryKXfTxhNzo8EJ6SXHQby9BOjS9VWu_HUYMI6McoE97wKqd4G3oZIGR1nneckyQ0HplEmnFlkTTTGs1A_WRntQdq4k1HyxNz_L6mWZXRGkJm59xafYnIFrxrlCVwzbMHnkAT0kiWrWDF166cY73O-15VsTkfomcWOpqO_ALJVEkSYYTn-RQ"
    ],
    "Workload-Proof-Token": [
      "eyJ0eXAiOiJhcHBsaWNhdGlvbi93cHQrand0IiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2ktcGlnL3NhL3BvcnRmb2xpby1iLXBpZyIsImF1ZCI6Imh0dHBzOi8vd29ya2xvYWQtYjEuZGVtby5tZXNoLmludGVybmFsIiwiZXhwIjoxNzg5NjY4OTU5LCJpYXQiOjE3ODk2Njg4OTksImp0aSI6IjUxMDUxMzllLTNmZmEtNGEzZi05NDI4LTZlZDU1ZTBlYmU0YiIsInd0aCI6IldCaUF5d1dyUmdmaW1tZ2p4d0ZpVWs5WWpMUENpSmJ6RVNma1RCVjJoclUiLCJvdGgiOnsieC1mb3J3YXJkZWQtd29ya2xvYWQtaWRlbnRpdHkiOiJ1NjVQS09kV29RdUl2ajdJZFFvMl9WcDVQaGZmY28tUDQ2S0ZQenlRSjc4IiwieC1vcmlnaW5hbC13b3JrbG9hZC1pZGVudGl0eS10b2tlbiI6IkpDb1RYcUc1WndPLXpmN25GZU13d1FlOW5rTnZrTE4yamcyOEQxT2ozbUUifX0.FvH5GO9alBH_g1Xj9fuDgL9Y3Lyyt_MGmGYbwWnxLs-GaXvME4EXQcht6nBmE9CJoNZHWSBxXctihs0_iFvaMA"
    ],
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/i-pig/sa/portfolio-b-pig"
    ],
    "X-Original-Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWt3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE56RTJOVE13TTFvWERUTTJNRGt4TkRFMk5UTXdNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFEYU5oNEsxZUVScW8wTkxJSHB5M1k1SXhUbngycU43REJDTXJNZW43NnpBYytjTUovMGg2WE5yZGdDbmVjRnZzdk9iaXFtSmQrWXJUeDRUVHI0R09oR0hidVB0WnlSSUhSVnVKWFJtVUZzUlhHZGtDcE9uRkMvUlRVWkxMV1NpS3JTQlo5MnJMNFQvaHgvZVlSS2ljUkNEaE10NEFxaENNbjA4WlpSWW9hc1B4dExTZ05PRUJFdUIycHp6YTR5UHRpQVQ4Z28wZlV2RGM1R0tzMi9PK3JRUHNxTUNmbGJVNkpXdytyNThpdWRXdTlpakMrQzVLcWFtRXJaRFdnVlZCSDlYcms4a1lCZlROVnRURG43dGo1QjhOWWVTck41SjhKQjI5dmxOLzk1MlhLUFJmUysyK2gxUFNwQndSVjZza2V3QnV4K0xqVEQzalNsdVBMbXlGWUNmT3IwRjUwaVVBRURSNEtETUIycXFRMmRUWkVPbUNyTnlyeXErVllUNk5QWGduSWVvOHpzS0Y4Y0pacDJSRlpFaHhac2xtdEtBRUR5WXZib0t2YWx5TzIzMGlFK1RYWXJaSWpqbWdsVmhHNmx2cUVXL2l2L1hyZkRnV3FnUE0vcXUrY0cvd040Nk80bFdueEt0U2dBLy9iSHhYcFdKMDlIU0EzTE1YLytwWXVXWFgwMHVaeUZWdzBORHFHZmY1Yk1kcXlVbHB5QWxpT0dLaHFscG1aYUFFdDhmNkZnamg3RHNBTCtJUGxyaUZTamhROGx0aUJoTnhmWkRSRDd5UllCMmNqL1k1M2FqbW5PK2ZWeFBoREY4K0N0N2Vlc0FINERuVWNJK2hTRFo1MWVPWEhQY3NzQkh2bnJHNHBjZUs1SEJuZUhnTGVmRlA1U3ltTmNYZDJMNndJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZFN3U5SnQyMFBpUlBWemlRSGVsNzY4VzRQcXNNQjhHQTFVZEl3UVlNQmFBRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQmhNZXBVWFFrc3lTUm5qNnNTYUlUOEJ3ajhJWThRYlV3THFvRlhiaytWY1hhUnVNaUJlQXUxb2ZkaWFVU0dxclQ1dHZMa1NJVjlNWXpCeVZXODVuQmFTdjV6MVVKeVZ5UVlsQ0ZONjZ1NXZGUUJMV0h3VlJYTjhTc2xYTlJhdVpxcW5mWXE4eHVjTHVGb2JvbVMrc25XWjdhTEo3M1ZTTFB6NjdSRjg2UDRaTTVSdW83NkQwNTBrVmxFTS8yb0M3d3VJOGtHUXcyZkRRRUFwZTVWeExnUFNZTmNkUWtVYWF5L2EzdmlNVHBveWZGbzJZSjdpV2xkVWxWZ1BWbTdIcnBabkhtTG85TzcvaGZhMG5ueGo4MmFSbUdxblNud2VJakRNeEFkYlZ6RXB2aHhFMlVwVURER1lsS0VkbmtrYzQyRlQwdUhnK3NKa0taUVJVVE1aU1BtQ000YjE5UFZHeVBRdzk5dEUxdjQzZExDVmx4eU1WVGhMSmUwaEhrVkx5N1RVRHNMdTN6SWRGQURyZTJnNWVEaGFRbnZGSEpiVnVaREdZOW54dmdMVEpHL1lMUHZneXRORTd4bTBUZm1YSlNuM3FNdExLYm9FQi9YaEZiUXJLUXJ4MXQxNHRlYmpjVGxQMTJHY1YvdXh2eVpSdW90aXpXek5jWlJDb1VCWTFjMHFvOWZ1WjA5L1BTMzVTZVFXbFd2VVFlQ09VYk9vTFlKWGZmMVVrOFU1dFdRWGFpSGVnQzIvOERhNDY2WEZiWEZUOTlPRFNydnRYZ01rajc2UTdIMStVMVpPSE9yNHpiRTlXazRRRXhRNGdwVk5mMnIyOXQwSlRkMlBDUDUvVS9SdXdIUkJWTU5hRjlTNEdQemltZ0Y3aHNLUjY3NXVtbFF0ZFQyUlVGNkh3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5a3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUURhTmg0SzFlRVJxbzBOTElIcHkzWTVJeFRueDJxTjdEQkNNck1lbjc2ekFjK2NNSi8waDZYTnJkZ0NuZWNGdnN2T2JpcW1KZCtZclR4NFRUcjRHT2hHSGJ1UHRaeVJJSFJWdUpYUm1VRnNSWEdka0NwT25GQy9SVFVaTExXU2lLclNCWjkyckw0VC9oeC9lWVJLaWNSQ0RoTXQ0QXFoQ01uMDhaWlJZb2FzUHh0TFNnTk9FQkV1QjJwenphNHlQdGlBVDhnbzBmVXZEYzVHS3MyL08rclFQc3FNQ2ZsYlU2Sld3K3I1OGl1ZFd1OWlqQytDNUtxYW1FclpEV2dWVkJIOVhyazhrWUJmVE5WdFREbjd0ajVCOE5ZZVNyTjVKOEpCMjl2bE4vOTUyWEtQUmZTKzIraDFQU3BCd1JWNnNrZXdCdXgrTGpURDNqU2x1UExteUZZQ2ZPcjBGNTBpVUFFRFI0S0RNQjJxcVEyZFRaRU9tQ3JOeXJ5cStWWVQ2TlBYZ25JZW84enNLRjhjSlpwMlJGWkVoeFpzbG10S0FFRHlZdmJvS3ZhbHlPMjMwaUUrVFhZclpJamptZ2xWaEc2bHZxRVcvaXYvWHJmRGdXcWdQTS9xdStjRy93TjQ2TzRsV254S3RTZ0EvL2JIeFhwV0owOUhTQTNMTVgvK3BZdVdYWDAwdVp5RlZ3ME5EcUdmZjViTWRxeVVscHlBbGlPR0tocWxwbVphQUV0OGY2RmdqaDdEc0FMK0lQbHJpRlNqaFE4bHRpQmhOeGZaRFJEN3lSWUIyY2ovWTUzYWptbk8rZlZ4UGhERjgrQ3Q3ZWVzQUg0RG5VY0kraFNEWjUxZU9YSFBjc3NCSHZuckc0cGNlSzVIQm5lSGdMZWZGUDVTeW1OY1hkMkw2d0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRkU3dTlKdDIwUGlSUFZ6aVFIZWw3NjhXNFBxc01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFCaE1lcFVYUWtzeVNSbmo2c1NhSVQ4QndqOElZOFFiVXdMcW9GWGJrK1ZjWGFSdU1pQmVBdTFvZmRpYVVTR3FyVDV0dkxrU0lWOU1ZekJ5Vlc4NW5CYVN2NXoxVUp5VnlRWWxDRk42NnU1dkZRQkxXSHdWUlhOOFNzbFhOUmF1WnFxbmZZcTh4dWNMdUZvYm9tUytzbldaN2FMSjczVlNMUHo2N1JGODZQNFpNNVJ1bzc2RDA1MGtWbEVNLzJvQzd3dUk4a0dRdzJmRFFFQXBlNVZ4TGdQU1lOY2RRa1VhYXkvYTN2aU1UcG95ZkZvMllKN2lXbGRVbFZnUFZtN0hycFpuSG1MbzlPNy9oZmEwbm54ajgyYVJtR3FuU253ZUlqRE14QWRiVnpFcHZoeEUyVXBVRERHWWxLRWRua2tjNDJGVDB1SGcrc0prS1pRUlVUTVpTUG1DTTRiMTlQVkd5UFF3OTl0RTF2NDNkTENWbHh5TVZUaExKZTBoSGtWTHk3VFVEc0x1M3pJZEZBRHJlMmc1ZURoYVFudkZISmJWdVpER1k5bnh2Z0xUSkcvWUxQdmd5dE5FN3htMFRmbVhKU24zcU10TEtib0VCL1hoRmJRcktRcngxdDE0dGViamNUbFAxMkdjVi91eHZ5WlJ1b3Rpeld6TmNaUkNvVUJZMWMwcW85ZnVaMDkvUFMzNVNlUVdsV3ZVUWVDT1ViT29MWUpYZmYxVWs4VTV0V1FYYWlIZWdDMi84RGE0NjZYRmJYRlQ5OU9EU3J2dFhnTWtqNzZRN0gxK1UxWk9IT3I0emJFOVdrNFFFeFE0Z3BWTmYycjI5dDBKVGQyUENQNS9VL1J1d0hSQlZNTmFGOVM0R1B6aW1nRjdoc0tSNjc1dW1sUXRkVDJSVUY2SHc9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVVzFvVEQzb25SRVFTamhCUUNyR2lBMGNDdndnd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOekUyTlRNd00xb1hEVE0yTURreE5ERTJOVE13TTFvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUF3T3ZhUnhHS3FhR2lMK1gzeHV2U2tnM2dlSVBWK25Gei9HcHl0eXlHYU1wT25QSEVBWHZIMmZHOVZZck8xMW9HRU5PcG1BcEJaUWN4U1hsSUlNcDNCaHVzOXNIVDFHNXRyK0lXRHI3dXE0eGQ2bFdvbGYvVDd1amNES1I0RnMwMzlMSXNNTnBhMzd3eTlKeldKVnlzMWxvSnJseUNNeldtZ1Jvb3NQWmpXQ0MzMmFwOU1hcU5WUzMxaVF3ODVVNlhEbnlnYUhOR2hoRGp1elIyd0U1NlEyaS92ZWxlaDV6R3dHSVB5N3FDQkZUVW5hSS8wYy9lV1RTYmFZNXU4SVRqSUZlL2FIZEF4WWloL0FWbFhXSVQ2SVM0UEQrRmZLQnRiRUc1ZTVGeFR4NE9qVERDUTlQMFNhRUhZdVU1eDZTTGRIeFhMR081cnlVY2Nvdi9lUXMrMS9LOG0rR3ZYcEhFTmdZeE9qenRBRFJ2aUFqWURYMng5VWlRaFpXSjZFb2pyUTJNV1dzOCtEUGZ0enRCY1Q1V01VWStNM244YlFCUjRyZEk0ZGdteHFacFpLM2ttbjhMdUpYZWhFeWhBdzc1NHJ5VHBiM2lNamFyTkNjNHpoay8wSGhWd0JLN1pGS0srME42c3NGVmV2aUd6Y0NjN0dqRmg1MDFIZWVrUmRYUlVJcUJUdWZ0ZDRDNGJxRDkrOEx0UWdqN3gxRTh1NkVlOGwwZ1hPUS9BdVRuSEJ2L2FlaWlFOSt3ejF6YTNmbzkzdGp6dmVNR3o5aEJma3hYamRBQmdLZG42cmxmT0V4Z2lrWW44emNZejFhemJ2U2xQbWxwenh3VVMzZGhLZWdrcFEzQVQvYTFKU2xKQ2RaUHFxYmgyNS9BM2ZZOVdsYWhnSmJMYXZ6ZTNqa0NBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUI4R0ExVWRJd1FZTUJhQUZPK2hIK21jb1hLRzdBcWc0aEM3OHNCdFI5R0dNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBR1I0OVo0VEpnNEVsaTl3RkhIaGttekJCODNzbVEyMjRPdGduUHlENmtEMElLRGg2KzBqaUJ5cEk3QUZ1RU91SENVU29IK0c3UTRZWFZSeWVTZmdkM3FBbUdKRHhHMVFNcVpLQ3c3YTRzelBsRXEwOGRISEZNTUtXZXY2YURpdjhQNDNiekRRSWF6L2dtVXpONlN1aEszeWpIRWxVRzJJTkdMcXlCUTNLSm9OTW5yWmdGcmpMeW5sU2tRQzdJR3hHa3lnb251NHNXeTkzaGRHY0FDb0pBaG9IdDNUcGw2MThJS3kzSGF3S2pIY3ZncFJmMVAwdjR3dllOdzZzMXB5RnA5cnVoZEdRb0g3eDJrRFJvMFUxNm5wakxpMjVoVFltUDZ3Q044OFJzQ00xS0tnSHMyRW1rd1pQWHhBU3hsVFFzRDlRdVNsdHROWjNzeWFTcUMzby9yajF4MkVrUDZ6WXE2cWp4VllIZy9uMDcwUTZRRkgvTk8vVkh6RVo1UkJKL2hkNFR5b2Z0dG1VN2FpaUMrdWFoQmFsWnpjVk1HNG5IZ3U5WmpLbWlNclBzUkh0Vzl4MlhHRG9VZGdQczMzczc5R21BbEFZKzdBMndNRHFFZVVHMHZwY0kyU0dEbzNHVEVmbS9XeHlMczR6R2hrdy9mN1laeSt2dFdXWE9kM2tRSXZCeXRxcTkyYTlzTjFUZmswaXFuQ003VlBYUEhFaTZCZHZGd090NVk2eUVzQUFvY1c5MjhFdDdyQWJmMXNkRUVDdmVQaHBPc0ZZK3ZNS0REQUlaaStGWS9paDEzNzIrNGN2b3Fra0lwWHNQd3UrRzlHZndybVRMQUtpR0VyNnlRTkMvdktBR2xDSkdJc29rTFBSSkMxTzh0NEsydEZkOFhmL2s5VERFVm0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVVcxb1REM29uUkVRU2poQlFDckdpQTBjQ3Z3Z3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBd092YVJ4R0txYUdpTCtYM3h1dlNrZzNnZUlQVituRnovR3B5dHl5R2FNcE9uUEhFQVh2SDJmRzlWWXJPMTFvR0VOT3BtQXBCWlFjeFNYbElJTXAzQmh1czlzSFQxRzV0citJV0RyN3VxNHhkNmxXb2xmL1Q3dWpjREtSNEZzMDM5TElzTU5wYTM3d3k5SnpXSlZ5czFsb0pybHlDTXpXbWdSb29zUFpqV0NDMzJhcDlNYXFOVlMzMWlRdzg1VTZYRG55Z2FITkdoaERqdXpSMndFNTZRMmkvdmVsZWg1ekd3R0lQeTdxQ0JGVFVuYUkvMGMvZVdUU2JhWTV1OElUaklGZS9hSGRBeFlpaC9BVmxYV0lUNklTNFBEK0ZmS0J0YkVHNWU1RnhUeDRPalREQ1E5UDBTYUVIWXVVNXg2U0xkSHhYTEdPNXJ5VWNjb3YvZVFzKzEvSzhtK0d2WHBIRU5nWXhPanp0QURSdmlBallEWDJ4OVVpUWhaV0o2RW9qclEyTVdXczgrRFBmdHp0QmNUNVdNVVkrTTNuOGJRQlI0cmRJNGRnbXhxWnBaSzNrbW44THVKWGVoRXloQXc3NTRyeVRwYjNpTWphck5DYzR6aGsvMEhoVndCSzdaRktLKzBONnNzRlZldmlHemNDYzdHakZoNTAxSGVla1JkWFJVSXFCVHVmdGQ0QzRicUQ5KzhMdFFnajd4MUU4dTZFZThsMGdYT1EvQXVUbkhCdi9hZWlpRTkrd3oxemEzZm85M3RqenZlTUd6OWhCZmt4WGpkQUJnS2RuNnJsZk9FeGdpa1luOHpjWXoxYXpidlNsUG1scHp4d1VTM2RoS2Vna3BRM0FUL2ExSlNsSkNkWlBxcWJoMjUvQTNmWTlXbGFoZ0piTGF2emUzamtDQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQUdSNDlaNFRKZzRFbGk5d0ZISGhrbXpCQjgzc21RMjI0T3RnblB5RDZrRDBJS0RoNiswamlCeXBJN0FGdUVPdUhDVVNvSCtHN1E0WVhWUnllU2ZnZDNxQW1HSkR4RzFRTXFaS0N3N2E0c3pQbEVxMDhkSEhGTU1LV2V2NmFEaXY4UDQzYnpEUUlhei9nbVV6TjZTdWhLM3lqSEVsVUcySU5HTHF5QlEzS0pvTk1uclpnRnJqTHlubFNrUUM3SUd4R2t5Z29udTRzV3k5M2hkR2NBQ29KQWhvSHQzVHBsNjE4SUt5M0hhd0tqSGN2Z3BSZjFQMHY0d3ZZTnc2czFweUZwOXJ1aGRHUW9IN3gya0RSbzBVMTZucGpMaTI1aFRZbVA2d0NOODhSc0NNMUtLZ0hzMkVta3daUFh4QVN4bFRRc0Q5UXVTbHR0Tlozc3lhU3FDM28vcmoxeDJFa1A2ellxNnFqeFZZSGcvbjA3MFE2UUZIL05PL1ZIekVaNVJCSi9oZDRUeW9mdHRtVTdhaWlDK3VhaEJhbFp6Y1ZNRzRuSGd1OVpqS21pTXJQc1JIdFc5eDJYR0RvVWRnUHMzM3M3OUdtQWxBWSs3QTJ3TURxRWVVRzB2cGNJMlNHRG8zR1RFZm0vV3h5THM0ekdoa3cvZjdZWnkrdnRXV1hPZDNrUUl2Qnl0cXE5MmE5c04xVGZrMGlxbkNNN1ZQWFBIRWk2QmR2RndPdDVZNnlFc0FBb2NXOTI4RXQ3ckFiZjFzZEVFQ3ZlUGhwT3NGWSt2TUtEREFJWmkrRlkvaWgxMzcyKzRjdm9xa2tJcFhzUHd1K0c5R2Z3cm1UTEFLaUdFcjZ5UU5DL3ZLQUdsQ0pHSXNva0xQUkpDMU84dDRLMnRGZDhYZi9rOVRERVZtIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2RlbW8vc2Evd29ya2xvYWQtYTEiLCJleHAiOjE3ODk3NTUxNDksImlhdCI6MTc4OTY2ODc0OSwiaXN0aW8uaW8iOnsidHJ1c3RfZG9tYWluIjoiY2x1c3Rlci5sb2NhbCIsIndvcmtsb2FkIjp7Im5hbWUiOiJ3b3JrbG9hZC1hMSIsIm5hbWVzcGFjZSI6ImRlbW8iLCJwb2QiOiJ3b3JrbG9hZC1hMS03N2JmOWZiZmQtZ3AyMjUifX0sImp0aSI6IjRhNTU5MGI0ODE0MDQ3NDIyYWUwMzE1ODU1YTI3NzcyIiwiY25mIjp7Imp3ayI6eyJrdHkiOiJFQyIsImNydiI6IlAtMjU2IiwieCI6ImNlTzNsZ2pXTDlweGVOaTJnNXBXNUdHY2MweVQ0X0tPQ1lXTmFMUW5NX0EiLCJ5IjoiSGxaQXFub0FlYzdlamxIZFFiUVF4RUJBTDJpYWU5RTdDM0tWdTRJd3VsWSJ9fX0.RduuUyFKv2NLGXGtq6TJuiYDkV6g3QyKnKZHxZ-DJ__KvXirM84SWs2sgDo-vB7SZHZf-Q2WMuIZCkSbyoZMpstiSFzJsS9TkCJTCCVDZfC7ov7GrdArRlbl6OzjtHIxdoTK9nTAPOGTbIXc8EhYAJbNI-TeiW4W4a2aS-1APHFMmOX7HroIrse7yebvhds0tYci-_u7m8RK6-PCbyCqR0T-wgT6NdGNziWH03xy0_kPvqFjHKxgqzDy28T9ncp5IWS7pL8hzknaslDAEsb7K0xqf9dydzuLzQ9VqqjoUPOHOCxQZ-39RX-PyWo14tytAqeeKqFUfLv8HConHL1Fp4_ui6ZlfP-YX20whtzvAwhJ5ibxU64eQL-oD8fm1ymbvs_gq8RGaSgJzXju4_5I3FPZLL3UFDj6BVKcTSZ2Wxpo92MLWK6G27OA2FrmVzgk2TsQB1rBDMIQswY3jaf-6LmhRi94zVybFwRUpIcyoEM35hspHhWFL2hMvy7YsyX1txSPRVjWmMR0jysqoV6smvhmtD-8unJscS5yqHTZC4kjy4JdUIGOSnoC7i5zegTc8WqJcGW27zLUG8eV5yg5H1KbdZuvdm1HMPktHVoGFv8f3VYSaegyk_Mau1HJSxoty4YTeFbv-_8xoGT6bQS6nOAa7PKwtZS6yBIGjvd-gYM"
    ]
  }
}
```

Verify `X-Forwarded-Workload-Identity`:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-b1/headers' | grep -A2 "X-Forwarded-Workload-Identity"
```

```
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/i-pig/sa/portfolio-b-pig"
    ],
```

---

## 7.0 Set up `workload-A → (ztunnel) → demo-egress-waypoint → (east-west) → pig-kgateway → (east-west) → demo-waypoint → workload-B`:

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

Verify `workload-A → (ztunnel) → demo-egress-waypoint → (east-west) → pig-kgateway → (east-west) → demo-waypoint → workload-B`:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-b1/headers'
```

```
HTTP/1.1 200 OK
access-control-allow-credentials: true
access-control-allow-origin: *
content-type: application/json; charset=utf-8
date: Thu, 17 Sep 2026 18:16:11 GMT
transfer-encoding: chunked

{
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Host": [
      "workload-b1.demo.mesh.internal"
    ],
    "User-Agent": [
      "curl/8.22.0"
    ],
    "Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWt3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE56RTJOVE13TTFvWERUTTJNRGt4TkRFMk5UTXdNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFEYU5oNEsxZUVScW8wTkxJSHB5M1k1SXhUbngycU43REJDTXJNZW43NnpBYytjTUovMGg2WE5yZGdDbmVjRnZzdk9iaXFtSmQrWXJUeDRUVHI0R09oR0hidVB0WnlSSUhSVnVKWFJtVUZzUlhHZGtDcE9uRkMvUlRVWkxMV1NpS3JTQlo5MnJMNFQvaHgvZVlSS2ljUkNEaE10NEFxaENNbjA4WlpSWW9hc1B4dExTZ05PRUJFdUIycHp6YTR5UHRpQVQ4Z28wZlV2RGM1R0tzMi9PK3JRUHNxTUNmbGJVNkpXdytyNThpdWRXdTlpakMrQzVLcWFtRXJaRFdnVlZCSDlYcms4a1lCZlROVnRURG43dGo1QjhOWWVTck41SjhKQjI5dmxOLzk1MlhLUFJmUysyK2gxUFNwQndSVjZza2V3QnV4K0xqVEQzalNsdVBMbXlGWUNmT3IwRjUwaVVBRURSNEtETUIycXFRMmRUWkVPbUNyTnlyeXErVllUNk5QWGduSWVvOHpzS0Y4Y0pacDJSRlpFaHhac2xtdEtBRUR5WXZib0t2YWx5TzIzMGlFK1RYWXJaSWpqbWdsVmhHNmx2cUVXL2l2L1hyZkRnV3FnUE0vcXUrY0cvd040Nk80bFdueEt0U2dBLy9iSHhYcFdKMDlIU0EzTE1YLytwWXVXWFgwMHVaeUZWdzBORHFHZmY1Yk1kcXlVbHB5QWxpT0dLaHFscG1aYUFFdDhmNkZnamg3RHNBTCtJUGxyaUZTamhROGx0aUJoTnhmWkRSRDd5UllCMmNqL1k1M2FqbW5PK2ZWeFBoREY4K0N0N2Vlc0FINERuVWNJK2hTRFo1MWVPWEhQY3NzQkh2bnJHNHBjZUs1SEJuZUhnTGVmRlA1U3ltTmNYZDJMNndJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZFN3U5SnQyMFBpUlBWemlRSGVsNzY4VzRQcXNNQjhHQTFVZEl3UVlNQmFBRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQmhNZXBVWFFrc3lTUm5qNnNTYUlUOEJ3ajhJWThRYlV3THFvRlhiaytWY1hhUnVNaUJlQXUxb2ZkaWFVU0dxclQ1dHZMa1NJVjlNWXpCeVZXODVuQmFTdjV6MVVKeVZ5UVlsQ0ZONjZ1NXZGUUJMV0h3VlJYTjhTc2xYTlJhdVpxcW5mWXE4eHVjTHVGb2JvbVMrc25XWjdhTEo3M1ZTTFB6NjdSRjg2UDRaTTVSdW83NkQwNTBrVmxFTS8yb0M3d3VJOGtHUXcyZkRRRUFwZTVWeExnUFNZTmNkUWtVYWF5L2EzdmlNVHBveWZGbzJZSjdpV2xkVWxWZ1BWbTdIcnBabkhtTG85TzcvaGZhMG5ueGo4MmFSbUdxblNud2VJakRNeEFkYlZ6RXB2aHhFMlVwVURER1lsS0VkbmtrYzQyRlQwdUhnK3NKa0taUVJVVE1aU1BtQ000YjE5UFZHeVBRdzk5dEUxdjQzZExDVmx4eU1WVGhMSmUwaEhrVkx5N1RVRHNMdTN6SWRGQURyZTJnNWVEaGFRbnZGSEpiVnVaREdZOW54dmdMVEpHL1lMUHZneXRORTd4bTBUZm1YSlNuM3FNdExLYm9FQi9YaEZiUXJLUXJ4MXQxNHRlYmpjVGxQMTJHY1YvdXh2eVpSdW90aXpXek5jWlJDb1VCWTFjMHFvOWZ1WjA5L1BTMzVTZVFXbFd2VVFlQ09VYk9vTFlKWGZmMVVrOFU1dFdRWGFpSGVnQzIvOERhNDY2WEZiWEZUOTlPRFNydnRYZ01rajc2UTdIMStVMVpPSE9yNHpiRTlXazRRRXhRNGdwVk5mMnIyOXQwSlRkMlBDUDUvVS9SdXdIUkJWTU5hRjlTNEdQemltZ0Y3aHNLUjY3NXVtbFF0ZFQyUlVGNkh3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5a3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUURhTmg0SzFlRVJxbzBOTElIcHkzWTVJeFRueDJxTjdEQkNNck1lbjc2ekFjK2NNSi8waDZYTnJkZ0NuZWNGdnN2T2JpcW1KZCtZclR4NFRUcjRHT2hHSGJ1UHRaeVJJSFJWdUpYUm1VRnNSWEdka0NwT25GQy9SVFVaTExXU2lLclNCWjkyckw0VC9oeC9lWVJLaWNSQ0RoTXQ0QXFoQ01uMDhaWlJZb2FzUHh0TFNnTk9FQkV1QjJwenphNHlQdGlBVDhnbzBmVXZEYzVHS3MyL08rclFQc3FNQ2ZsYlU2Sld3K3I1OGl1ZFd1OWlqQytDNUtxYW1FclpEV2dWVkJIOVhyazhrWUJmVE5WdFREbjd0ajVCOE5ZZVNyTjVKOEpCMjl2bE4vOTUyWEtQUmZTKzIraDFQU3BCd1JWNnNrZXdCdXgrTGpURDNqU2x1UExteUZZQ2ZPcjBGNTBpVUFFRFI0S0RNQjJxcVEyZFRaRU9tQ3JOeXJ5cStWWVQ2TlBYZ25JZW84enNLRjhjSlpwMlJGWkVoeFpzbG10S0FFRHlZdmJvS3ZhbHlPMjMwaUUrVFhZclpJamptZ2xWaEc2bHZxRVcvaXYvWHJmRGdXcWdQTS9xdStjRy93TjQ2TzRsV254S3RTZ0EvL2JIeFhwV0owOUhTQTNMTVgvK3BZdVdYWDAwdVp5RlZ3ME5EcUdmZjViTWRxeVVscHlBbGlPR0tocWxwbVphQUV0OGY2RmdqaDdEc0FMK0lQbHJpRlNqaFE4bHRpQmhOeGZaRFJEN3lSWUIyY2ovWTUzYWptbk8rZlZ4UGhERjgrQ3Q3ZWVzQUg0RG5VY0kraFNEWjUxZU9YSFBjc3NCSHZuckc0cGNlSzVIQm5lSGdMZWZGUDVTeW1OY1hkMkw2d0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRkU3dTlKdDIwUGlSUFZ6aVFIZWw3NjhXNFBxc01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFCaE1lcFVYUWtzeVNSbmo2c1NhSVQ4QndqOElZOFFiVXdMcW9GWGJrK1ZjWGFSdU1pQmVBdTFvZmRpYVVTR3FyVDV0dkxrU0lWOU1ZekJ5Vlc4NW5CYVN2NXoxVUp5VnlRWWxDRk42NnU1dkZRQkxXSHdWUlhOOFNzbFhOUmF1WnFxbmZZcTh4dWNMdUZvYm9tUytzbldaN2FMSjczVlNMUHo2N1JGODZQNFpNNVJ1bzc2RDA1MGtWbEVNLzJvQzd3dUk4a0dRdzJmRFFFQXBlNVZ4TGdQU1lOY2RRa1VhYXkvYTN2aU1UcG95ZkZvMllKN2lXbGRVbFZnUFZtN0hycFpuSG1MbzlPNy9oZmEwbm54ajgyYVJtR3FuU253ZUlqRE14QWRiVnpFcHZoeEUyVXBVRERHWWxLRWRua2tjNDJGVDB1SGcrc0prS1pRUlVUTVpTUG1DTTRiMTlQVkd5UFF3OTl0RTF2NDNkTENWbHh5TVZUaExKZTBoSGtWTHk3VFVEc0x1M3pJZEZBRHJlMmc1ZURoYVFudkZISmJWdVpER1k5bnh2Z0xUSkcvWUxQdmd5dE5FN3htMFRmbVhKU24zcU10TEtib0VCL1hoRmJRcktRcngxdDE0dGViamNUbFAxMkdjVi91eHZ5WlJ1b3Rpeld6TmNaUkNvVUJZMWMwcW85ZnVaMDkvUFMzNVNlUVdsV3ZVUWVDT1ViT29MWUpYZmYxVWs4VTV0V1FYYWlIZWdDMi84RGE0NjZYRmJYRlQ5OU9EU3J2dFhnTWtqNzZRN0gxK1UxWk9IT3I0emJFOVdrNFFFeFE0Z3BWTmYycjI5dDBKVGQyUENQNS9VL1J1d0hSQlZNTmFGOVM0R1B6aW1nRjdoc0tSNjc1dW1sUXRkVDJSVUY2SHc9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVVzFvVEQzb25SRVFTamhCUUNyR2lBMGNDdndnd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOekUyTlRNd00xb1hEVE0yTURreE5ERTJOVE13TTFvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUF3T3ZhUnhHS3FhR2lMK1gzeHV2U2tnM2dlSVBWK25Gei9HcHl0eXlHYU1wT25QSEVBWHZIMmZHOVZZck8xMW9HRU5PcG1BcEJaUWN4U1hsSUlNcDNCaHVzOXNIVDFHNXRyK0lXRHI3dXE0eGQ2bFdvbGYvVDd1amNES1I0RnMwMzlMSXNNTnBhMzd3eTlKeldKVnlzMWxvSnJseUNNeldtZ1Jvb3NQWmpXQ0MzMmFwOU1hcU5WUzMxaVF3ODVVNlhEbnlnYUhOR2hoRGp1elIyd0U1NlEyaS92ZWxlaDV6R3dHSVB5N3FDQkZUVW5hSS8wYy9lV1RTYmFZNXU4SVRqSUZlL2FIZEF4WWloL0FWbFhXSVQ2SVM0UEQrRmZLQnRiRUc1ZTVGeFR4NE9qVERDUTlQMFNhRUhZdVU1eDZTTGRIeFhMR081cnlVY2Nvdi9lUXMrMS9LOG0rR3ZYcEhFTmdZeE9qenRBRFJ2aUFqWURYMng5VWlRaFpXSjZFb2pyUTJNV1dzOCtEUGZ0enRCY1Q1V01VWStNM244YlFCUjRyZEk0ZGdteHFacFpLM2ttbjhMdUpYZWhFeWhBdzc1NHJ5VHBiM2lNamFyTkNjNHpoay8wSGhWd0JLN1pGS0srME42c3NGVmV2aUd6Y0NjN0dqRmg1MDFIZWVrUmRYUlVJcUJUdWZ0ZDRDNGJxRDkrOEx0UWdqN3gxRTh1NkVlOGwwZ1hPUS9BdVRuSEJ2L2FlaWlFOSt3ejF6YTNmbzkzdGp6dmVNR3o5aEJma3hYamRBQmdLZG42cmxmT0V4Z2lrWW44emNZejFhemJ2U2xQbWxwenh3VVMzZGhLZWdrcFEzQVQvYTFKU2xKQ2RaUHFxYmgyNS9BM2ZZOVdsYWhnSmJMYXZ6ZTNqa0NBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUI4R0ExVWRJd1FZTUJhQUZPK2hIK21jb1hLRzdBcWc0aEM3OHNCdFI5R0dNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBR1I0OVo0VEpnNEVsaTl3RkhIaGttekJCODNzbVEyMjRPdGduUHlENmtEMElLRGg2KzBqaUJ5cEk3QUZ1RU91SENVU29IK0c3UTRZWFZSeWVTZmdkM3FBbUdKRHhHMVFNcVpLQ3c3YTRzelBsRXEwOGRISEZNTUtXZXY2YURpdjhQNDNiekRRSWF6L2dtVXpONlN1aEszeWpIRWxVRzJJTkdMcXlCUTNLSm9OTW5yWmdGcmpMeW5sU2tRQzdJR3hHa3lnb251NHNXeTkzaGRHY0FDb0pBaG9IdDNUcGw2MThJS3kzSGF3S2pIY3ZncFJmMVAwdjR3dllOdzZzMXB5RnA5cnVoZEdRb0g3eDJrRFJvMFUxNm5wakxpMjVoVFltUDZ3Q044OFJzQ00xS0tnSHMyRW1rd1pQWHhBU3hsVFFzRDlRdVNsdHROWjNzeWFTcUMzby9yajF4MkVrUDZ6WXE2cWp4VllIZy9uMDcwUTZRRkgvTk8vVkh6RVo1UkJKL2hkNFR5b2Z0dG1VN2FpaUMrdWFoQmFsWnpjVk1HNG5IZ3U5WmpLbWlNclBzUkh0Vzl4MlhHRG9VZGdQczMzczc5R21BbEFZKzdBMndNRHFFZVVHMHZwY0kyU0dEbzNHVEVmbS9XeHlMczR6R2hrdy9mN1laeSt2dFdXWE9kM2tRSXZCeXRxcTkyYTlzTjFUZmswaXFuQ003VlBYUEhFaTZCZHZGd090NVk2eUVzQUFvY1c5MjhFdDdyQWJmMXNkRUVDdmVQaHBPc0ZZK3ZNS0REQUlaaStGWS9paDEzNzIrNGN2b3Fra0lwWHNQd3UrRzlHZndybVRMQUtpR0VyNnlRTkMvdktBR2xDSkdJc29rTFBSSkMxTzh0NEsydEZkOFhmL2s5VERFVm0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVVcxb1REM29uUkVRU2poQlFDckdpQTBjQ3Z3Z3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBd092YVJ4R0txYUdpTCtYM3h1dlNrZzNnZUlQVituRnovR3B5dHl5R2FNcE9uUEhFQVh2SDJmRzlWWXJPMTFvR0VOT3BtQXBCWlFjeFNYbElJTXAzQmh1czlzSFQxRzV0citJV0RyN3VxNHhkNmxXb2xmL1Q3dWpjREtSNEZzMDM5TElzTU5wYTM3d3k5SnpXSlZ5czFsb0pybHlDTXpXbWdSb29zUFpqV0NDMzJhcDlNYXFOVlMzMWlRdzg1VTZYRG55Z2FITkdoaERqdXpSMndFNTZRMmkvdmVsZWg1ekd3R0lQeTdxQ0JGVFVuYUkvMGMvZVdUU2JhWTV1OElUaklGZS9hSGRBeFlpaC9BVmxYV0lUNklTNFBEK0ZmS0J0YkVHNWU1RnhUeDRPalREQ1E5UDBTYUVIWXVVNXg2U0xkSHhYTEdPNXJ5VWNjb3YvZVFzKzEvSzhtK0d2WHBIRU5nWXhPanp0QURSdmlBallEWDJ4OVVpUWhaV0o2RW9qclEyTVdXczgrRFBmdHp0QmNUNVdNVVkrTTNuOGJRQlI0cmRJNGRnbXhxWnBaSzNrbW44THVKWGVoRXloQXc3NTRyeVRwYjNpTWphck5DYzR6aGsvMEhoVndCSzdaRktLKzBONnNzRlZldmlHemNDYzdHakZoNTAxSGVla1JkWFJVSXFCVHVmdGQ0QzRicUQ5KzhMdFFnajd4MUU4dTZFZThsMGdYT1EvQXVUbkhCdi9hZWlpRTkrd3oxemEzZm85M3RqenZlTUd6OWhCZmt4WGpkQUJnS2RuNnJsZk9FeGdpa1luOHpjWXoxYXpidlNsUG1scHp4d1VTM2RoS2Vna3BRM0FUL2ExSlNsSkNkWlBxcWJoMjUvQTNmWTlXbGFoZ0piTGF2emUzamtDQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQUdSNDlaNFRKZzRFbGk5d0ZISGhrbXpCQjgzc21RMjI0T3RnblB5RDZrRDBJS0RoNiswamlCeXBJN0FGdUVPdUhDVVNvSCtHN1E0WVhWUnllU2ZnZDNxQW1HSkR4RzFRTXFaS0N3N2E0c3pQbEVxMDhkSEhGTU1LV2V2NmFEaXY4UDQzYnpEUUlhei9nbVV6TjZTdWhLM3lqSEVsVUcySU5HTHF5QlEzS0pvTk1uclpnRnJqTHlubFNrUUM3SUd4R2t5Z29udTRzV3k5M2hkR2NBQ29KQWhvSHQzVHBsNjE4SUt5M0hhd0tqSGN2Z3BSZjFQMHY0d3ZZTnc2czFweUZwOXJ1aGRHUW9IN3gya0RSbzBVMTZucGpMaTI1aFRZbVA2d0NOODhSc0NNMUtLZ0hzMkVta3daUFh4QVN4bFRRc0Q5UXVTbHR0Tlozc3lhU3FDM28vcmoxeDJFa1A2ellxNnFqeFZZSGcvbjA3MFE2UUZIL05PL1ZIekVaNVJCSi9oZDRUeW9mdHRtVTdhaWlDK3VhaEJhbFp6Y1ZNRzRuSGd1OVpqS21pTXJQc1JIdFc5eDJYR0RvVWRnUHMzM3M3OUdtQWxBWSs3QTJ3TURxRWVVRzB2cGNJMlNHRG8zR1RFZm0vV3h5THM0ekdoa3cvZjdZWnkrdnRXV1hPZDNrUUl2Qnl0cXE5MmE5c04xVGZrMGlxbkNNN1ZQWFBIRWk2QmR2RndPdDVZNnlFc0FBb2NXOTI4RXQ3ckFiZjFzZEVFQ3ZlUGhwT3NGWSt2TUtEREFJWmkrRlkvaWgxMzcyKzRjdm9xa2tJcFhzUHd1K0c5R2Z3cm1UTEFLaUdFcjZ5UU5DL3ZLQUdsQ0pHSXNva0xQUkpDMU84dDRLMnRGZDhYZi9rOVRERVZtIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2RlbW8vc2EvZGVtby13YXlwb2ludCIsImV4cCI6MTc4OTc1NTM2MywiaWF0IjoxNzg5NjY4OTYzLCJpc3Rpby5pbyI6eyJ0cnVzdF9kb21haW4iOiJjbHVzdGVyLmxvY2FsIiwid29ya2xvYWQiOnsibmFtZSI6ImRlbW8td2F5cG9pbnQiLCJuYW1lc3BhY2UiOiJkZW1vIiwicG9kIjoiZGVtby13YXlwb2ludC01NmNjNzQ3N2Y5LXFucmI5In19LCJqdGkiOiI2ODY2MmY5Nzk4MzNkOTc0YTJkMGE1ZGI4NzIzNDhiNCIsImNuZiI6eyJqd2siOnsia3R5IjoiRUMiLCJjcnYiOiJQLTI1NiIsIngiOiJDU3lnRDJrbEZfMDBxN2VxMlB2RDFzeVNKaHphRU1OWm50RnZ2R3I5UG5nIiwieSI6Ik5qenNuU2tKcVpoWUxFOTJkYVhJcVlZQmN0OENTTDBUb0t6LXpGUF9RVzgifX19.vsJdJW1XyTbLBGl1tm_KjEG-dJ_CCspWr8-KwDReyXap8d2rDJoNxvOmJ9bh7_HaKFDES5cJ3RKJRVqQrilcPRa0yeO4Af0S1ys-4e91TDxe1TcCxKQmLQkyH1OiXwq6mAFl9kRVisdJGBHom2Rhxk1oSq01BXtcWPyDcN03eWJALyUuqy1cXGzJjaXqbXT0n956G8xtwgODPnnger8m5XFhdWOpOH2csnO-5YAb2sJIAzyrs_e74ibk8ysrmljTfMg_Kb28Y5uIF3PNEIxHDYxeLbJBBu30LMvPusKM1Zn1NW6vKCM_ud1ll5CfvAxXMsn9efsqkM6dgnXV5rL4RrvOydMQLp-G1z1FVlsVggEDFXdLvRs4ITGjAvUGSq223qAzP5zIB7071bEo2ARj3mpqkOB6TLBqEslht4_xSgJl5wD5ZhTvaVVkLZOJKnoGKUz-f8TzqLl1GIQ06FWFVn2w2qL5ImPCRA5kc6p98fO0SXJUWx8_MPXgVtgzbnp3S9cKq4E-l0mV1yGXPGBYMr_ttvwoYR8YsVdZNHV4ABU_bqEU92mj6IST4adsYYbfKlaAmVlwIdMeEIYY9tFiAsTg3WG5GAsr8Ttgnk5BecnluddPCYDNDOJ3_8Ej0Evp8TzRPr6DUfdS1BmJ_oikohWdK4GKPVZoZJD2d3nFy50"
    ],
    "Workload-Proof-Token": [
      "eyJ0eXAiOiJhcHBsaWNhdGlvbi93cHQrand0IiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2RlbW8vc2EvZGVtby13YXlwb2ludCIsImF1ZCI6Imh0dHBzOi8vd29ya2xvYWQtYjEuZGVtby5tZXNoLmludGVybmFsIiwiZXhwIjoxNzg5NjY5MDMxLCJpYXQiOjE3ODk2Njg5NzEsImp0aSI6IjA2YzU0ZmI2LTdlYWEtNDUyYS1iMzZiLTFjZGM5N2I5MTI4NiIsInd0aCI6IkROX0RpRU54WHM4WG9xbHd5bTB4Z3hzb2F5Y0pZTUN6LXFvU2Q5eWw3VVUiLCJvdGgiOnsieC1mb3J3YXJkZWQtd29ya2xvYWQtaWRlbnRpdHkiOiI1NW5peDNTRFFtdVFXSWxMeW82bEo5NG50SVpwdVpLNG9QWl81M0w5ajl3IiwieC1vcmlnaW5hbC13b3JrbG9hZC1pZGVudGl0eS10b2tlbiI6IkpDb1RYcUc1WndPLXpmN25GZU13d1FlOW5rTnZrTE4yamcyOEQxT2ozbUUifX0.Zh7avmN9ANhpmhlVTKpAIYd4EZlBjLB7XObcL4G1kpOj_OXB-lSC_sjbXPe69M5zy5cIvaZI8DHrjzXF6SY6PA"
    ],
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/i-pig/sa/portfolio-b-pig, spiffe://cluster.local/ns/demo/sa/demo-waypoint"
    ],
    "X-Original-Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWt3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE56RTJOVE13TTFvWERUTTJNRGt4TkRFMk5UTXdNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFEYU5oNEsxZUVScW8wTkxJSHB5M1k1SXhUbngycU43REJDTXJNZW43NnpBYytjTUovMGg2WE5yZGdDbmVjRnZzdk9iaXFtSmQrWXJUeDRUVHI0R09oR0hidVB0WnlSSUhSVnVKWFJtVUZzUlhHZGtDcE9uRkMvUlRVWkxMV1NpS3JTQlo5MnJMNFQvaHgvZVlSS2ljUkNEaE10NEFxaENNbjA4WlpSWW9hc1B4dExTZ05PRUJFdUIycHp6YTR5UHRpQVQ4Z28wZlV2RGM1R0tzMi9PK3JRUHNxTUNmbGJVNkpXdytyNThpdWRXdTlpakMrQzVLcWFtRXJaRFdnVlZCSDlYcms4a1lCZlROVnRURG43dGo1QjhOWWVTck41SjhKQjI5dmxOLzk1MlhLUFJmUysyK2gxUFNwQndSVjZza2V3QnV4K0xqVEQzalNsdVBMbXlGWUNmT3IwRjUwaVVBRURSNEtETUIycXFRMmRUWkVPbUNyTnlyeXErVllUNk5QWGduSWVvOHpzS0Y4Y0pacDJSRlpFaHhac2xtdEtBRUR5WXZib0t2YWx5TzIzMGlFK1RYWXJaSWpqbWdsVmhHNmx2cUVXL2l2L1hyZkRnV3FnUE0vcXUrY0cvd040Nk80bFdueEt0U2dBLy9iSHhYcFdKMDlIU0EzTE1YLytwWXVXWFgwMHVaeUZWdzBORHFHZmY1Yk1kcXlVbHB5QWxpT0dLaHFscG1aYUFFdDhmNkZnamg3RHNBTCtJUGxyaUZTamhROGx0aUJoTnhmWkRSRDd5UllCMmNqL1k1M2FqbW5PK2ZWeFBoREY4K0N0N2Vlc0FINERuVWNJK2hTRFo1MWVPWEhQY3NzQkh2bnJHNHBjZUs1SEJuZUhnTGVmRlA1U3ltTmNYZDJMNndJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZFN3U5SnQyMFBpUlBWemlRSGVsNzY4VzRQcXNNQjhHQTFVZEl3UVlNQmFBRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQmhNZXBVWFFrc3lTUm5qNnNTYUlUOEJ3ajhJWThRYlV3THFvRlhiaytWY1hhUnVNaUJlQXUxb2ZkaWFVU0dxclQ1dHZMa1NJVjlNWXpCeVZXODVuQmFTdjV6MVVKeVZ5UVlsQ0ZONjZ1NXZGUUJMV0h3VlJYTjhTc2xYTlJhdVpxcW5mWXE4eHVjTHVGb2JvbVMrc25XWjdhTEo3M1ZTTFB6NjdSRjg2UDRaTTVSdW83NkQwNTBrVmxFTS8yb0M3d3VJOGtHUXcyZkRRRUFwZTVWeExnUFNZTmNkUWtVYWF5L2EzdmlNVHBveWZGbzJZSjdpV2xkVWxWZ1BWbTdIcnBabkhtTG85TzcvaGZhMG5ueGo4MmFSbUdxblNud2VJakRNeEFkYlZ6RXB2aHhFMlVwVURER1lsS0VkbmtrYzQyRlQwdUhnK3NKa0taUVJVVE1aU1BtQ000YjE5UFZHeVBRdzk5dEUxdjQzZExDVmx4eU1WVGhMSmUwaEhrVkx5N1RVRHNMdTN6SWRGQURyZTJnNWVEaGFRbnZGSEpiVnVaREdZOW54dmdMVEpHL1lMUHZneXRORTd4bTBUZm1YSlNuM3FNdExLYm9FQi9YaEZiUXJLUXJ4MXQxNHRlYmpjVGxQMTJHY1YvdXh2eVpSdW90aXpXek5jWlJDb1VCWTFjMHFvOWZ1WjA5L1BTMzVTZVFXbFd2VVFlQ09VYk9vTFlKWGZmMVVrOFU1dFdRWGFpSGVnQzIvOERhNDY2WEZiWEZUOTlPRFNydnRYZ01rajc2UTdIMStVMVpPSE9yNHpiRTlXazRRRXhRNGdwVk5mMnIyOXQwSlRkMlBDUDUvVS9SdXdIUkJWTU5hRjlTNEdQemltZ0Y3aHNLUjY3NXVtbFF0ZFQyUlVGNkh3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5a3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUURhTmg0SzFlRVJxbzBOTElIcHkzWTVJeFRueDJxTjdEQkNNck1lbjc2ekFjK2NNSi8waDZYTnJkZ0NuZWNGdnN2T2JpcW1KZCtZclR4NFRUcjRHT2hHSGJ1UHRaeVJJSFJWdUpYUm1VRnNSWEdka0NwT25GQy9SVFVaTExXU2lLclNCWjkyckw0VC9oeC9lWVJLaWNSQ0RoTXQ0QXFoQ01uMDhaWlJZb2FzUHh0TFNnTk9FQkV1QjJwenphNHlQdGlBVDhnbzBmVXZEYzVHS3MyL08rclFQc3FNQ2ZsYlU2Sld3K3I1OGl1ZFd1OWlqQytDNUtxYW1FclpEV2dWVkJIOVhyazhrWUJmVE5WdFREbjd0ajVCOE5ZZVNyTjVKOEpCMjl2bE4vOTUyWEtQUmZTKzIraDFQU3BCd1JWNnNrZXdCdXgrTGpURDNqU2x1UExteUZZQ2ZPcjBGNTBpVUFFRFI0S0RNQjJxcVEyZFRaRU9tQ3JOeXJ5cStWWVQ2TlBYZ25JZW84enNLRjhjSlpwMlJGWkVoeFpzbG10S0FFRHlZdmJvS3ZhbHlPMjMwaUUrVFhZclpJamptZ2xWaEc2bHZxRVcvaXYvWHJmRGdXcWdQTS9xdStjRy93TjQ2TzRsV254S3RTZ0EvL2JIeFhwV0owOUhTQTNMTVgvK3BZdVdYWDAwdVp5RlZ3ME5EcUdmZjViTWRxeVVscHlBbGlPR0tocWxwbVphQUV0OGY2RmdqaDdEc0FMK0lQbHJpRlNqaFE4bHRpQmhOeGZaRFJEN3lSWUIyY2ovWTUzYWptbk8rZlZ4UGhERjgrQ3Q3ZWVzQUg0RG5VY0kraFNEWjUxZU9YSFBjc3NCSHZuckc0cGNlSzVIQm5lSGdMZWZGUDVTeW1OY1hkMkw2d0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRkU3dTlKdDIwUGlSUFZ6aVFIZWw3NjhXNFBxc01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFCaE1lcFVYUWtzeVNSbmo2c1NhSVQ4QndqOElZOFFiVXdMcW9GWGJrK1ZjWGFSdU1pQmVBdTFvZmRpYVVTR3FyVDV0dkxrU0lWOU1ZekJ5Vlc4NW5CYVN2NXoxVUp5VnlRWWxDRk42NnU1dkZRQkxXSHdWUlhOOFNzbFhOUmF1WnFxbmZZcTh4dWNMdUZvYm9tUytzbldaN2FMSjczVlNMUHo2N1JGODZQNFpNNVJ1bzc2RDA1MGtWbEVNLzJvQzd3dUk4a0dRdzJmRFFFQXBlNVZ4TGdQU1lOY2RRa1VhYXkvYTN2aU1UcG95ZkZvMllKN2lXbGRVbFZnUFZtN0hycFpuSG1MbzlPNy9oZmEwbm54ajgyYVJtR3FuU253ZUlqRE14QWRiVnpFcHZoeEUyVXBVRERHWWxLRWRua2tjNDJGVDB1SGcrc0prS1pRUlVUTVpTUG1DTTRiMTlQVkd5UFF3OTl0RTF2NDNkTENWbHh5TVZUaExKZTBoSGtWTHk3VFVEc0x1M3pJZEZBRHJlMmc1ZURoYVFudkZISmJWdVpER1k5bnh2Z0xUSkcvWUxQdmd5dE5FN3htMFRmbVhKU24zcU10TEtib0VCL1hoRmJRcktRcngxdDE0dGViamNUbFAxMkdjVi91eHZ5WlJ1b3Rpeld6TmNaUkNvVUJZMWMwcW85ZnVaMDkvUFMzNVNlUVdsV3ZVUWVDT1ViT29MWUpYZmYxVWs4VTV0V1FYYWlIZWdDMi84RGE0NjZYRmJYRlQ5OU9EU3J2dFhnTWtqNzZRN0gxK1UxWk9IT3I0emJFOVdrNFFFeFE0Z3BWTmYycjI5dDBKVGQyUENQNS9VL1J1d0hSQlZNTmFGOVM0R1B6aW1nRjdoc0tSNjc1dW1sUXRkVDJSVUY2SHc9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVVzFvVEQzb25SRVFTamhCUUNyR2lBMGNDdndnd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOekUyTlRNd00xb1hEVE0yTURreE5ERTJOVE13TTFvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUF3T3ZhUnhHS3FhR2lMK1gzeHV2U2tnM2dlSVBWK25Gei9HcHl0eXlHYU1wT25QSEVBWHZIMmZHOVZZck8xMW9HRU5PcG1BcEJaUWN4U1hsSUlNcDNCaHVzOXNIVDFHNXRyK0lXRHI3dXE0eGQ2bFdvbGYvVDd1amNES1I0RnMwMzlMSXNNTnBhMzd3eTlKeldKVnlzMWxvSnJseUNNeldtZ1Jvb3NQWmpXQ0MzMmFwOU1hcU5WUzMxaVF3ODVVNlhEbnlnYUhOR2hoRGp1elIyd0U1NlEyaS92ZWxlaDV6R3dHSVB5N3FDQkZUVW5hSS8wYy9lV1RTYmFZNXU4SVRqSUZlL2FIZEF4WWloL0FWbFhXSVQ2SVM0UEQrRmZLQnRiRUc1ZTVGeFR4NE9qVERDUTlQMFNhRUhZdVU1eDZTTGRIeFhMR081cnlVY2Nvdi9lUXMrMS9LOG0rR3ZYcEhFTmdZeE9qenRBRFJ2aUFqWURYMng5VWlRaFpXSjZFb2pyUTJNV1dzOCtEUGZ0enRCY1Q1V01VWStNM244YlFCUjRyZEk0ZGdteHFacFpLM2ttbjhMdUpYZWhFeWhBdzc1NHJ5VHBiM2lNamFyTkNjNHpoay8wSGhWd0JLN1pGS0srME42c3NGVmV2aUd6Y0NjN0dqRmg1MDFIZWVrUmRYUlVJcUJUdWZ0ZDRDNGJxRDkrOEx0UWdqN3gxRTh1NkVlOGwwZ1hPUS9BdVRuSEJ2L2FlaWlFOSt3ejF6YTNmbzkzdGp6dmVNR3o5aEJma3hYamRBQmdLZG42cmxmT0V4Z2lrWW44emNZejFhemJ2U2xQbWxwenh3VVMzZGhLZWdrcFEzQVQvYTFKU2xKQ2RaUHFxYmgyNS9BM2ZZOVdsYWhnSmJMYXZ6ZTNqa0NBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUI4R0ExVWRJd1FZTUJhQUZPK2hIK21jb1hLRzdBcWc0aEM3OHNCdFI5R0dNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBR1I0OVo0VEpnNEVsaTl3RkhIaGttekJCODNzbVEyMjRPdGduUHlENmtEMElLRGg2KzBqaUJ5cEk3QUZ1RU91SENVU29IK0c3UTRZWFZSeWVTZmdkM3FBbUdKRHhHMVFNcVpLQ3c3YTRzelBsRXEwOGRISEZNTUtXZXY2YURpdjhQNDNiekRRSWF6L2dtVXpONlN1aEszeWpIRWxVRzJJTkdMcXlCUTNLSm9OTW5yWmdGcmpMeW5sU2tRQzdJR3hHa3lnb251NHNXeTkzaGRHY0FDb0pBaG9IdDNUcGw2MThJS3kzSGF3S2pIY3ZncFJmMVAwdjR3dllOdzZzMXB5RnA5cnVoZEdRb0g3eDJrRFJvMFUxNm5wakxpMjVoVFltUDZ3Q044OFJzQ00xS0tnSHMyRW1rd1pQWHhBU3hsVFFzRDlRdVNsdHROWjNzeWFTcUMzby9yajF4MkVrUDZ6WXE2cWp4VllIZy9uMDcwUTZRRkgvTk8vVkh6RVo1UkJKL2hkNFR5b2Z0dG1VN2FpaUMrdWFoQmFsWnpjVk1HNG5IZ3U5WmpLbWlNclBzUkh0Vzl4MlhHRG9VZGdQczMzczc5R21BbEFZKzdBMndNRHFFZVVHMHZwY0kyU0dEbzNHVEVmbS9XeHlMczR6R2hrdy9mN1laeSt2dFdXWE9kM2tRSXZCeXRxcTkyYTlzTjFUZmswaXFuQ003VlBYUEhFaTZCZHZGd090NVk2eUVzQUFvY1c5MjhFdDdyQWJmMXNkRUVDdmVQaHBPc0ZZK3ZNS0REQUlaaStGWS9paDEzNzIrNGN2b3Fra0lwWHNQd3UrRzlHZndybVRMQUtpR0VyNnlRTkMvdktBR2xDSkdJc29rTFBSSkMxTzh0NEsydEZkOFhmL2s5VERFVm0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVVcxb1REM29uUkVRU2poQlFDckdpQTBjQ3Z3Z3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TnpFMk5UTXdNMW9YRFRNMk1Ea3hOREUyTlRNd00xb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBd092YVJ4R0txYUdpTCtYM3h1dlNrZzNnZUlQVituRnovR3B5dHl5R2FNcE9uUEhFQVh2SDJmRzlWWXJPMTFvR0VOT3BtQXBCWlFjeFNYbElJTXAzQmh1czlzSFQxRzV0citJV0RyN3VxNHhkNmxXb2xmL1Q3dWpjREtSNEZzMDM5TElzTU5wYTM3d3k5SnpXSlZ5czFsb0pybHlDTXpXbWdSb29zUFpqV0NDMzJhcDlNYXFOVlMzMWlRdzg1VTZYRG55Z2FITkdoaERqdXpSMndFNTZRMmkvdmVsZWg1ekd3R0lQeTdxQ0JGVFVuYUkvMGMvZVdUU2JhWTV1OElUaklGZS9hSGRBeFlpaC9BVmxYV0lUNklTNFBEK0ZmS0J0YkVHNWU1RnhUeDRPalREQ1E5UDBTYUVIWXVVNXg2U0xkSHhYTEdPNXJ5VWNjb3YvZVFzKzEvSzhtK0d2WHBIRU5nWXhPanp0QURSdmlBallEWDJ4OVVpUWhaV0o2RW9qclEyTVdXczgrRFBmdHp0QmNUNVdNVVkrTTNuOGJRQlI0cmRJNGRnbXhxWnBaSzNrbW44THVKWGVoRXloQXc3NTRyeVRwYjNpTWphck5DYzR6aGsvMEhoVndCSzdaRktLKzBONnNzRlZldmlHemNDYzdHakZoNTAxSGVla1JkWFJVSXFCVHVmdGQ0QzRicUQ5KzhMdFFnajd4MUU4dTZFZThsMGdYT1EvQXVUbkhCdi9hZWlpRTkrd3oxemEzZm85M3RqenZlTUd6OWhCZmt4WGpkQUJnS2RuNnJsZk9FeGdpa1luOHpjWXoxYXpidlNsUG1scHp4d1VTM2RoS2Vna3BRM0FUL2ExSlNsSkNkWlBxcWJoMjUvQTNmWTlXbGFoZ0piTGF2emUzamtDQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRk8raEgrbWNvWEtHN0FxZzRoQzc4c0J0UjlHR01COEdBMVVkSXdRWU1CYUFGTytoSCttY29YS0c3QXFnNGhDNzhzQnRSOUdHTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQUdSNDlaNFRKZzRFbGk5d0ZISGhrbXpCQjgzc21RMjI0T3RnblB5RDZrRDBJS0RoNiswamlCeXBJN0FGdUVPdUhDVVNvSCtHN1E0WVhWUnllU2ZnZDNxQW1HSkR4RzFRTXFaS0N3N2E0c3pQbEVxMDhkSEhGTU1LV2V2NmFEaXY4UDQzYnpEUUlhei9nbVV6TjZTdWhLM3lqSEVsVUcySU5HTHF5QlEzS0pvTk1uclpnRnJqTHlubFNrUUM3SUd4R2t5Z29udTRzV3k5M2hkR2NBQ29KQWhvSHQzVHBsNjE4SUt5M0hhd0tqSGN2Z3BSZjFQMHY0d3ZZTnc2czFweUZwOXJ1aGRHUW9IN3gya0RSbzBVMTZucGpMaTI1aFRZbVA2d0NOODhSc0NNMUtLZ0hzMkVta3daUFh4QVN4bFRRc0Q5UXVTbHR0Tlozc3lhU3FDM28vcmoxeDJFa1A2ellxNnFqeFZZSGcvbjA3MFE2UUZIL05PL1ZIekVaNVJCSi9oZDRUeW9mdHRtVTdhaWlDK3VhaEJhbFp6Y1ZNRzRuSGd1OVpqS21pTXJQc1JIdFc5eDJYR0RvVWRnUHMzM3M3OUdtQWxBWSs3QTJ3TURxRWVVRzB2cGNJMlNHRG8zR1RFZm0vV3h5THM0ekdoa3cvZjdZWnkrdnRXV1hPZDNrUUl2Qnl0cXE5MmE5c04xVGZrMGlxbkNNN1ZQWFBIRWk2QmR2RndPdDVZNnlFc0FBb2NXOTI4RXQ3ckFiZjFzZEVFQ3ZlUGhwT3NGWSt2TUtEREFJWmkrRlkvaWgxMzcyKzRjdm9xa2tJcFhzUHd1K0c5R2Z3cm1UTEFLaUdFcjZ5UU5DL3ZLQUdsQ0pHSXNva0xQUkpDMU84dDRLMnRGZDhYZi9rOVRERVZtIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2RlbW8vc2Evd29ya2xvYWQtYTEiLCJleHAiOjE3ODk3NTUxNDksImlhdCI6MTc4OTY2ODc0OSwiaXN0aW8uaW8iOnsidHJ1c3RfZG9tYWluIjoiY2x1c3Rlci5sb2NhbCIsIndvcmtsb2FkIjp7Im5hbWUiOiJ3b3JrbG9hZC1hMSIsIm5hbWVzcGFjZSI6ImRlbW8iLCJwb2QiOiJ3b3JrbG9hZC1hMS03N2JmOWZiZmQtZ3AyMjUifX0sImp0aSI6IjRhNTU5MGI0ODE0MDQ3NDIyYWUwMzE1ODU1YTI3NzcyIiwiY25mIjp7Imp3ayI6eyJrdHkiOiJFQyIsImNydiI6IlAtMjU2IiwieCI6ImNlTzNsZ2pXTDlweGVOaTJnNXBXNUdHY2MweVQ0X0tPQ1lXTmFMUW5NX0EiLCJ5IjoiSGxaQXFub0FlYzdlamxIZFFiUVF4RUJBTDJpYWU5RTdDM0tWdTRJd3VsWSJ9fX0.RduuUyFKv2NLGXGtq6TJuiYDkV6g3QyKnKZHxZ-DJ__KvXirM84SWs2sgDo-vB7SZHZf-Q2WMuIZCkSbyoZMpstiSFzJsS9TkCJTCCVDZfC7ov7GrdArRlbl6OzjtHIxdoTK9nTAPOGTbIXc8EhYAJbNI-TeiW4W4a2aS-1APHFMmOX7HroIrse7yebvhds0tYci-_u7m8RK6-PCbyCqR0T-wgT6NdGNziWH03xy0_kPvqFjHKxgqzDy28T9ncp5IWS7pL8hzknaslDAEsb7K0xqf9dydzuLzQ9VqqjoUPOHOCxQZ-39RX-PyWo14tytAqeeKqFUfLv8HConHL1Fp4_ui6ZlfP-YX20whtzvAwhJ5ibxU64eQL-oD8fm1ymbvs_gq8RGaSgJzXju4_5I3FPZLL3UFDj6BVKcTSZ2Wxpo92MLWK6G27OA2FrmVzgk2TsQB1rBDMIQswY3jaf-6LmhRi94zVybFwRUpIcyoEM35hspHhWFL2hMvy7YsyX1txSPRVjWmMR0jysqoV6smvhmtD-8unJscS5yqHTZC4kjy4JdUIGOSnoC7i5zegTc8WqJcGW27zLUG8eV5yg5H1KbdZuvdm1HMPktHVoGFv8f3VYSaegyk_Mau1HJSxoty4YTeFbv-_8xoGT6bQS6nOAa7PKwtZS6yBIGjvd-gYM"
    ]
  }
}
```

Verify `X-Forwarded-Workload-Identity`:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-b1/headers' | grep -A2 "X-Forwarded-Workload-Identity"
```

```
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/i-pig/sa/portfolio-b-pig, spiffe://cluster.local/ns/demo/sa/demo-waypoint"
    ],
```


## Cleanup

```bash
./data/cleanup-3-kind-clusters.sh
```

