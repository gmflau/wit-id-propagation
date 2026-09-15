---
author: Gilbert Lau
date: "September 18, 2026"
versions:
  "Solo istio distro": 1.31.0
  "enterprise-agentgateway": v2026.9.0
title: "WIT Identity Propagation with Enterprise Agentgateway"
---

# WIT Identity Propagation: workload-A → Agentgateway Egress Waypoint → Agentgateway PIG Gateway → Agentgateway Waypoint → workload-B

## Overview

This lab replaces the EnvoyFilter-based XFCC chain from [README_32.md](./README_32.md) with native WIMSE Workload Identity Token (WIT) propagation using `enterprise-agentgateway` across three KinD clusters. The same multi-hop traffic path is preserved, but identity travels through a cryptographically bound token chain rather than custom headers. All three agentgateway components — egress waypoint, PIG gateway, and inbound waypoint — participate natively in the WIT chain with no additional proxy layer.

**Full traffic path:**
```
workload-A → (ztunnel) → demo-egress-waypoint → (east-west) → pig-kgateway → (east-west) → demo-waypoint → workload-B
```

**Cluster layout:**
- `cluster-1` — `pig-kgateway` (agentgateway), `i-pig` namespace
- `cluster-2` — `demo-egress-waypoint` (agentgateway), `workload-A` (netshoot), `source-demo` namespace
- `cluster-3` — `demo-waypoint` (agentgateway), `workload-B` (go-httpbin), `i-pig` namespace

**What changes from README_32:**
- `pig-kgateway` uses `enterprise-agentgateway` instead of `enterprise-kgateway` — no separate `pig-waypoint` component needed
- A new `demo-egress-waypoint` (agentgateway) is deployed on cluster-2 as an **egress waypoint** for workload-A
- workload-A sends plain HTTP requests — **zero application changes needed**
- workload-A's own ztunnel embeds workload-A's SPIFFE identity claims (from its istiod-issued cert SAN) into a WIT and forwards it on the outbound HBONE connection to `demo-egress-waypoint` — this is what `ENABLE_WORKLOAD_CLAIMS=true` on ztunnel enables, with zero application involvement
- `demo-egress-waypoint` (`SourceDelegation`) forwards that inbound WIT and emits a WPT, binding the chain to its verified HBONE connection with workload-A's ztunnel
- `pig-kgateway` (`SourceDelegation`) forwards the hoisted WIT and emits a fresh WPT, binding the chain to its verified connection with the egress waypoint
- `demo-waypoint` (`PeerBound` enforcement) validates the WPT chain and authorizes using `workloadIdentity.chain.origin` = `workload-a-sa` — no EnvoyFilter required

**Identity propagation comparison:**

| Aspect | README_32 (EnvoyFilter + XFCC) | This lab (WIMSE WIT + WPT) |
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
>
> **Verification bug — `entWptEnforcement` always rejects:** in `enterprise-agentgateway` v2026.9.0, any WIT/WPT verification (`entWptEnforcement` in `Permissive`, `RequireProof`, or `PeerBound` mode) fails with:
> ```
> workload proof token verification failed: bound WIT rejected: no SAN in verified cert chain matches trust domain 'cluster.local' (inspected: [DNS:istiod.istio-system.svc])
> ```
> `DNS:istiod.istio-system.svc` is istiod's own control-plane serving certificate SAN — not a workload SPIFFE identity. This reproduces on the simplest possible hop (`demo-egress-waypoint` → `demo-waypoint` directly, bypassing `pig-kgateway` entirely) with the same signature, just without the "bound" wording (`workload identity token verification failed: ...`), so it isn't specific to `pig-kgateway` or to cross-cluster routing — the verification logic appears to check the wrong certificate whenever a WIT/WPT is actually validated. Treat this as a confirmed product bug to file against `enterprise-agentgateway` v2026.9.0, not a config error. §5.1 below shows how to demonstrate identity propagation without hitting this path.

---

## 1.1 Create the GKE Clusters

Create three zonal GKE clusters in us-central1 on a shared VPC:

```bash
./data/setup-3-3n-gke-clusters.sh
```

This script creates `glau-cluster-1` (us-central1-a), `glau-cluster-2` (us-central1-b), and `glau-cluster-3` (us-central1-c), each with 3 worker nodes, on a shared VPC (`solo-vpc`) with pod CIDRs `10.10/16`, `10.20/16`, and `10.30/16`. GCP VPC-native routing advertises pod CIDRs automatically — no manual `ip route` setup is needed.

### 1.2 Install the Ambient Mesh

Install Solo Istio ambient mesh across all three clusters and link them as a flat-network multicluster mesh:

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
export REMOTE_CONTEXT1="gke_${PROJECT_ID}_${CLUSTER1_ZONE}_${REMOTE_CLUSTER1}"
export REMOTE_CONTEXT2="gke_${PROJECT_ID}_${CLUSTER2_ZONE}_${REMOTE_CLUSTER2}"
export REMOTE_CONTEXT3="gke_${PROJECT_ID}_${CLUSTER3_ZONE}_${REMOTE_CLUSTER3}"
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
helm install enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT1} \
  -n agentgateway-system \
  --create-namespace

helm install enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT1} \
  --set licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY} \
  --set istio.autoEnabled=true \
  --set istio.clusterId=${REMOTE_CLUSTER1} \
  -n agentgateway-system
```

**cluster-2** (demo-egress-waypoint):
```bash
helm install enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT2} \
  -n agentgateway-system \
  --create-namespace

helm install enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT2} \
  --set licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY} \
  --set istio.autoEnabled=true \
  --set istio.clusterId=${REMOTE_CLUSTER2} \
  -n agentgateway-system
```

**cluster-3** (demo-waypoint):
```bash
helm install enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT3} \
  -n agentgateway-system \
  --create-namespace

helm install enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --version ${AGENTGATEWAY_VERSION} \
  --kube-context ${REMOTE_CONTEXT3} \
  --set licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY} \
  --set istio.autoEnabled=true \
  --set istio.clusterId=${REMOTE_CLUSTER3} \
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

## Deploy workloads

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

