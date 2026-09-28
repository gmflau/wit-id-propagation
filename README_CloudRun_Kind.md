---
author: Gilbert Lau
date: "September 21, 2026"
versions:
  "Solo istio distro": 1.31.0
  "enterprise-agentgateway": v2026.9.2
title: "WIT Identity Propagation from a Cloud Run–style Workload (Dedicated Ztunnel Sidecar, Local Kind Multi-Cluster)"
---

# WIT Identity Propagation: workload-a1 (Cloud Run stand-in) → Agentgateway Egress → Agentgateway PIG Gateway → Agentgateway Waypoint → workload-b1

## Overview

This is a variant of [README_Kind.md](./README_Kind.md). Everything about the mesh, the agentgateway hops, and the destination workloads is unchanged — the only thing that changes is **how `workload-a1` gets onto the mesh in the first place**.

In README_Kind.md, `workload-a1` is an ordinary ambient pod: it sits in a namespace labeled `istio.io/dataplane-mode=ambient`, and the **node's shared ztunnel** (an Istio CNI-injected DaemonSet pod) transparently captures its egress and stamps its WIT onto the outbound HBONE connection. That works because `workload-a1` is running on a Kubernetes node with the ambient CNI installed.

A **Cloud Run service (or an ECS task, or any VM/serverless compute)** has no such node. There's no ambient CNI, no per-node ztunnel DaemonSet, nothing to transparently intercept its egress or mint a WIT from its mTLS SAN claims. To bring that kind of workload into the same WIMSE identity chain, the workload has to carry **its own dedicated ztunnel** — a sidecar container running in `PROXY_MODE=dedicated` that does its own outbound capture (via `iptables-nft`, since there's no CNI to do it for you), its own CSR/mTLS bootstrap against istiod, and presents the workload's WIT on outbound HBONE exactly like the shared ztunnel would.

This lab reproduces that shape locally: `workload-a1` is redeployed as a two-container pod (`app` + a dedicated `ztunnel` sidecar) that has **opted out** of cluster-2's shared ambient dataplane (`istio.io/dataplane-mode: none`) — as if it had never been scheduled onto a mesh node at all, which is exactly the Cloud Run situation.

This pattern is validated by Solo's enterprise conformance suite: `solo-io/enterprise-conformance-tests` PR #2 ("WPT tests") adds a `WorkloadProofToken/ingress_bootstrap/dedicated_sidecar` conformance case exercising precisely this shape — see `harness/dedicated_ztunnel_sidecar.go` and `harness/templates/vm_dedicated_ztunnel_sidecar_deployment.yaml` in that PR. This lab is a hand-run, Kind-based reproduction of that same pattern, wired into the existing multi-hop WIT/WPT topology from README_Kind.md rather than the conformance harness's single-hop ingress test.

**Full traffic path:**
```
workload-a1 (dedicated ztunnel sidecar, simulating Cloud Run) → (HBONE) → wpt-cel-egress → (east-west) → portfolio-b-pig → (east-west) → demo-waypoint → workload-b1
```

**Cluster layout** (identical to README_Kind.md):
- `cluster-1` — `portfolio-b-pig` (agentgateway PIG gateway), `i-pig` namespace
- `cluster-2` — `wpt-cel-egress` (agentgateway egress), **`workload-a1` (Cloud Run stand-in, dedicated ztunnel sidecar)**, `demo`/`i-peg`/`i-pig` namespaces
- `cluster-3` — `demo-waypoint` (agentgateway waypoint), `workload-b1` (go-httpbin), `demo` namespace