## Set up `workload-a1 → wpt-cel-egress → workload-a2`:

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
Date: Tue, 15 Sep 2026 13:52:03 GMT
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
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWd3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE5UQTFOVFExTlZvWERUTTJNRGt4TWpBMU5UUTFOVm93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFDTWFHZzlKb3JuNk1JSDUwSHhRZlM1a2E1SDVTUXg4TUdod1JZZTdPMmFuWElFeGl0T0g0V0NuelBjOXRmUGJZRjJWd0F3WTBUVTlNdktaVFNVbTg3MWEwUklqeUtIMHNCTTdNNXVsVHJGNXJpK3ppN3dYY2J3Umhzait5Z3pUbHlmWmtRaC9DdTRvNTlHa0JMMytNODBjeUxmZFJ0ZVZMQ0hNMS9SbmFUUjVSbzJLVjZlZGxRc2tOQXRlZTU2Ni9mbG5seEx3SCtJS2RZbkpTR05WZ2wxbk1YcHZsdzR4WDVySkN1Mm5UeW9SOTk0eDVTb1h6dkV3SGQvVUNWVzRLVHBIakgzMnBienpzZWlpWWVybXNLVnVIOHdHalpDbUp0elZnbmc0dzdXa29yaGtFMlB4NFp1TU5LaVpCNUNOUTB2ZU5JNFBwK0dGdXovanNDaTJCRkc3TnE5d2VoZm1uMVpEVXNLWENVRHlZY3A4eWdwd2pFRk56d2U2OUdOcW10dW5JbFB0Ky9ISnk4dFB1QVc1aHo5NWF3am9EUUF5bEFYbUdXdTRIWHRxSXRxajZNMXQ2UzF6VGV3MVlpZENlL1Rvd1ZTZEF1WHh3OTE3Mi93UDRlWkRlZTVHOXJqbTZkUlhBOWdlSDU3WVZJaWRvTVFabnRPTG15a2F6Yi8vTzVCK1pXalBMYXBiL05TVVFMRW5XYXBWb3hLOU9iWUJTdjdsWlQ4RWtMY1dUeTZ6a2ZCYUtLM2xQOXA5RFdKZGZrbGpJNWF2bjRPWVZzcm5xTlZYejFUa3ZkcCtqQXM4WVBUU1A1RmY0aUZoOGdkVGgvcmNGVmg2QmFXVDA2OW5hTUcraDZPaHM5RDI3WWNmVFN6K2I3SHJxUk10TWF5cWpnSzNHdHNmeDlMSVFJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZPTG54akZ2SVZqelduQWxXVkNZSEtnS3RRdjRNQjhHQTFVZEl3UVlNQmFBRkdvdlV0WExyUXBTdytOOUhueU9xTnY0WEdTbE1BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQklXNllneXlmakhPQ0pNbzVOY3MrMmJtQjgrZjdEc2pwOFRiNzhUQkpsbHB2VW8rcWJMRVF3SWxHeU9uQkREdzhQUXBMemwyWWQ2bjliM0FGTUlEZ3BLMHZjTVU0ZWNzdE1XSWd3WUlabk5BUXNqN3pObUIzMUF5YXdjeEFaYUxGL3ltSElaQlQ0Uys0OEl2UUZhaC9GNlQ3ekFDY1pGaDRTODNQZUZ5L2RJTWFjWVNTVTIzeUVGRjgzWms3UG5VeitWV3JtT1JVMFpaUHVrY3pyaGpIWWlvb3FoakMzeVlyckNwUU5yMklVOVpYcGJOT1NLRGNOSWFKMkx6UlJuUGs3dDkyUTY3ejR4czBHKzh5OFBDdXp0SmZRWUxrcHZ1QUo2TE1XSU5weldvZGxHalR1Y01Sbkc4U2tjVWNjcHRZMnVxMElTV2UxOGRETHlOUkYrL3dHajlpTDBMUVdmY2ZSVXRhdGcrMVE3eiswU1VDMDdxN3lqSnNwaEVWcUY2UG0wQXhDRjRoTDhiNCt4ZTdLeEJRSkNsRW90MXVkaFZ2bDE4OGV5aGV5dktvVEd5N0JuTWJ1RmN4bjVYdlByUGlFNEJ6VS92TWJxbVZQYmx2ckFneW9DTmpJUEl6c0Voa2IwZGh3Q1VaNnRSc3JpdHRDRWxaU2JuaU0xZVlkcGdxL09jNVRvREQ1dmRhUkJFbTIzbFVLVHNoRUtoSzhScVNOMUthUmMwQjF3QWVHZTlOdndKNWhwVk16bWxIdHY4N3Z6bHlXb0FOcll1TWFYbEQzTTlVaEFpNWFJVWsyV3pnanREMGJOcWhQaXB2VFFPNXdyVW9oVlpkeGVoamUydlJKK0Q0YkRnRlhLMEV0NTQvT0hjZmdLZCs5Z3ppUEQ2NFVvUHhUREVRR0FBPT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5Z3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TlRBMU5UUTFOVm9YRFRNMk1Ea3hNakExTlRRMU5Wb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUUNNYUdnOUpvcm42TUlINTBIeFFmUzVrYTVINVNReDhNR2h3UlllN08yYW5YSUV4aXRPSDRXQ256UGM5dGZQYllGMlZ3QXdZMFRVOU12S1pUU1VtODcxYTBSSWp5S0gwc0JNN001dWxUckY1cmkremk3d1hjYndSaHNqK3lnelRseWZaa1FoL0N1NG81OUdrQkwzK004MGN5TGZkUnRlVkxDSE0xL1JuYVRSNVJvMktWNmVkbFFza05BdGVlNTY2L2Zsbmx4THdIK0lLZFluSlNHTlZnbDFuTVhwdmx3NHhYNXJKQ3UyblR5b1I5OTR4NVNvWHp2RXdIZC9VQ1ZXNEtUcEhqSDMycGJ6enNlaWlZZXJtc0tWdUg4d0dqWkNtSnR6VmduZzR3N1drb3Joa0UyUHg0WnVNTktpWkI1Q05RMHZlTkk0UHArR0Z1ei9qc0NpMkJGRzdOcTl3ZWhmbW4xWkRVc0tYQ1VEeVljcDh5Z3B3akVGTnp3ZTY5R05xbXR1bklsUHQrL0hKeTh0UHVBVzVoejk1YXdqb0RRQXlsQVhtR1d1NEhYdHFJdHFqNk0xdDZTMXpUZXcxWWlkQ2UvVG93VlNkQXVYeHc5MTcyL3dQNGVaRGVlNUc5cmptNmRSWEE5Z2VINTdZVklpZG9NUVpudE9MbXlrYXpiLy9PNUIrWldqUExhcGIvTlNVUUxFbldhcFZveEs5T2JZQlN2N2xaVDhFa0xjV1R5NnprZkJhS0szbFA5cDlEV0pkZmtsakk1YXZuNE9ZVnNybnFOVlh6MVRrdmRwK2pBczhZUFRTUDVGZjRpRmg4Z2RUaC9yY0ZWaDZCYVdUMDY5bmFNRytoNk9oczlEMjdZY2ZUU3orYjdIcnFSTXRNYXlxamdLM0d0c2Z4OUxJUUlEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRk9MbnhqRnZJVmp6V25BbFdWQ1lIS2dLdFF2NE1COEdBMVVkSXdRWU1CYUFGR292VXRYTHJRcFN3K045SG55T3FOdjRYR1NsTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFCSVc2WWd5eWZqSE9DSk1vNU5jcysyYm1COCtmN0RzanA4VGI3OFRCSmxscHZVbytxYkxFUXdJbEd5T25CRER3OFBRcEx6bDJZZDZuOWIzQUZNSURncEswdmNNVTRlY3N0TVdJZ3dZSVpuTkFRc2o3ek5tQjMxQXlhd2N4QVphTEYveW1ISVpCVDRTKzQ4SXZRRmFoL0Y2VDd6QUNjWkZoNFM4M1BlRnkvZElNYWNZU1NVMjN5RUZGODNaazdQblV6K1ZXcm1PUlUwWlpQdWtjenJoakhZaW9vcWhqQzN5WXJyQ3BRTnIySVU5WlhwYk5PU0tEY05JYUoyTHpSUm5Qazd0OTJRNjd6NHhzMEcrOHk4UEN1enRKZlFZTGtwdnVBSjZMTVdJTnB6V29kbEdqVHVjTVJuRzhTa2NVY2NwdFkydXEwSVNXZTE4ZERMeU5SRisvd0dqOWlMMExRV2ZjZlJVdGF0ZysxUTd6KzBTVUMwN3E3eWpKc3BoRVZxRjZQbTBBeENGNGhMOGI0K3hlN0t4QlFKQ2xFb3QxdWRoVnZsMTg4ZXloZXl2S29UR3k3Qm5NYnVGY3huNVh2UHJQaUU0QnpVL3ZNYnFtVlBibHZyQWd5b0NOaklQSXpzRWhrYjBkaHdDVVo2dFJzcml0dENFbFpTYm5pTTFlWWRwZ3EvT2M1VG9ERDV2ZGFSQkVtMjNsVUtUc2hFS2hLOFJxU04xS2FSYzBCMXdBZUdlOU52d0o1aHBWTXptbEh0djg3dnpseVdvQU5yWXVNYVhsRDNNOVVoQWk1YUlVazJXemdqdEQwYk5xaFBpcHZUUU81d3JVb2hWWmR4ZWhqZTJ2UkorRDRiRGdGWEswRXQ1NC9PSGNmZ0tkKzlnemlQRDY0VW9QeFRERVFHQUE9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVRFdOcm56NjNZZGhyWERHYnhrRStRdU91SEM0d0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOVEExTlRRMU5Gb1hEVE0yTURreE1qQTFOVFExTkZvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUFwdGVGa1paSVEyYzlSdmxjYnh4c1FWZm51ZDNLMXFIaENUdkRmSVArcitmTlFOZW5qaDFseG1vdVd2d1NBTEVGTnRDT3ZDM1I4Z3RDQm9BZGtPeTQvSW9VNmx5SS83V05Xbnk1SXJobGlXR0NTUEdVWjlGNExMV0w2a3hBbTIzNy9yeXVpN1VzY2VzbXNLY2VkeGdqYjhUSU8rMWlNbFNCdDlBS2w1bldCcVduOXMyWWxWV3N3ak5qVlEyZThrNTJHNGFhSjRWNmt5YWFVRG9TZGIxZU9VZWlNR3M5V0oyU3FLV3kwWXVQOElaRGdMZllYOHNyR0NRcko4bWxycHFKYUNuSklEQ3E1NGo2NkUwMEtYUlI0cXkzLzRHdnVHVllsN1p0aFpiaDJqTG93dCtBYlVxRTJJR2RZa0R3YjZoem5Xc0N2QzluRTNXVmxEbnAwc29TcHBHSVZzbmJzNkFwNHNML3RVSS9GV0hwbC9YSk1zVVhoam5VcWNFM3BUbG1ReUZ1dGJzU2xVN3JKUlRWeVFBUjltcE4yWnNLR2hJM2x3V0V5a2VtMkZHTXhCTk9CZ1JjTHVYWHlNZFhIN0FpY0tMQkZvcDB0S0luSEM3QlNJL2Z2SXlINitTc2NqV3RwZFpBQjJYazN5bTNUZVQ4bTZPcFU4S1ZjbCsvMnZ0NTQ0ZTJKQTJtbG9FZno3RTJGKzhWbTVpbmdHbXZmNXBCY3h3VUQ2SW5SRzZ2dFRST3o5d3owTXhSU0RhSlNEeEY4ZHVWcXJyMlZlZ2dweEpXNi93Z29oUXRvbVlBMFY3RE1QZEc0dWYxMllmdzdrVnJ2VHBtUlFMS0toUHR0OGgxd0R3MVBJRm8rdWpEODBvTkV1c2p6YVdTNCtMeElBVkwrajJxdnNWTEU3VUNBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGR292VXRYTHJRcFN3K045SG55T3FOdjRYR1NsTUI4R0ExVWRJd1FZTUJhQUZHb3ZVdFhMclFwU3crTjlIbnlPcU52NFhHU2xNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBR1JuV05nZFZERlFReHdDTno2ZkRyQnhscUVUU3c2YjNCVkNiN2QwQzNyaFJPYU40WkZ2bHMwYUovYVpQNlJ6OGdHQWl5RDdqdklneCtVTUVNeHE5QUZNejhVTkwzZ1I1RjgrK3dGYlVYWHphVExkZUcwUlYvMWpUa3ZFdlNzeGMwR1NGekNHWjNENUdZTmczaFZyOXlwMVllZ2c3dVJ1OWxMNy9QR0RBdTNCNy9tMStKTmxrY1ZLdkg2ZVpuUjJXRU1zRDh3SXA2b1JBMi8wS1ZnMVB4VUtCUitZd21rZTNvRHNUR1FKemhrL1l0ZzRQbGZ3RW9WbzF2eStMaGJWbVRSNEdENHdCcUJrLzNsUVo5TnB3aEhzSFNUV3prOERlZkw0ZjNZWDNEMVR2cWZzVU9qc2FZWTM4Q2VsTGt4WnNBeVZJWmVVWmdyZ0VnMHFkdXJKNU9BVldzTXBWb3hJS3hoMnBqV3VoMGx3UHlzSTREbDlVejRlclZGR3RnVDVia3RvSFRWRHpWVTc2SG9ZVXJ1WjM1M0pmOHlDNkd3K0pNeHhIQnVMK2Y3cXdxM0w5bGQwOW15bHQ1dHlvNWc4VnBkS2dacis3d1JjVmFlL0RHa1oycFB3SDdIUVRVbVVsVldWVUVIYjQ4a3YvRjNlZHZVdGpKUlN1a0x4dnFuMjJ0WnlFVVhXR3Q0ZGVMSlVyejNZS2toRE55Nld4MlNCZ2c1WkVkQnBOaDZqSWE3Nkp3dmlON09VbWhnYWNaVmMxQ0xEOEZ2RW4rOW53N3pEYWFQRlgvZ3ZwNm9ZNkRoYjVTYkxndzlXdWVUeU11TFVsa05Za3QzcDUydGRDYjJURUJGL2ZQNXNZSkVWM2FwamJ0Vk5rdTY2ZWRnVzB5VXlQT3p5MnMxSXJUYTYiLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVURXTnJuejYzWWRoclhER2J4a0UrUXVPdUhDNHdEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TlRBMU5UUTFORm9YRFRNMk1Ea3hNakExTlRRMU5Gb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBcHRlRmtaWklRMmM5UnZsY2J4eHNRVmZudWQzSzFxSGhDVHZEZklQK3IrZk5RTmVuamgxbHhtb3VXdndTQUxFRk50Q092QzNSOGd0Q0JvQWRrT3k0L0lvVTZseUkvN1dOV255NUlyaGxpV0dDU1BHVVo5RjRMTFdMNmt4QW0yMzcvcnl1aTdVc2Nlc21zS2NlZHhnamI4VElPKzFpTWxTQnQ5QUtsNW5XQnFXbjlzMllsVldzd2pOalZRMmU4azUyRzRhYUo0VjZreWFhVURvU2RiMWVPVWVpTUdzOVdKMlNxS1d5MFl1UDhJWkRnTGZZWDhzckdDUXJKOG1scnBxSmFDbkpJRENxNTRqNjZFMDBLWFJSNHF5My80R3Z1R1ZZbDdadGhaYmgyakxvd3QrQWJVcUUySUdkWWtEd2I2aHpuV3NDdkM5bkUzV1ZsRG5wMHNvU3BwR0lWc25iczZBcDRzTC90VUkvRldIcGwvWEpNc1VYaGpuVXFjRTNwVGxtUXlGdXRic1NsVTdySlJUVnlRQVI5bXBOMlpzS0doSTNsd1dFeWtlbTJGR014Qk5PQmdSY0x1WFh5TWRYSDdBaWNLTEJGb3AwdEtJbkhDN0JTSS9mdkl5SDYrU3Njald0cGRaQUIyWGszeW0zVGVUOG02T3BVOEtWY2wrLzJ2dDU0NGUySkEybWxvRWZ6N0UyRis4Vm01aW5nR212ZjVwQmN4d1VENkluUkc2dnRUUk96OXd6ME14UlNEYUpTRHhGOGR1VnFycjJWZWdncHhKVzYvd2dvaFF0b21ZQTBWN0RNUGRHNHVmMTJZZnc3a1ZydlRwbVJRTEtLaFB0dDhoMXdEdzFQSUZvK3VqRDgwb05FdXNqemFXUzQrTHhJQVZMK2oycXZzVkxFN1VDQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRkdvdlV0WExyUXBTdytOOUhueU9xTnY0WEdTbE1COEdBMVVkSXdRWU1CYUFGR292VXRYTHJRcFN3K045SG55T3FOdjRYR1NsTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQUdSbldOZ2RWREZRUXh3Q056NmZEckJ4bHFFVFN3NmIzQlZDYjdkMEMzcmhST2FONFpGdmxzMGFKL2FaUDZSejhnR0FpeUQ3anZJZ3grVU1FTXhxOUFGTXo4VU5MM2dSNUY4Kyt3RmJVWFh6YVRMZGVHMFJWLzFqVGt2RXZTc3hjMEdTRnpDR1ozRDVHWU5nM2hWcjl5cDFZZWdnN3VSdTlsTDcvUEdEQXUzQjcvbTErSk5sa2NWS3ZINmVablIyV0VNc0Q4d0lwNm9SQTIvMEtWZzFQeFVLQlIrWXdta2Uzb0RzVEdRSnpoay9ZdGc0UGxmd0VvVm8xdnkrTGhiVm1UUjRHRDR3QnFCay8zbFFaOU5wd2hIc0hTVFd6azhEZWZMNGYzWVgzRDFUdnFmc1VPanNhWVkzOENlbExreFpzQXlWSVplVVpncmdFZzBxZHVySjVPQVZXc01wVm94SUt4aDJwald1aDBsd1B5c0k0RGw5VXo0ZXJWRkd0Z1Q1Ymt0b0hUVkR6VlU3NkhvWVVydVozNTNKZjh5QzZHdytKTXh4SEJ1TCtmN3F3cTNMOWxkMDlteWx0NXR5bzVnOFZwZEtnWnIrN3dSY1ZhZS9ER2taMnBQd0g3SFFUVW1VbFZXVlVFSGI0OGt2L0YzZWR2VXRqSlJTdWtMeHZxbjIydFp5RVVYV0d0NGRlTEpVcnozWUtraEROeTZXeDJTQmdnNVpFZEJwTmg2aklhNzZKd3ZpTjdPVW1oZ2FjWlZjMUNMRDhGdkVuKzludzd6RGFhUEZYL2d2cDZvWTZEaGI1U2JMZ3c5V3VlVHlNdUxVbGtOWWt0M3A1MnRkQ2IyVEVCRi9mUDVzWUpFVjNhcGpidFZOa3U2NmVkZ1cweVV5UE96eTJzMUlyVGE2Il19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2ktcGVnL3NhL3dwdC1jZWwtZWdyZXNzIiwiZXhwIjoxNzg5NTY2NjM4LCJpYXQiOjE3ODk0ODAyMzgsImlzdGlvLmlvIjp7InRydXN0X2RvbWFpbiI6ImNsdXN0ZXIubG9jYWwiLCJ3b3JrbG9hZCI6eyJuYW1lIjoid3B0LWNlbC1lZ3Jlc3MiLCJuYW1lc3BhY2UiOiJpLXBlZyIsInBvZCI6IndwdC1jZWwtZWdyZXNzLTU0ZjZmNjhkNS03dmNkYiJ9fSwianRpIjoiMjM0ZWUwOTAxNGZiMWYzOWI2NmI4YTBhZWU3MzQ4N2QiLCJjbmYiOnsiandrIjp7Imt0eSI6IkVDIiwiY3J2IjoiUC0yNTYiLCJ4IjoiaVBSVFhBcmhyLXRJaWlwMTE3cmJVVDRReTIteHgxTnEwT09ZMGZzcHYzWSIsInkiOiJUQ09XTC1kWDl6MWd1MXNpaWpkVl9EQ2tjQUEtSDFjWC0yaHEyWmpBclZrIn19fQ.a9sSOd4EUIWsnp_IKBSlNOB6FfXDm2CCUXaCP32PiGMXcLkhBdOlym5WaLDP2Ek-C932Q7sR7Rvx_zq-Nn_Da_lXJhN0fTUJRMRSDJyg37a0KCVZjg-1SveqZd9TR149YC_8Mcb9dvho_fYVl3TJpUNZ6x6uLY8KdoBCfvCRUMk4S8bsZI5hqV3PlGxF-eAMVVCyEqGerF7J-rcN148XCDAeyviUlLSAeeq4dP6puf3izDuR6gm1ynKkEOHB6DbINkt_Xq_dTHP0WfS0_w5SZRDvxkHVYdjqBW3uWZ0YxvFmYz5uh4YuVV4dbguWvupsdpBtQ5aBWZWsnsKF21mnlu0ExmchKHs2aMcHgAWwplVqbHSTZJKh7OA3Y66vN2hfBf2Wnh7C8g98VnFG_SpuNTLVrYMXTHyJJKO07oxkFJaGTAbx3_bh3BjbmsKWHBg2RH7MIQz0Nnzx4RfXTeeORc99l-5pXB1xVuP2HMzv3xMgcnd2-ECQNF-7AIJ52Sl5rOUCRNrslUTyRI4b-IMVzsZUai_BPtivzixsqJ5QVFKc8LWFLkfJX7fe3dzKBFQUWsAJ1feCYOoE1JflLQdaXoQQVg8YdSEElNjTLZTD0Cl7Mc4iKnqTps_7MhpcggGE_K5edPMAnVtJZoKSQ5ghzDhQeROR8KnNs_Z1UexhD9s"
    ],
    "Workload-Proof-Token": [
      "eyJ0eXAiOiJhcHBsaWNhdGlvbi93cHQrand0IiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2ktcGVnL3NhL3dwdC1jZWwtZWdyZXNzIiwiYXVkIjoiaHR0cHM6Ly93b3JrbG9hZC1hMi5kZW1vLnN2Yy5jbHVzdGVyLmxvY2FsIiwiZXhwIjoxNzg5NDgwMzgzLCJpYXQiOjE3ODk0ODAzMjMsImp0aSI6IjliM2MwN2QyLTc1M2EtNDhjYS04MzRhLWRkMWQ5OTEzYzY5OCIsInd0aCI6IkRZNkx4aDUxT1VvYkJhd0dPZXZhMURPXzlOQl9Wand1RkZ3b0hoRjFqa0kiLCJvdGgiOnsieC1mb3J3YXJkZWQtd29ya2xvYWQtaWRlbnRpdHkiOiJ5YlhacThheTJPTVhfaHJPNm5iRkczRXkxbWZtMW1EVEFZSjRYd1lSeXJNIiwieC1vcmlnaW5hbC13b3JrbG9hZC1pZGVudGl0eS10b2tlbiI6Ik1sYmxJRGZLUVBCTkJFeEEwNXFMTnBRV2ZQNU1ac3c3ZjZJeFdSNzJ4SGsifX0.jWE0luEAuS0n9WZCoGTv4rN8NTQZtS9PFJ4jhKGOVQV6S7PTUQP2E5ZVUh9Cv54d_2eeD_xw4nL8Kpqsul5PFg"
    ],
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress"
    ],
    "X-Original-Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWd3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE5UQTFOVFExTlZvWERUTTJNRGt4TWpBMU5UUTFOVm93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFDTWFHZzlKb3JuNk1JSDUwSHhRZlM1a2E1SDVTUXg4TUdod1JZZTdPMmFuWElFeGl0T0g0V0NuelBjOXRmUGJZRjJWd0F3WTBUVTlNdktaVFNVbTg3MWEwUklqeUtIMHNCTTdNNXVsVHJGNXJpK3ppN3dYY2J3Umhzait5Z3pUbHlmWmtRaC9DdTRvNTlHa0JMMytNODBjeUxmZFJ0ZVZMQ0hNMS9SbmFUUjVSbzJLVjZlZGxRc2tOQXRlZTU2Ni9mbG5seEx3SCtJS2RZbkpTR05WZ2wxbk1YcHZsdzR4WDVySkN1Mm5UeW9SOTk0eDVTb1h6dkV3SGQvVUNWVzRLVHBIakgzMnBienpzZWlpWWVybXNLVnVIOHdHalpDbUp0elZnbmc0dzdXa29yaGtFMlB4NFp1TU5LaVpCNUNOUTB2ZU5JNFBwK0dGdXovanNDaTJCRkc3TnE5d2VoZm1uMVpEVXNLWENVRHlZY3A4eWdwd2pFRk56d2U2OUdOcW10dW5JbFB0Ky9ISnk4dFB1QVc1aHo5NWF3am9EUUF5bEFYbUdXdTRIWHRxSXRxajZNMXQ2UzF6VGV3MVlpZENlL1Rvd1ZTZEF1WHh3OTE3Mi93UDRlWkRlZTVHOXJqbTZkUlhBOWdlSDU3WVZJaWRvTVFabnRPTG15a2F6Yi8vTzVCK1pXalBMYXBiL05TVVFMRW5XYXBWb3hLOU9iWUJTdjdsWlQ4RWtMY1dUeTZ6a2ZCYUtLM2xQOXA5RFdKZGZrbGpJNWF2bjRPWVZzcm5xTlZYejFUa3ZkcCtqQXM4WVBUU1A1RmY0aUZoOGdkVGgvcmNGVmg2QmFXVDA2OW5hTUcraDZPaHM5RDI3WWNmVFN6K2I3SHJxUk10TWF5cWpnSzNHdHNmeDlMSVFJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZPTG54akZ2SVZqelduQWxXVkNZSEtnS3RRdjRNQjhHQTFVZEl3UVlNQmFBRkdvdlV0WExyUXBTdytOOUhueU9xTnY0WEdTbE1BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQklXNllneXlmakhPQ0pNbzVOY3MrMmJtQjgrZjdEc2pwOFRiNzhUQkpsbHB2VW8rcWJMRVF3SWxHeU9uQkREdzhQUXBMemwyWWQ2bjliM0FGTUlEZ3BLMHZjTVU0ZWNzdE1XSWd3WUlabk5BUXNqN3pObUIzMUF5YXdjeEFaYUxGL3ltSElaQlQ0Uys0OEl2UUZhaC9GNlQ3ekFDY1pGaDRTODNQZUZ5L2RJTWFjWVNTVTIzeUVGRjgzWms3UG5VeitWV3JtT1JVMFpaUHVrY3pyaGpIWWlvb3FoakMzeVlyckNwUU5yMklVOVpYcGJOT1NLRGNOSWFKMkx6UlJuUGs3dDkyUTY3ejR4czBHKzh5OFBDdXp0SmZRWUxrcHZ1QUo2TE1XSU5weldvZGxHalR1Y01Sbkc4U2tjVWNjcHRZMnVxMElTV2UxOGRETHlOUkYrL3dHajlpTDBMUVdmY2ZSVXRhdGcrMVE3eiswU1VDMDdxN3lqSnNwaEVWcUY2UG0wQXhDRjRoTDhiNCt4ZTdLeEJRSkNsRW90MXVkaFZ2bDE4OGV5aGV5dktvVEd5N0JuTWJ1RmN4bjVYdlByUGlFNEJ6VS92TWJxbVZQYmx2ckFneW9DTmpJUEl6c0Voa2IwZGh3Q1VaNnRSc3JpdHRDRWxaU2JuaU0xZVlkcGdxL09jNVRvREQ1dmRhUkJFbTIzbFVLVHNoRUtoSzhScVNOMUthUmMwQjF3QWVHZTlOdndKNWhwVk16bWxIdHY4N3Z6bHlXb0FOcll1TWFYbEQzTTlVaEFpNWFJVWsyV3pnanREMGJOcWhQaXB2VFFPNXdyVW9oVlpkeGVoamUydlJKK0Q0YkRnRlhLMEV0NTQvT0hjZmdLZCs5Z3ppUEQ2NFVvUHhUREVRR0FBPT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5Z3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TlRBMU5UUTFOVm9YRFRNMk1Ea3hNakExTlRRMU5Wb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUUNNYUdnOUpvcm42TUlINTBIeFFmUzVrYTVINVNReDhNR2h3UlllN08yYW5YSUV4aXRPSDRXQ256UGM5dGZQYllGMlZ3QXdZMFRVOU12S1pUU1VtODcxYTBSSWp5S0gwc0JNN001dWxUckY1cmkremk3d1hjYndSaHNqK3lnelRseWZaa1FoL0N1NG81OUdrQkwzK004MGN5TGZkUnRlVkxDSE0xL1JuYVRSNVJvMktWNmVkbFFza05BdGVlNTY2L2Zsbmx4THdIK0lLZFluSlNHTlZnbDFuTVhwdmx3NHhYNXJKQ3UyblR5b1I5OTR4NVNvWHp2RXdIZC9VQ1ZXNEtUcEhqSDMycGJ6enNlaWlZZXJtc0tWdUg4d0dqWkNtSnR6VmduZzR3N1drb3Joa0UyUHg0WnVNTktpWkI1Q05RMHZlTkk0UHArR0Z1ei9qc0NpMkJGRzdOcTl3ZWhmbW4xWkRVc0tYQ1VEeVljcDh5Z3B3akVGTnp3ZTY5R05xbXR1bklsUHQrL0hKeTh0UHVBVzVoejk1YXdqb0RRQXlsQVhtR1d1NEhYdHFJdHFqNk0xdDZTMXpUZXcxWWlkQ2UvVG93VlNkQXVYeHc5MTcyL3dQNGVaRGVlNUc5cmptNmRSWEE5Z2VINTdZVklpZG9NUVpudE9MbXlrYXpiLy9PNUIrWldqUExhcGIvTlNVUUxFbldhcFZveEs5T2JZQlN2N2xaVDhFa0xjV1R5NnprZkJhS0szbFA5cDlEV0pkZmtsakk1YXZuNE9ZVnNybnFOVlh6MVRrdmRwK2pBczhZUFRTUDVGZjRpRmg4Z2RUaC9yY0ZWaDZCYVdUMDY5bmFNRytoNk9oczlEMjdZY2ZUU3orYjdIcnFSTXRNYXlxamdLM0d0c2Z4OUxJUUlEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRk9MbnhqRnZJVmp6V25BbFdWQ1lIS2dLdFF2NE1COEdBMVVkSXdRWU1CYUFGR292VXRYTHJRcFN3K045SG55T3FOdjRYR1NsTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFCSVc2WWd5eWZqSE9DSk1vNU5jcysyYm1COCtmN0RzanA4VGI3OFRCSmxscHZVbytxYkxFUXdJbEd5T25CRER3OFBRcEx6bDJZZDZuOWIzQUZNSURncEswdmNNVTRlY3N0TVdJZ3dZSVpuTkFRc2o3ek5tQjMxQXlhd2N4QVphTEYveW1ISVpCVDRTKzQ4SXZRRmFoL0Y2VDd6QUNjWkZoNFM4M1BlRnkvZElNYWNZU1NVMjN5RUZGODNaazdQblV6K1ZXcm1PUlUwWlpQdWtjenJoakhZaW9vcWhqQzN5WXJyQ3BRTnIySVU5WlhwYk5PU0tEY05JYUoyTHpSUm5Qazd0OTJRNjd6NHhzMEcrOHk4UEN1enRKZlFZTGtwdnVBSjZMTVdJTnB6V29kbEdqVHVjTVJuRzhTa2NVY2NwdFkydXEwSVNXZTE4ZERMeU5SRisvd0dqOWlMMExRV2ZjZlJVdGF0ZysxUTd6KzBTVUMwN3E3eWpKc3BoRVZxRjZQbTBBeENGNGhMOGI0K3hlN0t4QlFKQ2xFb3QxdWRoVnZsMTg4ZXloZXl2S29UR3k3Qm5NYnVGY3huNVh2UHJQaUU0QnpVL3ZNYnFtVlBibHZyQWd5b0NOaklQSXpzRWhrYjBkaHdDVVo2dFJzcml0dENFbFpTYm5pTTFlWWRwZ3EvT2M1VG9ERDV2ZGFSQkVtMjNsVUtUc2hFS2hLOFJxU04xS2FSYzBCMXdBZUdlOU52d0o1aHBWTXptbEh0djg3dnpseVdvQU5yWXVNYVhsRDNNOVVoQWk1YUlVazJXemdqdEQwYk5xaFBpcHZUUU81d3JVb2hWWmR4ZWhqZTJ2UkorRDRiRGdGWEswRXQ1NC9PSGNmZ0tkKzlnemlQRDY0VW9QeFRERVFHQUE9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVRFdOcm56NjNZZGhyWERHYnhrRStRdU91SEM0d0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOVEExTlRRMU5Gb1hEVE0yTURreE1qQTFOVFExTkZvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUFwdGVGa1paSVEyYzlSdmxjYnh4c1FWZm51ZDNLMXFIaENUdkRmSVArcitmTlFOZW5qaDFseG1vdVd2d1NBTEVGTnRDT3ZDM1I4Z3RDQm9BZGtPeTQvSW9VNmx5SS83V05Xbnk1SXJobGlXR0NTUEdVWjlGNExMV0w2a3hBbTIzNy9yeXVpN1VzY2VzbXNLY2VkeGdqYjhUSU8rMWlNbFNCdDlBS2w1bldCcVduOXMyWWxWV3N3ak5qVlEyZThrNTJHNGFhSjRWNmt5YWFVRG9TZGIxZU9VZWlNR3M5V0oyU3FLV3kwWXVQOElaRGdMZllYOHNyR0NRcko4bWxycHFKYUNuSklEQ3E1NGo2NkUwMEtYUlI0cXkzLzRHdnVHVllsN1p0aFpiaDJqTG93dCtBYlVxRTJJR2RZa0R3YjZoem5Xc0N2QzluRTNXVmxEbnAwc29TcHBHSVZzbmJzNkFwNHNML3RVSS9GV0hwbC9YSk1zVVhoam5VcWNFM3BUbG1ReUZ1dGJzU2xVN3JKUlRWeVFBUjltcE4yWnNLR2hJM2x3V0V5a2VtMkZHTXhCTk9CZ1JjTHVYWHlNZFhIN0FpY0tMQkZvcDB0S0luSEM3QlNJL2Z2SXlINitTc2NqV3RwZFpBQjJYazN5bTNUZVQ4bTZPcFU4S1ZjbCsvMnZ0NTQ0ZTJKQTJtbG9FZno3RTJGKzhWbTVpbmdHbXZmNXBCY3h3VUQ2SW5SRzZ2dFRST3o5d3owTXhSU0RhSlNEeEY4ZHVWcXJyMlZlZ2dweEpXNi93Z29oUXRvbVlBMFY3RE1QZEc0dWYxMllmdzdrVnJ2VHBtUlFMS0toUHR0OGgxd0R3MVBJRm8rdWpEODBvTkV1c2p6YVdTNCtMeElBVkwrajJxdnNWTEU3VUNBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGR292VXRYTHJRcFN3K045SG55T3FOdjRYR1NsTUI4R0ExVWRJd1FZTUJhQUZHb3ZVdFhMclFwU3crTjlIbnlPcU52NFhHU2xNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBR1JuV05nZFZERlFReHdDTno2ZkRyQnhscUVUU3c2YjNCVkNiN2QwQzNyaFJPYU40WkZ2bHMwYUovYVpQNlJ6OGdHQWl5RDdqdklneCtVTUVNeHE5QUZNejhVTkwzZ1I1RjgrK3dGYlVYWHphVExkZUcwUlYvMWpUa3ZFdlNzeGMwR1NGekNHWjNENUdZTmczaFZyOXlwMVllZ2c3dVJ1OWxMNy9QR0RBdTNCNy9tMStKTmxrY1ZLdkg2ZVpuUjJXRU1zRDh3SXA2b1JBMi8wS1ZnMVB4VUtCUitZd21rZTNvRHNUR1FKemhrL1l0ZzRQbGZ3RW9WbzF2eStMaGJWbVRSNEdENHdCcUJrLzNsUVo5TnB3aEhzSFNUV3prOERlZkw0ZjNZWDNEMVR2cWZzVU9qc2FZWTM4Q2VsTGt4WnNBeVZJWmVVWmdyZ0VnMHFkdXJKNU9BVldzTXBWb3hJS3hoMnBqV3VoMGx3UHlzSTREbDlVejRlclZGR3RnVDVia3RvSFRWRHpWVTc2SG9ZVXJ1WjM1M0pmOHlDNkd3K0pNeHhIQnVMK2Y3cXdxM0w5bGQwOW15bHQ1dHlvNWc4VnBkS2dacis3d1JjVmFlL0RHa1oycFB3SDdIUVRVbVVsVldWVUVIYjQ4a3YvRjNlZHZVdGpKUlN1a0x4dnFuMjJ0WnlFVVhXR3Q0ZGVMSlVyejNZS2toRE55Nld4MlNCZ2c1WkVkQnBOaDZqSWE3Nkp3dmlON09VbWhnYWNaVmMxQ0xEOEZ2RW4rOW53N3pEYWFQRlgvZ3ZwNm9ZNkRoYjVTYkxndzlXdWVUeU11TFVsa05Za3QzcDUydGRDYjJURUJGL2ZQNXNZSkVWM2FwamJ0Vk5rdTY2ZWRnVzB5VXlQT3p5MnMxSXJUYTYiLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVURXTnJuejYzWWRoclhER2J4a0UrUXVPdUhDNHdEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TlRBMU5UUTFORm9YRFRNMk1Ea3hNakExTlRRMU5Gb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBcHRlRmtaWklRMmM5UnZsY2J4eHNRVmZudWQzSzFxSGhDVHZEZklQK3IrZk5RTmVuamgxbHhtb3VXdndTQUxFRk50Q092QzNSOGd0Q0JvQWRrT3k0L0lvVTZseUkvN1dOV255NUlyaGxpV0dDU1BHVVo5RjRMTFdMNmt4QW0yMzcvcnl1aTdVc2Nlc21zS2NlZHhnamI4VElPKzFpTWxTQnQ5QUtsNW5XQnFXbjlzMllsVldzd2pOalZRMmU4azUyRzRhYUo0VjZreWFhVURvU2RiMWVPVWVpTUdzOVdKMlNxS1d5MFl1UDhJWkRnTGZZWDhzckdDUXJKOG1scnBxSmFDbkpJRENxNTRqNjZFMDBLWFJSNHF5My80R3Z1R1ZZbDdadGhaYmgyakxvd3QrQWJVcUUySUdkWWtEd2I2aHpuV3NDdkM5bkUzV1ZsRG5wMHNvU3BwR0lWc25iczZBcDRzTC90VUkvRldIcGwvWEpNc1VYaGpuVXFjRTNwVGxtUXlGdXRic1NsVTdySlJUVnlRQVI5bXBOMlpzS0doSTNsd1dFeWtlbTJGR014Qk5PQmdSY0x1WFh5TWRYSDdBaWNLTEJGb3AwdEtJbkhDN0JTSS9mdkl5SDYrU3Njald0cGRaQUIyWGszeW0zVGVUOG02T3BVOEtWY2wrLzJ2dDU0NGUySkEybWxvRWZ6N0UyRis4Vm01aW5nR212ZjVwQmN4d1VENkluUkc2dnRUUk96OXd6ME14UlNEYUpTRHhGOGR1VnFycjJWZWdncHhKVzYvd2dvaFF0b21ZQTBWN0RNUGRHNHVmMTJZZnc3a1ZydlRwbVJRTEtLaFB0dDhoMXdEdzFQSUZvK3VqRDgwb05FdXNqemFXUzQrTHhJQVZMK2oycXZzVkxFN1VDQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRkdvdlV0WExyUXBTdytOOUhueU9xTnY0WEdTbE1COEdBMVVkSXdRWU1CYUFGR292VXRYTHJRcFN3K045SG55T3FOdjRYR1NsTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQUdSbldOZ2RWREZRUXh3Q056NmZEckJ4bHFFVFN3NmIzQlZDYjdkMEMzcmhST2FONFpGdmxzMGFKL2FaUDZSejhnR0FpeUQ3anZJZ3grVU1FTXhxOUFGTXo4VU5MM2dSNUY4Kyt3RmJVWFh6YVRMZGVHMFJWLzFqVGt2RXZTc3hjMEdTRnpDR1ozRDVHWU5nM2hWcjl5cDFZZWdnN3VSdTlsTDcvUEdEQXUzQjcvbTErSk5sa2NWS3ZINmVablIyV0VNc0Q4d0lwNm9SQTIvMEtWZzFQeFVLQlIrWXdta2Uzb0RzVEdRSnpoay9ZdGc0UGxmd0VvVm8xdnkrTGhiVm1UUjRHRDR3QnFCay8zbFFaOU5wd2hIc0hTVFd6azhEZWZMNGYzWVgzRDFUdnFmc1VPanNhWVkzOENlbExreFpzQXlWSVplVVpncmdFZzBxZHVySjVPQVZXc01wVm94SUt4aDJwald1aDBsd1B5c0k0RGw5VXo0ZXJWRkd0Z1Q1Ymt0b0hUVkR6VlU3NkhvWVVydVozNTNKZjh5QzZHdytKTXh4SEJ1TCtmN3F3cTNMOWxkMDlteWx0NXR5bzVnOFZwZEtnWnIrN3dSY1ZhZS9ER2taMnBQd0g3SFFUVW1VbFZXVlVFSGI0OGt2L0YzZWR2VXRqSlJTdWtMeHZxbjIydFp5RVVYV0d0NGRlTEpVcnozWUtraEROeTZXeDJTQmdnNVpFZEJwTmg2aklhNzZKd3ZpTjdPVW1oZ2FjWlZjMUNMRDhGdkVuKzludzd6RGFhUEZYL2d2cDZvWTZEaGI1U2JMZ3c5V3VlVHlNdUxVbGtOWWt0M3A1MnRkQ2IyVEVCRi9mUDVzWUpFVjNhcGpidFZOa3U2NmVkZ1cweVV5UE96eTJzMUlyVGE2Il19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2RlbW8vc2Evd29ya2xvYWQtYTEiLCJleHAiOjE3ODk1NjU0ODcsImlhdCI6MTc4OTQ3OTA4NywiaXN0aW8uaW8iOnsidHJ1c3RfZG9tYWluIjoiY2x1c3Rlci5sb2NhbCIsIndvcmtsb2FkIjp7Im5hbWUiOiJ3b3JrbG9hZC1hMSIsIm5hbWVzcGFjZSI6ImRlbW8iLCJwb2QiOiJ3b3JrbG9hZC1hMS03YjVkNmM1YjU3LWpjcDlqIn19LCJqdGkiOiJkYzM5MjkzOGNlZjY4NGEyM2JlOWRhYzc4ZTkyZWFiNiIsImNuZiI6eyJqd2siOnsia3R5IjoiRUMiLCJjcnYiOiJQLTI1NiIsIngiOiIxaXYtSGctbGQxdkg5ZS1IMThudTIxcDlFLTYzUFBJMFFiZXJDalNVSk5JIiwieSI6Imh2algtMFBzcm9FdmdvdG5JTTJVY2tvQjRDUEN3RzBkQVlpeDUyQnVYZW8ifX19.QXC5wfI-SKfCRJVxi0RWNLwFDHBXpxH3QaDtW8mlgQsc2AnLSsaJ7av6nI2q6UodsmSQFQlwMyC45nVHKlWOTuhkdjhU9TOry2Lmw89ytYLbIkUh5vlX7bSht8UdF-IsTFjnOR-y1Zj9_Zg_1L4qax80HCDrC74yXdRKpLvscl70rQoUmPla8Xfr9iQAAVZFeNPIQXs8e-umuNGS2SXLbLyv6L_OZQdGYM1tcyzNeVIIh2TOkKh7YtszzR--QgGKACYFriC2kfa3VQjQn9OF7AS4Wnrp1794TVwwN5WtfSNI6g5aPRPsxXln_L0KDjwEjYLK_yt1DZ1rQ5YntgLCpPQf4tep2BXlk3iGW-PkeS2AmFeGGYfTrUPOD--cXKVTXSjtkHoxHbxXnRhNYaCpft0GFNbnBYWt7tTlLdiF0YhIxcKYAsZ_iGfrZaAxPbO_NgEBur-sa4EQEbr9eKlmNT5a0WRr8t6V3Qo_SyxiFAtFMbzufvxxqy77oHdnaRhjdYT2sgMBv_Wpn2-CA_3ShTmeKK0n3dQQY_KAG3Z37yKNC09_RQB08UhuhDZ-MqcyePxGk5okqXlnqdx5rsllDYUtcUMdWfEaM3tTD5iqv7BiOso4ZXkp0l7JU99e5WvaxrNPXzicypu_X9O3Eg1TcGxQnSkHsKB8SjCNOorT7ts"
    ]
  }
}
```

---

## Set up `workload-a1 → wpt-cel-egress → demo-waypoint → workload-a2`:

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

**What was missing:** `EnterpriseAgentgatewayParameters` with `workloadClaims.enabled: true` alone doesn't make a hop mint or forward anything — that only comes from an explicit `backend.workloadIdentity` policy (`demo-waypoint-emit` above). Without it, `demo-waypoint` can genuinely process a request (correct routing via the `use-waypoint`/`ingress-use-waypoint` labels) while still leaving no trace of itself in `X-Forwarded-Workload-Identity`, since nothing tells it to append its own identity to the chain — indistinguishable from a bypass by looking at the header alone. Confirm by checking the waypoint's own access log for `gateway=demo/demo-waypoint ... src.identity=...` before assuming it's a routing problem, not a missing-policy one.

Verify `workload-a1 → wpt-cel-egress → demo-waypoint → workload-a2`:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-a2/headers'
```