**How this works:**
- `workload-a1`'s pod now runs **two containers**: `app` (the same `curlimages/curl` sleeper as before) and `ztunnel` (`PROXY_MODE=dedicated`) — plus two shell-less `iptables-nft` init containers that redirect the app container's egress into the sidecar. This is the workload doing for itself what the CNI + shared ztunnel do transparently for every other ambient pod on a real node.
- The pod is labeled `istio.io/dataplane-mode: none`, which opts it **out** of cluster-2's shared ambient dataplane even though its namespace (`demo`) is ambient-enabled. A real Cloud Run instance was never inside that dataplane to begin with — this label just makes the Kind pod behave the same way.
- Because the pod is excluded from ambient workload aggregation, istiod has no automatic way to learn its identity. It's registered manually via a `WorkloadEntry` named to match the sidecar's `PROXY_WORKLOAD_INFO` value, so the dedicated ztunnel's own XDS self-lookup resolves — mirroring `applyDedicatedZtunnelWorkloadEntry` in the conformance harness referenced above.
- The dedicated ztunnel still sets `ENABLE_WORKLOAD_CLAIMS=true` and reads its identity from its own istiod-issued mTLS cert, exactly like the shared ztunnel does — so it hoists the same WIT onto the outbound HBONE connection to `wpt-cel-egress`.
- Everything downstream — `wpt-cel-egress` (bootstraps + mints a WPT), `portfolio-b-pig` (`PeerBound` enforce, `SourceDelegation` re-mint), `demo-waypoint` (`PeerBound` enforce) — is **byte-for-byte identical** to README_Kind.md. From the receiving side, a dedicated-ztunnel-fronted workload and a shared-ztunnel-fronted workload are indistinguishable: both simply present a valid WIT over a verified HBONE connection.

**Ambient shared ztunnel vs. dedicated ztunnel sidecar (Cloud Run shape):**

| Aspect | Ambient shared ztunnel (README_Kind.md) | Dedicated ztunnel sidecar (this doc) |
|---|---|---|
| What captures egress | Node-level CNI + shared `ztunnel` DaemonSet pod | Two `iptables-nft` init containers in the workload's own pod |
| `PROXY_MODE` | `shared` (implicit, DaemonSet default) | `dedicated` |
| Identity bootstrap | Pod SA token via CNI-mounted socket, automatic | Projected `serviceAccountToken` (`audience: istio-ca`) mounted directly into the sidecar |
| Workload discovery | Automatic — istiod indexes every ambient pod | Manual — a `WorkloadEntry` named to match `PROXY_WORKLOAD_INFO` |
| Dataplane-mode label | `ambient` (namespace-level, inherited) | `none` (pod-level override) |
| Real-world analogue | Any pod on a GKE/Kind node with ambient CNI | Cloud Run, ECS Fargate, a bare VM — anything without a node-level mesh dataplane |
| WIT/WPT chain behavior at every downstream hop | Identical | Identical |

**Key concepts (new in this doc — see README_Kind.md for WIT/WPT/SourceDelegation/PeerBound basics):**
- **`PROXY_MODE=dedicated`:** tells ztunnel it is the sole proxy for exactly one workload identity, not a shared per-node proxy multiplexing many pods.
- **`PROXY_WORKLOAD_INFO`:** `<namespace>/<serviceAccount>/<name>` — the identity the dedicated ztunnel looks itself up as in istiod's workload API. The `WorkloadEntry` must be named to match, or the lookup never resolves.
- **`PACKET_MARK` (`1337` = `0x539`):** the dedicated ztunnel marks its own outbound sockets with this value; the `iptables-nft` redirect rule explicitly excludes marked traffic so the ztunnel's own connections to istiod/upstream don't loop back into its own outbound listener (port 15001).
- **`istio.io/dataplane-mode: none`:** a pod-level label that overrides the namespace's `ambient` label, opting a single pod out of the shared dataplane so its own dedicated ztunnel is unambiguously responsible for it.
- **`iptables-nft` init containers:** the install-cni image is distroless (no shell), so the redirect rules are invoked as a direct `iptables-nft` argv rather than a shell script. The istiod-return rule (port 15012) must be added *before* the catch-all outbound redirect, or the sidecar's own control-plane traffic loops into port 15001.

> **Simplification vs. a genuine off-cluster VM/Cloud Run instance:** because this pod is still scheduled by Kubernetes, its `istio-token` is a kubelet-managed **projected `serviceAccountToken`** (auto-rotated, `audience: istio-ca`) — the same mechanism a normal `istio-proxy` sidecar uses. A workload that is *actually* outside Kubernetes (a real Cloud Run instance, an EC2 box) has no kubelet to project that token for it, so it instead needs the static, long-lived `istio-token` Secret that `istioctl x workload entry configure` generates for VM onboarding. The dedicated-ztunnel mechanics (`PROXY_MODE=dedicated`, the `iptables-nft` capture, the `WorkloadEntry`) are identical either way — only the token delivery differs.

> **Alpha feature:** WIMSE WIT/WPT support is in alpha and not production-ready. See README_Kind.md's mode-correction note for `workloadIdentity.mode` — the same applies here.

---

## 1.0 Shared infrastructure (identical to README_Kind.md)

Everything through installing `enterprise-agentgateway` is unchanged. Run these exactly as in [README_Kind.md](./README_Kind.md) §1.1–2.0 before continuing.

### 1.1 Create the Kind Clusters

```bash
./data/setup-3-kind-clusters.sh
```

### 1.2 Install the Ambient Mesh

```bash
./data/setup-ambient-mc-fn3-kind.sh
```

Requires `SOLO_LICENSE_KEY` and `GLOO_MESH_LICENSE_KEY` in your environment.

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
export AGENTGATEWAY_VERSION=v2026.9.2
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
enterprise-agentgateway            solo.io/enterprise-agentgateway   True       21s
enterprise-agentgateway-waypoint   solo.io/enterprise-agentgateway   True       21s
```

---

## 3.0 Deploy workloads

### 3.1 Deploy `workload-a1` as a Cloud Run stand-in (dedicated ztunnel sidecar)

Unlike README_Kind.md, `workload-a1` is **not** a plain ambient pod. It's a two-container pod that fronts itself with its own `PROXY_MODE=dedicated` ztunnel and has opted out of cluster-2's shared ambient dataplane.

**Resolve the mesh's own ztunnel/CNI images.** The sidecar must run the same Solo ztunnel build the mesh already uses (WIT-capable) — not some other public image:

```bash
export CLUSTER2_ZTUNNEL_IMAGE=$(kubectl --context $REMOTE_CONTEXT2 -n istio-system get daemonset ztunnel -o jsonpath='{.spec.template.spec.containers[0].image}')
export CLUSTER2_CNI_IMAGE=$(kubectl --context $REMOTE_CONTEXT2 -n istio-system get daemonset istio-cni-node -o jsonpath='{.spec.template.spec.containers[0].image}')