---

## Set up `workload-a1 → wpt-cel-egress → portfolio-b-pig → workload-b1`:

**Missing piece, same as the `pig-kgateway.i-pig.mesh.internal` case documented above:** a `kind: Hostname` backendRef needs an actual `ServiceEntry` publishing that hostname in the *consuming* namespace (`i-pig`) — the auto-generated cross-cluster mirror `ServiceEntry` doesn't work here either, per the same three gotchas already noted (can't be a `targetRefs` target, name-vs-hostname confusion, wrong namespace). Fetch `workload-b1`'s actual pod IP on cluster-3 first — a `ServiceEntry` endpoint bypasses the Service/kube-proxy entirely and must point at the pod directly, not at the ClusterIP:

```bash
WORKLOAD_B1_IP=$(kubectl --context $REMOTE_CONTEXT3 get pod -n demo -l app=workload-b1 \
  -o jsonpath='{.items[0].status.podIP}')
echo $WORKLOAD_B1_IP
```

```bash
kubectl --context $REMOTE_CONTEXT1 create namespace i-pig

kubectl --context $REMOTE_CONTEXT1 label namespace i-pig istio.io/dataplane-mode=ambient --overwrite

kubectl --context $REMOTE_CONTEXT1 apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: workload-b1-mesh-internal
  namespace: i-pig
spec:
  hosts:
  - workload-b1.demo.mesh.internal
  location: MESH_EXTERNAL
  resolution: STATIC
  ports:
  - number: 8000
    name: http
    protocol: HTTP
  endpoints:
  - address: ${WORKLOAD_B1_IP}
    ports:
      http: 8080
---
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
      networking.istio.io/tunnel: "http"
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: portfolio-b-pig-params
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
      mode: "RequireProof"
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
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: portfolio-b-pig-to-workload-b1
  namespace: i-pig
spec:
  parentRefs:
  - name: portfolio-b-pig
    namespace: i-pig
  rules:
  - matches:
    - path
        type: PathPrefix
        value: /workload-b1
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
  - backendRefs:
    - group: networking.istio.io
      kind: Hostname
      name: workload-b1.demo.mesh.internal
      port: 8000
EOF
```