echo "ztunnel image: $CLUSTER2_ZTUNNEL_IMAGE"
echo "cni image:     $CLUSTER2_CNI_IMAGE"
```

**Confirm the CA root cert configmap exists in `demo`.** Istiod auto-populates `istio-ca-root-cert` into every namespace it watches; this just double-checks it before the pod mounts it:

```bash
kubectl --context $REMOTE_CONTEXT2 get configmap istio-ca-root-cert -n demo
```

**Deploy the pod:**

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
      annotations:
        sidecar.istio.io/inject: "false"
      labels:
        app: workload-a1
        # Opts this pod OUT of cluster-2's shared ambient dataplane -- as if it were never
        # scheduled onto a mesh node at all. This is what makes it behave like Cloud Run: its
        # own dedicated ztunnel below is now solely responsible for its mesh identity.
        istio.io/dataplane-mode: none
    spec:
      serviceAccountName: workload-a1
      automountServiceAccountToken: false
      initContainers:
      # Shell-less iptables-nft (install-cni is distroless). Order matters: istiod's own
      # control-plane traffic must RETURN before the catch-all REDIRECT, or the sidecar
      # ztunnel's own XDS/CA connection would loop back into its own outbound listener (15001).
      - name: redirect-istiod-return
        image: ${CLUSTER2_CNI_IMAGE}
        securityContext: {privileged: true, runAsUser: 0, runAsNonRoot: false, capabilities: {add: ["NET_ADMIN", "NET_RAW"]}}
        command: ["iptables-nft", "-w", "-t", "nat", "-A", "OUTPUT", "-p", "tcp", "--dport", "15012", "-j", "RETURN"]
      - name: redirect-outbound
        image: ${CLUSTER2_CNI_IMAGE}
        securityContext: {privileged: true, runAsUser: 0, runAsNonRoot: false, capabilities: {add: ["NET_ADMIN", "NET_RAW"]}}
        command: ["iptables-nft", "-w", "-t", "nat", "-A", "OUTPUT", "-p", "tcp", "!", "-o", "lo", "-m", "mark", "!", "--mark", "0x539/0xfff", "-j", "REDIRECT", "--to-ports", "15001"]
      containers:
      - name: ztunnel
        # The mesh's own Solo ztunnel build (WIT-capable) -- resolved above, not a generic image.
        image: ${CLUSTER2_ZTUNNEL_IMAGE}
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
          # Distroless ztunnel defaults to non-root; without root the SO_MARK setsockopt
          # (PACKET_MARK) returns EPERM on the outbound connect despite privileged: true.
          runAsUser: 0
          runAsNonRoot: false
          capabilities:
            add: ["SYS_ADMIN", "NET_ADMIN", "NET_RAW"]
        args: ["proxy", "ztunnel"]
        env:
        - {name: PROXY_MODE, value: "dedicated"}
        - {name: PROXY_WORKLOAD_INFO, value: "demo/workload-a1/workload-a1"}
        - {name: ENABLE_WORKLOAD_CLAIMS, value: "true"}
        - {name: PACKET_MARK, value: "1337"}
        # No IP_TRANSPARENT source spoofing available in a plain pod.
        - {name: ENABLE_ORIG_SRC, value: "false"}
        - {name: CA_ADDRESS, value: "istiod.istio-system.svc:15012"}
        - {name: XDS_ADDRESS, value: "istiod.istio-system.svc:15012"}
        - {name: NETWORK, value: "flat-network"}
        - {name: ISTIO_META_CLUSTER_ID, value: "cluster-2"}
        - name: POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        - name: POD_NAMESPACE
          valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
        - name: INSTANCE_IP
          valueFrom: {fieldRef: {fieldPath: status.podIP}}
        readinessProbe:
          httpGet: {port: 15021, path: /healthz/ready}
          initialDelaySeconds: 1
          periodSeconds: 2
        volumeMounts:
        - {mountPath: /var/run/secrets/istio, name: istiod-ca-cert}
        - {mountPath: /var/run/secrets/tokens, name: istio-token}
        - {mountPath: /tmp, name: tmp}
      - name: app
        image: curlimages/curl
        command: ["/bin/sleep", "3650d"]
        imagePullPolicy: IfNotPresent
      volumes:
      - name: istio-token
        # A real off-cluster Cloud Run instance would use a static VM-onboarding istio-token
        # Secret instead (no kubelet to project one) -- see the note in the Overview above.
        projected:
          sources:
          - serviceAccountToken:
              audience: istio-ca
              expirationSeconds: 43200
              path: istio-token
      - name: istiod-ca-cert
        configMap: {name: istio-ca-root-cert}
      - name: tmp
        emptyDir: {}
EOF

kubectl --context $REMOTE_CONTEXT2 wait --for=condition=ready pod -l app=workload-a1 -n demo --timeout=180s
```

**Register the sidecar's identity in istiod.** Because the pod opted out of ambient workload aggregation, its own dedicated ztunnel's `PROXY_WORKLOAD_INFO` self-lookup won't resolve until it's published as a `WorkloadEntry` — named to match, exactly as `applyDedicatedZtunnelWorkloadEntry` does in the conformance harness:

```bash
export WORKLOAD_A1_POD=$(kubectl --context $REMOTE_CONTEXT2 get pod -n demo -l app=workload-a1 -o jsonpath='{.items[0].metadata.name}')
export WORKLOAD_A1_POD_IP=$(kubectl --context $REMOTE_CONTEXT2 get pod -n demo $WORKLOAD_A1_POD -o jsonpath='{.status.podIP}')

kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: WorkloadEntry
metadata:
  name: workload-a1
  namespace: demo
spec:
  address: ${WORKLOAD_A1_POD_IP}
  network: flat-network
  serviceAccount: workload-a1
  labels:
    app: workload-a1
EOF
```

**Verify the dedicated ztunnel connected to istiod and issued itself a cert:**

```bash
kubectl --context $REMOTE_CONTEXT2 logs -n demo deploy/workload-a1 -c ztunnel --tail=50 | grep -i -E "certificate|xds|connected"
```

You should see log lines indicating a successful CA cert fetch and an established XDS connection — the same signal a shared ztunnel DaemonSet pod would emit, just scoped to this one workload.

### Deploy workload-a2

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

### Deploy workload-b1

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

Verify `workload-a1 → wpt-cel-egress → workload-a2` (run from the `app` container — the dedicated ztunnel sidecar transparently intercepts this):
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -c app -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-a2/headers'
```

Check the identity chain (JWT values are illustrative and omitted here — see README_Kind.md §4.0 for a full raw example; the shape is identical since `workload-a1`'s SPIFFE ID hasn't changed):
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -c app -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-a2/headers' | grep -A2 "X-Forwarded-Workload-Identity"
```