### Proof: `enterprise-kgateway` resolves the same `Hostname` backendRef with no manual `ServiceEntry`

```bash
helm uninstall enterprise-agentgateway-crds \
  --kube-context ${REMOTE_CONTEXT1} \
  -n agentgateway-system
```

```bash
export KGW_VERSION=2.2.0

helm upgrade -i enterprise-kgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds \
  --create-namespace \
  --namespace kgateway-system \
  --version ${KGW_VERSION} \
  --kube-context ${REMOTE_CONTEXT1}

helm upgrade -i enterprise-kgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway \
  -n kgateway-system \
  --version ${KGW_VERSION} \
  --set-string licensing.licenseKey=$GLOO_LICENSE_KEY \
  --set controller.extraEnv.KGW_ENABLE_ISTIO_INTEGRATION=true \
  --kube-context ${REMOTE_CONTEXT1}

kubectl --context $REMOTE_CONTEXT1 apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kgw-proof
  namespace: i-pig
spec:
  gatewayClassName: enterprise-kgateway
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kgw-proof-to-workload-b1
  namespace: i-pig
spec:
  parentRefs:
  - name: kgw-proof
    namespace: i-pig
  rules:
  - backendRefs:
    - group: networking.istio.io
      kind: Hostname
      name: workload-b1.demo.mesh.internal
      port: 8000
EOF
```

Verify:
```bash
export KGW_PROOF_IP=$(kubectl --context $REMOTE_CONTEXT1 get gtw -n i-pig kgw-proof -ojsonpath='{.status.addresses[0].value}')
echo $KGW_PROOF_IP
curl -si http://$KGW_PROOF_IP/headers
```

- **`200 OK`** → confirms the hypothesis: `enterprise-kgateway`'s controller resolves the auto-generated cross-cluster mirror `ServiceEntry` as a valid `Hostname` backend target where `enterprise-agentgateway`'s controller doesn't — a genuine product difference, not a general Gateway API/Istio limitation.
- **Same `"no ServiceEntry ... publishes hostname"`-style failure** → the gap is more fundamental (e.g. something about `workload-b1`'s specific `service-scope: global` federation, not agentgateway specifically) and the earlier conclusion needs revisiting.

Clean up after: `kubectl --context $REMOTE_CONTEXT1 delete gateway kgw-proof -n i-pig; kubectl --context $REMOTE_CONTEXT1 delete httproute kgw-proof-to-workload-b1 -n i-pig` (leave the Helm releases in place only if you want to keep testing kgateway further).

---













---

## 2.1 Deploy `demo-egress-waypoint` (agentgateway) on `cluster-2`

`demo-egress-waypoint` intercepts outbound traffic from workload-A. It operates as an egress waypoint for the `source-demo` namespace on cluster-2: when workload-A sends a plain HTTP request, ztunnel routes it through this agentgateway before it leaves the cluster. Workload-A's own ztunnel already forwards a WIT for its SPIFFE identity on the outbound HBONE connection (from the SAN claims istiod embedded in its cert — enabled by `ENABLE_WORKLOAD_CLAIMS=true` on ztunnel and `workloadClaims.enabled: true` below), so the egress waypoint's job is to forward that WIT via `SourceDelegation` — transparently, without any application involvement.

```bash
kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: demo-egress-waypoint-params
  namespace: source-demo
spec:
  workloadClaims:
    enabled: true
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo-egress-waypoint
  namespace: source-demo
  labels:
    istio.io/waypoint-for: all
spec:
  gatewayClassName: enterprise-agentgateway-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
    allowedRoutes:
      namespaces:
        from: All
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: demo-egress-waypoint-params
EOF
```

```bash
kubectl --context $REMOTE_CONTEXT2 get gateway.gateway.networking.k8s.io -n source-demo
kubectl --context $REMOTE_CONTEXT2 rollout status deployment/demo-egress-waypoint -n source-demo --timeout=120s
```

Verify the pod obtained its Istio certificate:
```bash
kubectl --context $REMOTE_CONTEXT2 logs -n source-demo \
  -l gateway.networking.k8s.io/gateway-name=demo-egress-waypoint \
  | grep -E "Successfully fetched|marking server ready"
```

### 2.2 Configure SourceDelegation at `demo-egress-waypoint`

`SourceDelegation` instructs the egress waypoint to forward the inbound WIT on its verified HBONE connection — the WIT workload-A's ztunnel already attached from its SAN-embedded SPIFFE identity — rather than minting a new one. `emitProof: true` produces a WPT binding that WIT to this verified connection, allowing `pig-kgateway` downstream to forward it with confidence via its own `SourceDelegation` policy.

This targets a `ServiceEntry` for `pig-kgateway` rather than the `demo-egress-waypoint` Gateway directly (the original, simpler approach — still valid, see the commented block below) to scope the delegation specifically to egress traffic bound for `pig-kgateway`, matching Solo's own documented pattern for egress-to-a-named-destination (`docs.solo.io/istio/1.31.x/agentic-mesh/egress/`).

Three things had to be fixed to get this to attach, each confirmed live:
1. **The auto-generated cross-cluster mirror `ServiceEntry` (`autogen.i-pig.pig-kgateway`, in `istio-system`) can't be used as a `targetRefs` target at all** — `EnterpriseAgentgatewayPolicy` never attaches to it, `use-waypoint`-labeling it has no effect. A manually-defined `ServiceEntry` is required instead.
2. **`targetRefs.name` must be the ServiceEntry's own Kubernetes object name, not the hostname it publishes** (`pig-kgateway.i-pig.mesh.internal` is a `spec.hosts` entry, not a `metadata.name` — using it as the latter produces `"ServiceEntry ... not found"`).
3. **The `ServiceEntry` and the policy both have to live in `demo-egress-waypoint`'s own namespace (`source-demo`), not `istio-system`.** `istio.io/use-waypoint` resolves the named waypoint within the same namespace as the label; `EnterpriseAgentgatewayPolicy`'s `targetRefs` has no cross-namespace support at all (confirmed elsewhere in this `046` series — patching one in fails with `strict decoding error: unknown field`).

```bash
# Original, simpler approach — targets the Gateway directly, still valid:
# kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
# apiVersion: enterpriseagentgateway.solo.io/v1alpha1
# kind: EnterpriseAgentgatewayPolicy
# metadata:
#   name: demo-egress-source-delegation
#   namespace: source-demo
# spec:
#   targetRefs:
#   - group: gateway.networking.k8s.io
#     kind: Gateway
#     name: demo-egress-waypoint
#   backend:
#     workloadIdentity:
#       mode: SourceDelegation
#       emitProof: true
#       proofLifetime: 60s
# EOF
export PIG_KGATEWAY_IP=$(kubectl --context $REMOTE_CONTEXT1 get svc pig-kgateway -n i-pig \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $PIG_KGATEWAY_IP

kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: pig-kgateway-mesh-internal
  namespace: source-demo
  labels:
    istio.io/use-waypoint: demo-egress-waypoint
spec:
  hosts:
  - pig-kgateway.i-pig.mesh.internal
  location: MESH_EXTERNAL
  resolution: STATIC
  ports:
  - number: 80
    name: http
    protocol: HTTP
  endpoints:
  - address: ${PIG_KGATEWAY_IP}
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: demo-egress-source-delegation
  namespace: source-demo
spec:
  targetRefs:
  - kind: ServiceEntry
    group: networking.istio.io
    name: pig-kgateway-mesh-internal
  backend:
    workloadIdentity:
      mode: SourceDelegation
      emitProof: true
      proofLifetime: 60s
EOF
```

Verify it actually attached before moving on:
```bash
kubectl --context $REMOTE_CONTEXT2 get enterpriseagentgatewaypolicy demo-egress-source-delegation -n source-demo \
  -o jsonpath='{.status.ancestors[0].conditions}'
# Expected: ..."message":"Attached to all targets"...
```

### 2.3 Route workload-A outbound traffic through `demo-egress-waypoint`

Workload-A's ServiceAccount needs to be labeled so ztunnel routes its outbound HBONE connections through the egress waypoint — but `workload-a-sa` doesn't exist yet at this point in the lab. **Don't run this yet**; it's done in §3.1, once §3.0 has created the ServiceAccount.

---

## 2.4 Deploy `pig-kgateway` (agentgateway) on `cluster-1`

`pig-kgateway` is the PIG gateway on cluster-1. It uses `enterprise-agentgateway` (not the waypoint variant) and listens on HTTP port 80 as a standard ingress gateway. Because it is itself agentgateway, it participates natively in the WIT chain via `SourceDelegation` — no separate `pig-waypoint` component is needed.

```bash
kubectl --context $REMOTE_CONTEXT1 apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: pig-kgateway-params
  namespace: i-pig
spec:
  workloadClaims:
    enabled: true
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: pig-kgateway
  namespace: i-pig
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: pig-kgateway-params
EOF
```

```bash
kubectl --context $REMOTE_CONTEXT1 get gateway.gateway.networking.k8s.io -n i-pig
kubectl --context $REMOTE_CONTEXT1 rollout status deployment/pig-kgateway -n i-pig --timeout=120s
```

Verify the pod obtained its Istio certificate:
```bash
kubectl --context $REMOTE_CONTEXT1 logs -n i-pig \
  -l gateway.networking.k8s.io/gateway-name=pig-kgateway \
  | grep -E "Successfully fetched|marking server ready"
```

### 2.5 Configure SourceDelegation at `pig-kgateway`

`pig-kgateway` receives requests from `demo-egress-waypoint` that already carry workload-A's WIT (hoisted in §2.2). `SourceDelegation` forwards that WIT to the backend (`demo-waypoint` on cluster-3) and emits a fresh WPT proving pig-kgateway received it over a verified mTLS connection from the egress waypoint.

```bash
kubectl --context $REMOTE_CONTEXT1 apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: pig-kgateway-source-delegation
  namespace: i-pig
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: pig-kgateway
  backend:
    workloadIdentity:
      mode: SourceDelegation
      emitProof: true
      proofLifetime: 60s
EOF
```

---

## 2.6 Deploy `demo-waypoint` (agentgateway) on `cluster-3`

```bash
kubectl --context $REMOTE_CONTEXT3 apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: demo-waypoint-params
  namespace: i-pig
spec:
  workloadClaims:
    enabled: true
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo-waypoint
  namespace: i-pig
  labels:
    istio.io/waypoint-for: all
spec:
  gatewayClassName: enterprise-agentgateway-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
    allowedRoutes:
      namespaces:
        from: All
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: demo-waypoint-params
EOF
```

```bash
kubectl --context $REMOTE_CONTEXT3 get gateway.gateway.networking.k8s.io -n i-pig
kubectl --context $REMOTE_CONTEXT3 rollout status deployment/demo-waypoint -n i-pig --timeout=120s
```

Verify Istio certificate issuance on `cluster-3`:
```bash
kubectl --context $REMOTE_CONTEXT3 logs -n i-pig \
  -l gateway.networking.k8s.io/gateway-name=demo-waypoint \
  | grep -E "Successfully fetched|marking server ready"
```

### 2.7 Label `i-pig` namespace to route through `demo-waypoint`

```bash
kubectl --context $REMOTE_CONTEXT3 label ns i-pig istio.io/use-waypoint=demo-waypoint --overwrite
kubectl --context $REMOTE_CONTEXT3 label ns i-pig istio.io/ingress-use-waypoint=true --overwrite
```

### 2.8 Configure WPT enforcement and authorization at `demo-waypoint`

PeerBound enforcement validates the WPT chain. The authorization policy uses `workloadIdentity.chain.origin` — which resolves to workload-A's SPIFFE identity, hoisted by `demo-egress-waypoint` and re-signed by `pig-kgateway`, preserved end-to-end even though workload-A never attached a WIT header.

```bash
kubectl --context $REMOTE_CONTEXT3 apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: demo-waypoint-wpt-enforce
  namespace: i-pig
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: demo-waypoint
  traffic:
    entWptEnforcement:
      mode: PeerBound
EOF
```

```bash
kubectl --context $REMOTE_CONTEXT3 apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: demo-waypoint-authz
  namespace: i-pig
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: workload-b
  traffic:
    authorization:
      action: Allow
      policy:
        matchExpressions:
        - 'workloadIdentity.chain.origin.endsWith("/ns/source-demo/sa/workload-a-sa")'
EOF
```

---

## 3.0 Deploy Sample Workloads

```bash
kubectl --context $REMOTE_CONTEXT2 -n source-demo apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-a-sa
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workload-a
spec:
  replicas: 1
  selector:
    matchLabels:
      app: workload-a
  template:
    metadata:
      labels:
        app: workload-a
    spec:
      serviceAccountName: workload-a-sa
      containers:
      - name: netshoot
        image: nicolaka/netshoot
        command: ["sleep", "infinity"]
EOF
```

```bash
kubectl --context $REMOTE_CONTEXT3 -n i-pig apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-b-sa
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workload-b
spec:
  replicas: 1
  selector:
    matchLabels:
      app: workload-b
  template:
    metadata:
      labels:
        app: workload-b
    spec:
      serviceAccountName: workload-b-sa
      containers:
      - name: httpbin
        image: mccutchen/go-httpbin:v2.15.0
        ports:
        - containerPort: 8080
          name: http
---
apiVersion: v1
kind: Service
metadata:
  name: workload-b
  labels:
    solo.io/service-scope: global
spec:
  selector:
    app: workload-b
  ports:
  - port: 80
    targetPort: http
    name: http
EOF
```

```bash
kubectl --context $REMOTE_CONTEXT2 wait --for=condition=ready pod -l app=workload-a -n source-demo --timeout=120s
kubectl --context $REMOTE_CONTEXT2 get pods -n source-demo

kubectl --context $REMOTE_CONTEXT3 wait --for=condition=ready pod -l app=workload-b -n i-pig --timeout=120s
kubectl --context $REMOTE_CONTEXT3 get pods -n i-pig
```

### 3.1 Label workload-A's ServiceAccount for egress waypoint

Route outbound traffic from workload-A through `demo-egress-waypoint`:

```bash
kubectl --context $REMOTE_CONTEXT2 label serviceaccount workload-a-sa -n source-demo \
  istio.io/use-waypoint=demo-egress-waypoint
```

### 3.2 Create an HTTPRoute to reach workload-B via PIG

```bash
kubectl --context $REMOTE_CONTEXT1 apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: workload-b-route
  namespace: i-pig
spec:
  parentRefs:
  - name: pig-kgateway
    namespace: i-pig
  rules:
  - backendRefs:
    - group: networking.istio.io
      kind: Hostname
      name: workload-b.i-pig.mesh.internal
      port: 80
EOF
```

Label `pig-kgateway` as a global service so workload-A can reach it cross-cluster:
```bash
kubectl --context $REMOTE_CONTEXT1 label svc pig-kgateway -n i-pig solo.io/service-scope=global
```

Verify PIG → workload-B is reachable:
```bash
export GW_IP=$(kubectl --context $REMOTE_CONTEXT1 get gtw -n i-pig pig-kgateway \
  -ojsonpath='{.status.addresses[0].value}')
echo $GW_IP
curl -si http://$GW_IP/headers
# Expected: HTTP/1.1 200 OK
```

---

## 4.0 Observe WIT Propagation

### 4.1 Send plain request via PIG — egress waypoint hoists WIT automatically

workload-A sends a plain HTTP request with no identity headers. `demo-egress-waypoint` on cluster-2 intercepts the outbound traffic, reads workload-A's SPIFFE identity from the mTLS connection, and mints a WIT for `workload-a-sa`. `pig-kgateway` on cluster-1 forwards the WIT via `SourceDelegation` and emits a fresh WPT. `demo-waypoint` validates the WPT chain and authorizes based on `workload-a-sa`.

```bash
kubectl --context $REMOTE_CONTEXT2 exec -n source-demo \
  $(kubectl --context $REMOTE_CONTEXT2 get pod -n source-demo -l app=workload-a -o jsonpath='{.items[0].metadata.name}') \
  -- curl -si http://pig-kgateway.i-pig.mesh.internal/headers \
  | grep -i -E "Workload-Identity-Token|Workload-Proof-Token"
```

Originally expected — workload-B echoing back the WIT and WPT as headers:
```
"Workload-Identity-Token": ["eyJ..."]
"Workload-Proof-Token": ["eyJ..."]
```

**This does not currently happen.** Neither header appears at `workload-B` in this build, with or without `entWptEnforcement` configured — see the verification bug called out above. Attaching these headers to the upstream request appears to depend on `entWptEnforcement` actually running at the receiving gateway, which then always rejects the request before it reaches the backend once a real WIT/WPT is validated. **Skip to §5.1** for a working way to prove identity propagation that doesn't depend on this broken path.

### 4.2 Confirm via `demo-waypoint` access logs on `cluster-3`

```bash
kubectl --context $REMOTE_CONTEXT3 logs -n i-pig \
  -l gateway.networking.k8s.io/gateway-name=demo-waypoint \
  --tail=10
```

Expected for an authorized request:
```
info  request gateway=i-pig/demo-waypoint ... http.status=200 protocol=http duration=Xms
```

Denied requests log:
```
info  request ... http.status=403 error="authorization failed" reason=Authorization duration=0ms
```

### 4.3 Confirm via `pig-kgateway` access logs on `cluster-1`

agentgateway logs WIT/WPT fields natively — no custom log format configuration required:

```bash
kubectl --context $REMOTE_CONTEXT1 logs -n i-pig \
  -l gateway.networking.k8s.io/gateway-name=pig-kgateway \
  --tail=5
```

---

## 5.0 Verify Unauthorized Identity is Rejected

> **Currently not runnable as written.** This scenario depends on `demo-waypoint-wpt-enforce` + `demo-waypoint-authz` (§2.8) being active at `demo-waypoint`, but those policies always trip the verification bug from the Alpha-feature callout above — they reject *every* request, not just unauthorized ones. This lab's live state has both policies removed (see §5.1). Re-apply them from §2.8 only once the underlying bug is fixed upstream.

A pod running as a different ServiceAccount (`other-sa`) is NOT labeled to use the egress waypoint, so no WIT is hoisted for its outbound traffic. The request arrives at `pig-kgateway` without a WIT; `SourceDelegation` has nothing to forward; `demo-waypoint` sees no `chain.origin` matching `workload-a-sa` and returns 403.

```bash
kubectl --context $REMOTE_CONTEXT2 -n source-demo create serviceaccount other-sa 2>/dev/null || true

kubectl --context $REMOTE_CONTEXT2 run curl-deny -n source-demo \
  --image=nicolaka/netshoot --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"other-sa"}}' \
  -- curl -si http://pig-kgateway.i-pig.mesh.internal/headers

until kubectl --context $REMOTE_CONTEXT2 get pod curl-deny -n source-demo \
  -o jsonpath='{.status.phase}' 2>/dev/null | grep -qE "Succeeded|Failed"; do sleep 2; done
kubectl --context $REMOTE_CONTEXT2 logs curl-deny -n source-demo | grep "HTTP/"
kubectl --context $REMOTE_CONTEXT2 delete pod curl-deny -n source-demo --ignore-not-found
```

Expected:
```
HTTP/1.1 403 Forbidden
```

---

## 5.1 Final demonstration: proving identity propagation without WPT enforcement

Because `entWptEnforcement` cannot currently validate a WIT/WPT without hitting the bug above, this section proves identity propagation a different way: `SourceDelegation` operates at the **mTLS connection level**, independent of WIT/WPT header verification. `demo-egress-waypoint` doesn't just relay a claim in a header — it re-establishes its own outbound connection to the next hop *as* workload-A's SPIFFE identity (a delegated credential). The receiving proxy reports that as the connection's verified peer identity (`src.identity`) in its own access log, with no `entWptEnforcement` or `AuthorizationPolicy` involved.

Make sure neither `demo-waypoint-wpt-enforce` nor `demo-waypoint-authz` is applied — they only trigger the verification bug and reject the request before this can be observed:

```bash
kubectl --context $REMOTE_CONTEXT3 delete enterpriseagentgatewaypolicy \
  demo-waypoint-wpt-enforce demo-waypoint-authz -n i-pig --ignore-not-found
```

**Before — through `pig-kgateway`.** `pig-kgateway` is a plain ingress gateway (not ambient-captured — see the "Known issue" discussion in the investigation history), so it terminates the connection from `demo-egress-waypoint` and re-originates a new one *as itself*, not as workload-A. The original caller's identity is lost at this hop:

```bash
kubectl --context $REMOTE_CONTEXT2 exec -n source-demo \
  $(kubectl --context $REMOTE_CONTEXT2 get pod -n source-demo -l app=workload-a -o jsonpath='{.items[0].metadata.name}') \
  -- curl -s -o /dev/null -w "status=%{http_code}\n" http://pig-kgateway.i-pig.mesh.internal/headers

kubectl --context $REMOTE_CONTEXT3 logs -n i-pig -l gateway.networking.k8s.io/gateway-name=demo-waypoint --tail=1
```

Captured result — `src.identity` is `pig-kgateway`'s own identity, not workload-A's:
```
status=200
2026-09-10T17:13:25.886239Z info request gateway=i-pig/demo-waypoint listener=waypoint route=i-pig/_waypoint-default endpoint=workload-b.i-pig.mesh.internal:80 src.addr=10.10.2.8:58460 src.identity=spiffe://cluster.local/ns/i-pig/sa/pig-kgateway http.method=GET http.host=workload-b.i-pig.mesh.internal http.path=/headers http.version=HTTP/1.1 http.status=200 protocol=http duration=9ms
```

**After — direct workload-A → workload-B, bypassing `pig-kgateway`.** workload-A's outbound traffic always routes through `demo-egress-waypoint` (SA label in §3.1), so even a direct call to workload-B still goes through a real ambient waypoint on each end — it just skips the one hop (`pig-kgateway`) that can't delegate:

```bash
kubectl --context $REMOTE_CONTEXT2 exec -n source-demo \
  $(kubectl --context $REMOTE_CONTEXT2 get pod -n source-demo -l app=workload-a -o jsonpath='{.items[0].metadata.name}') \
  -- curl -s -o /dev/null -w "status=%{http_code}\n" http://workload-b.i-pig.mesh.internal/headers

kubectl --context $REMOTE_CONTEXT3 logs -n i-pig -l gateway.networking.k8s.io/gateway-name=demo-waypoint --tail=1
```

Captured result — `src.identity` is workload-A's own SPIFFE identity, delegated end-to-end by `demo-egress-waypoint`'s `SourceDelegation` and verified cryptographically by the mTLS handshake, no header or proof token involved:
```
status=200
2026-09-10T17:13:28.972866Z info request gateway=i-pig/demo-waypoint listener=waypoint route=i-pig/_waypoint-default endpoint=workload-b.i-pig.mesh.internal:80 src.addr=10.20.0.18:56398 src.identity=spiffe://cluster.local/ns/source-demo/sa/workload-a-sa http.method=GET http.host=workload-b.i-pig.mesh.internal http.path=/headers http.version=HTTP/1.1 http.status=200 protocol=http duration=2ms
```

**Conclusion:** identity propagation from workload-A to workload-B is real and provable via `SourceDelegation`'s connection-level identity delegation (`src.identity` in the receiving proxy's access log), independent of the currently-broken WIT/WPT header verification path. The one hop that can't preserve it — `pig-kgateway`, a plain ingress gateway that terminates and re-originates the connection as itself — is the same hop where `entWptEnforcement` was meant to re-attach proof of the original identity, which is exactly the path blocked by the verification bug.

---

## Cleanup

```bash
./data/cleanup-3-3n-gke-clusters.sh
```