```
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress"
    ],
```

Note the origin is still `spiffe://cluster.local/ns/demo/sa/workload-a1` — the receiving side cannot tell (and doesn't need to know) whether that WIT came from a shared node ztunnel or `workload-a1`'s own dedicated sidecar.

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
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: demo-waypoint-enforce
  namespace: demo
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: demo-waypoint
  traffic:
    entWptEnforcement:
      mode: "PeerBound"
EOF

kubectl --context $REMOTE_CONTEXT2 label namespace demo istio.io/use-waypoint=demo-waypoint --overwrite
kubectl --context $REMOTE_CONTEXT2 label namespace demo istio.io/ingress-use-waypoint=true --overwrite
```

Verify `workload-a1 → wpt-cel-egress → demo-waypoint → workload-a2`:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -c app -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-a2/headers' | grep -A2 "X-Forwarded-Workload-Identity"
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
  namespace: i-pig
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

Point a route on cluster-2 (the consuming side, where `wpt-cel-egress` lives) at `portfolio-b-pig` via its cross-cluster mesh-internal hostname. It lives in the already-existing `demo` namespace, alongside `wpt-cel-egress-to-workload-a`:
```bash
kubectl --context $REMOTE_CONTEXT2 apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wpt-cel-egress-to-workload-b
  namespace: demo
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
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -c app -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-b1/headers' | grep -A2 "X-Forwarded-Workload-Identity"
```

```
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/i-pig/sa/portfolio-b-pig"
    ],
```

---

## 7.0 Set up `workload-a1 (Cloud Run stand-in) → (dedicated ztunnel) → wpt-cel-egress → (east-west) → portfolio-b-pig → (east-west) → demo-waypoint → workload-b1`:

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
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: demo-waypoint-enforce
  namespace: demo
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: demo-waypoint
  traffic:
    entWptEnforcement:
      mode: "PeerBound"
EOF

kubectl --context $REMOTE_CONTEXT3 label namespace demo istio.io/use-waypoint=demo-waypoint --overwrite
kubectl --context $REMOTE_CONTEXT3 label namespace demo istio.io/ingress-use-waypoint=true --overwrite
```

Verify the full chain, curling from `workload-a1`'s `app` container (its own dedicated ztunnel sidecar handles the HBONE origination transparently — no change to the app's request at all):
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -c app -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-b1/headers'
```

```
HTTP/1.1 200 OK
access-control-allow-credentials: true
access-control-allow-origin: *
content-type: application/json; charset=utf-8
transfer-encoding: chunked

{
  "headers": {
    "Host": ["workload-b1.demo.mesh.internal"],
    "User-Agent": ["curl/8.22.0"],
    "Workload-Identity-Token": ["<WIT JWT, minted by demo-waypoint>"],
    "Workload-Proof-Token": ["<WPT JWT, bound to demo-waypoint's verified HBONE connection>"],
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/i-pig/sa/portfolio-b-pig, spiffe://cluster.local/ns/demo/sa/demo-waypoint"
    ],
    "X-Original-Workload-Identity-Token": ["<the original WIT workload-a1's dedicated ztunnel presented>"]
  }
}
```

(JWT values above are illustrative — see README_Kind.md §7.0 for a full raw example with real tokens; the shape is byte-for-byte identical because the receiving hops cannot distinguish a dedicated-ztunnel origin from a shared one.)

Verify `X-Forwarded-Workload-Identity` — the full four-hop chain, originating from the Cloud Run stand-in:
```bash
kubectl --context $REMOTE_CONTEXT2 exec -n demo deploy/workload-a1 -c app -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/workload-b1/headers' | grep -A2 "X-Forwarded-Workload-Identity"
```

```
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/demo/sa/workload-a1, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/i-pig/sa/portfolio-b-pig, spiffe://cluster.local/ns/demo/sa/demo-waypoint"
    ],
```

`workload-a1`'s identity survives the full chain exactly as it does in README_Kind.md — the only thing that's proven differently here is that the *origin* of that identity was a dedicated ztunnel sidecar with no ambient CNI underneath it, not the shared node ztunnel. That's the Cloud Run shape.

---

## Cleanup

```bash
./data/cleanup-3-kind-clusters.sh
```
