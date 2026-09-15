# WIT/WPT Identity Propagation on Solo Enterprise Agentgateway on Istio Ambient Mesh

This lab builds a single-cluster KinD environment on Istio Ambient Mesh to test how workload identity actually propagates across a chain of Solo Enterprise Agentgateway hops, using two Solo-specific mechanisms:

- **WIT (Workload Identity Token)** — a per-workload JWT ztunnel embeds into its own mTLS cert (`ENABLE_WORKLOAD_CLAIMS`), proving a workload's SPIFFE identity.
- **WPT (Workload Proof Token)** — a short-lived JWT one gateway mints (`backend.workloadIdentity.emitProof`) to vouch for a verified caller to the next hop, enforced downstream via `traffic.entWptEnforcement`.

The topology is built up one hop at a time, each stage verified before adding the next:

```
1. sleep → wpt-cel-egress → httpbin                                    (plain egress, no waypoint)
2. sleep → wpt-cel-egress → httpbin-waypoint → httpbin                 (waypoint added, no enforcement)
3. sleep → wpt-cel-egress → httpbin-waypoint → httpbin                 (+ entWptEnforcement + proof header)
4. sleep → wpt-cel-egress → wpt-cel-ingress → httpbin-waypoint → httpbin  (final: ingress hop added)
```

The final topology exercised is:

```
sleep → wpt-cel-egress → wpt-cel-ingress → httpbin-waypoint → httpbin
```

Each gateway hop in that chain validates the proof it received and mints a new one before forwarding, extending an `X-Forwarded-Workload-Identity` header by one entry per hop — so the request `httpbin` finally sees carries the full, ordered identity chain back to `sleep`, the original caller.

Everything in this file was verified live against a real cluster, including several corrections to earlier, wrong assumptions (a mistaken CA SAN, wrong `entWptEnforcement` target kind, a hardcoded backend header-size limit, and more) — where something surprising was found, it's called out inline as a "Correction from an earlier version of this file."

Requires a Solo Gloo Mesh license key (`GLOO_MESH_LICENSE_KEY`) and an Enterprise Agentgateway license key (`AGENTGATEWAY_LICENSE_KEY`).

---

# Env setup

## Create a KinD cluster

```bash
export KIND_CLUSTER=wpt-cel

kind create cluster --name ${KIND_CLUSTER}

kubectl config use-context kind-${KIND_CLUSTER}
```

KinD has no built-in `LoadBalancer` provider, so `Gateway` Services (like `wpt-cel-egress` below) would otherwise sit at `EXTERNAL-IP <pending>` forever. Run this in a dedicated terminal and leave it running for the life of the lab:
```bash
sudo cloud-provider-kind
```

```bash
kubectl get nodes
# Expected: wpt-cel-control-plane   Ready   control-plane
```

---

## Install Solo Istio Ambient Mesh

```bash
export ISTIO_VERSION=1.31.0
export ISTIO_IMAGE=${ISTIO_VERSION}-solo
export REPO=us-docker.pkg.dev/soloio-img/istio
export HELM_REPO=us-docker.pkg.dev/soloio-img/istio-helm
# export GLOO_MESH_LICENSE_KEY=<your-license-key>

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml

helm upgrade --install istio-base oci://${HELM_REPO}/base \
  --namespace istio-system --create-namespace --version ${ISTIO_IMAGE} --wait \
  -f - <<EOF
defaultRevision: ""
profile: ambient
EOF

helm upgrade --install istiod oci://${HELM_REPO}/istiod \
--namespace istio-system --version ${ISTIO_IMAGE} --wait \
-f - <<EOF
global:
  hub: ${REPO}
  proxy:
    clusterDomain: cluster.local
  tag: ${ISTIO_IMAGE}
  multiCluster:
    clusterName: Kubernetes
env:
  PILOT_ENABLE_IP_AUTOALLOCATE: "true"
  PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
pilot:
  cni:
    namespace: istio-system
    enabled: true
profile: ambient
license:
  value: ${GLOO_MESH_LICENSE_KEY}
EOF

helm upgrade --install istio-cni oci://${HELM_REPO}/cni \
  --namespace istio-system --version ${ISTIO_IMAGE} --wait \
  -f - <<EOF
ambient:
  dnsCapture: true
excludeNamespaces:
  - istio-system
  - kube-system
global:
  hub: ${REPO}
  tag: ${ISTIO_IMAGE}
profile: ambient
EOF
```

`global.multiCluster.clusterName: Kubernetes` is set explicitly on istiod rather than left to Istio's implicit default, so it's a visible value the Enterprise Agentgateway install below must match — not something to discover later from an authentication error. (Unlike the k3s/Colima variant of this lab, `global.platform: k3s` is omitted from the `istio-cni` values here — that setting is k3s-specific and doesn't apply to a plain KinD cluster.)

### ztunnel — `ENABLE_WORKLOAD_CLAIMS` is required

This is the setting that makes ztunnel embed a workload's SPIFFE identity claims into its own mTLS certificate as a WIT (an `OtherName` SAN — confirmed via a live cert on this exact stack as OID `1.3.6.1.4.1.65865.1.1`). Without it, no WIT ever exists on any connection, and everything downstream is moot.

```bash
helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
--namespace istio-system --version ${ISTIO_IMAGE} --wait \
-f - <<EOF
logLevel: info
logAsJson: true
configValidation: true
enabled: true
env:
  L7_ENABLED: "true"
  ENABLE_WORKLOAD_CLAIMS: "true"
  VALIDATE_SPIFFE_TRUST_DOMAIN_NAMES: "STRICT"
hub: ${REPO}
istioNamespace: istio-system
namespace: istio-system
profile: ambient
proxy:
  clusterDomain: cluster.local
tag: ${ISTIO_IMAGE}
terminationGracePeriodSeconds: 29
variant: distroless
EOF

kubectl get pods -n istio-system
```

Verify a workload actually gets a WIT (deploy `sleep` first — see below — then check):
```bash
istioctl ztunnel-config certificates -o json | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    if 'sleep' in str(c):
        print(c['identity'], '->', c['state'])
"
# Expected: spiffe://cluster.local/ns/sleep-ns/sa/sleep@... -> Available (WIT present)
```

---

### Create a Correct Intermediate CA with subjectAltName = URI:spiffe://cluster.local

**Correction from an earlier version of this file:** the SAN here was previously generated as `URI:spiffe://cluster.local/` — a trailing slash. Confirmed live by comparing against the stock `istio-ca-secret` root cert (which carries no SAN at all, only `O=cluster.local`, confirming a DNS SAN isn't needed here either): the trust domain URI is `spiffe://cluster.local` with **no trailing slash** (a trailing slash makes it a SPIFFE ID with path `/`, not the bare trust domain), and `VALIDATE_SPIFFE_TRUST_DOMAIN_NAMES: "STRICT"` on ztunnel makes that distinction load-bearing.

Generate a root CA and an intermediate with the **correct** trust domain SAN (`spiffe://cluster.local`):
```bash
mkdir -p /tmp/good-ca

# Root CA
openssl genrsa -out /tmp/good-ca/root-key.pem 4096
openssl req -new -x509 -key /tmp/good-ca/root-key.pem -out /tmp/good-ca/root-cert.pem -days 3650 \
  -subj "/O=Test Root CA"

# Intermediate CA key + CSR
openssl genrsa -out /tmp/good-ca/ca-key.pem 4096
openssl req -new -key /tmp/good-ca/ca-key.pem -out /tmp/good-ca/ca-csr.pem \
  -subj "/O=Test Intermediate CA"

# Sign the intermediate with the CORRECT trust domain SAN
cat > /tmp/good-ca/correct-san.cnf <<EOF
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectAltName = URI:spiffe://cluster.local
EOF

openssl x509 -req -in /tmp/good-ca/ca-csr.pem \
  -CA /tmp/good-ca/root-cert.pem -CAkey /tmp/good-ca/root-key.pem -CAcreateserial \
  -out /tmp/good-ca/ca-cert.pem -days 3650 \
  -extfile /tmp/good-ca/correct-san.cnf

cat /tmp/good-ca/ca-cert.pem /tmp/good-ca/root-cert.pem > /tmp/good-ca/cert-chain.pem
```

Apply it and rotate certs:
```bash
kubectl create secret generic cacerts -n istio-system \
  --from-file=/tmp/good-ca/ca-cert.pem \
  --from-file=/tmp/good-ca/ca-key.pem \
  --from-file=/tmp/good-ca/root-cert.pem \
  --from-file=/tmp/good-ca/cert-chain.pem

kubectl rollout restart deployment/istiod -n istio-system
kubectl rollout status deployment/istiod -n istio-system
kubectl rollout restart daemonset/ztunnel -n istio-system
kubectl rollout status daemonset/ztunnel -n istio-system
```

---

## Install Solo Enterprise Agentgateway v2026.9.0

```bash
export AGENTGATEWAY_VERSION=v2026.9.0

helm install enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --version ${AGENTGATEWAY_VERSION} \
  -n agentgateway-system --create-namespace

helm install enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --version ${AGENTGATEWAY_VERSION} \
  --set licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY} \
  --set istio.autoEnabled=true \
  --set istio.clusterId=Kubernetes \
  -n agentgateway-system
```

`istio.clusterId=Kubernetes` matches `global.multiCluster.clusterName: Kubernetes` from the istiod install above — every agentgateway pod authenticates to istiod's CA using this value as its claimed cluster identity, and istiod's `KubeJWTAuthenticator` rejects any client claiming a cluster it doesn't recognize.

```bash
kubectl get pods -n agentgateway-system
kubectl get gatewayclass | grep enterprise-agentgateway
# Expected: enterprise-agentgateway and enterprise-agentgateway-waypoint, both ACCEPTED=True
```

---

## Deploy `sleep` and `httpbin`

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: httpbin
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: Namespace
metadata:
  name: sleep-ns
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
  namespace: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: httpbin
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 8080
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: httpbin
  labels:
    app: httpbin
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
      - image: docker.io/mccutchen/go-httpbin:2.25.0
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 8080
        env:
        - name: SRV_MAX_HEADER_BYTES
          value: "131072"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sleep
  namespace: sleep-ns
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
  namespace: sleep-ns
  labels:
    app: sleep
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sleep
  template:
    metadata:
      labels:
        app: sleep
    spec:
      serviceAccountName: sleep
      containers:
      - name: sleep
        image: curlimages/curl
        command: ["/bin/sleep", "3650d"]
        imagePullPolicy: IfNotPresent
EOF

kubectl wait --for=condition=available deploy/httpbin -n httpbin --timeout=90s
kubectl wait --for=condition=available deploy/sleep -n sleep-ns --timeout=90s
```

---

## Set up `sleep → wpt-cel-egress → wpt-cel-ingress → httpbin`:

```bash
kubectl create namespace i-peg

kubectl apply -f - <<EOF
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
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wpt-cel-egress-to-echo
  namespace: httpbin
spec:
  parentRefs:
  - name: wpt-cel-egress
    namespace: i-peg
  rules:
  - backendRefs:
    - group: ""
      kind: Service
      name: httpbin
      port: 8000
EOF
```

Verify `sleep → wpt-cel-egress → wpt-cel-ingress → httpbin`:
```bash
kubectl exec -n sleep-ns deploy/sleep -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/headers'
```
```
HTTP/1.1 200 OK
Access-Control-Allow-Credentials: true
Access-Control-Allow-Origin: *
Content-Type: application/json; charset=utf-8
Date: Tue, 15 Sep 2026 00:30:44 GMT
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
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWN3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE5ESXpNRGt4TTFvWERUTTJNRGt4TVRJek1Ea3hNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFDZlhSSHNkamU1dFN5R3dJWE5rT1BqaDdYQnp5a3prR1F5TXJmVnVNYjBZS1lsYkRuVkd6R2hnVTJFQWZoa2JyMW1wWGxnZXN5aDErQTZBV2tQWWg0UFZGRkJSNUlNNUFIWUc5LzdpRHQvaGM3c3phak9ERUtWcCt2WktQMFRjYmhtb2VmMlBqWFJnR1VqUWlvd2k5QlY0aVpvaC9nRkFDNVZzaThGMS9kdmZ5bUhTamNxcEkydXFNelRoNWE2RElZcUU2dFpieGdvamRKTThGUjV2dEtpcGFJaDFMYjIvMmRsdmFDNm5FejNHUXc1Q0gzSlYyM1pwQmxKN25BTHBJUjExa2kzci84c0RhUG93TVc0V0s4V3lIeEIzQWIxYXBESXppQkxxR0NXQjdtc1NERXprMVhpczAzVmFKTlhhY1dRT0NUM1luaXdlZ0xxNU9VeTJrWGhSOFMvMEFPc0wzcGVIcU02VmR0L0RRNk00UGIzTk94WkFqc0tEUEdUbFdHWG5DY1o2TUtDc1Nxd3M3dW9iTHpCalU0RTAzUjJaSzNtaDFqK2hXaWZuR29FZ0lWa05KWjJCamJwZS94VEdpUWxjVW41ZUdTOWZsV1hncFIrVWNqSGpQZlJNaFF5OWhPQkUxVGlsMUQydTZ3eGxzMURkc3VYOXZmMUR6QkJTeWcrcDA4T2x2aXlBc2RUQkJidGl2Tmh2MGhpUlcxL2VjMkwvbFRpWEM4aStzSXZCR09QM0lkQWNXYzl1bUltT2t2R1dDS2RqN0duT3AyWWZQalZsdkd5bFlFMFJhY3g5UnNxMDNXaGY3Q0ZzSDA2U0tPWjI3OEpYSk9LalVFK0tXNGdaNXM5cHc4aGtyclJSZU0rS2EwWDBDVTd1NVFQNlhtRFBVTytQTmNvK3dJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZPRDJMVFBSdjA0bzF2cEJSNUxKNFhVMnRjaWtNQjhHQTFVZEl3UVlNQmFBRkN1QVJzQXVCTkc4YmtobmFtK1VRZ0RXSnVWTk1BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQUFXR21abTRkV3d1UFkzZ2NRWkdrUnlCNnZXdlBGaFNadkFsaGpVa0dUV1lDOVYwV0dVSGhrN2kwZXQ2aEpaWWlhelZ1aURZNmUyRlNoZ3JOdEdxSWd5TE5ZUVRCQ1AzTXZlYWtUUm5TVlVEZ0VRc2gyNUlQQllpQll2QzdLbmlKSk9KalBhUmxCSklMcVFMeU9OaDBEOEtQVHNwai9WOHFvL3doY2Z3RDVPb3BlalE1OWlyOENDdGtjVDZSRDBobGVINUIrOEdDbjdER3pNeFlPQUFTNGUvd2lGZUNxdEtNeStIUFlmQXQ3YWM4NEd4QTZqRW53WkNPeG15L1hmWEVsMU1UdU10SVVBNDAwMXhpSnZETVNMSFphMzNyci9LOHZZVkxZZjJOcTdiNHlJTjEzay9CUUt5cG1lUUJaRThlWnNqSWdjbEZBSmtZenRFY2ZVZ282LzE0dUpBeE93S1NFQm1mdUIzL2l0S29WNEJPOEV0bnBjT0VrSUZ1dVY0TG4vblF4SkZ2UTY1ajBwcjA1S0tiR2sxaVhBeGlxdWtscjhKRXgzMnVqQmVmaVVpMVEwMnlmN1BSN3A3VWdndGN0N0ZLUXM0V253UWNjaDFuZ3Azb2o4RkllRkEyck8vMUJ2WkNPaHFCbnYwNWlQSVJPZXVQOTJhM2dseTRjZGwvdkhaNGVyRWdWVGp3Y1h3bFZ4cUM1bTAzWW1qYzdoc3Q4WkR6TU5JVi9IMWsrSXgrZ0x5STg4WllHU3IraFVVeXJlQWxiZ2h3emsyRkVwdlFQNjAzUFh5STFyaVF1bFZkTnhOVmVDN0NOaitidTNiWXptRHdHRDUzQ3Izdmg4b1pkU0Z4a3FWdmpjL3J4Sy9zUlVFSjlWbmFlRU8rWUx5cHJuV1QvMjAzajd3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5Y3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TkRJek1Ea3hNMW9YRFRNMk1Ea3hNVEl6TURreE0xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUUNmWFJIc2RqZTV0U3lHd0lYTmtPUGpoN1hCenlremtHUXlNcmZWdU1iMFlLWWxiRG5WR3pHaGdVMkVBZmhrYnIxbXBYbGdlc3loMStBNkFXa1BZaDRQVkZGQlI1SU01QUhZRzkvN2lEdC9oYzdzemFqT0RFS1ZwK3ZaS1AwVGNiaG1vZWYyUGpYUmdHVWpRaW93aTlCVjRpWm9oL2dGQUM1VnNpOEYxL2R2ZnltSFNqY3FwSTJ1cU16VGg1YTZESVlxRTZ0WmJ4Z29qZEpNOEZSNXZ0S2lwYUloMUxiMi8yZGx2YUM2bkV6M0dRdzVDSDNKVjIzWnBCbEo3bkFMcElSMTFraTNyLzhzRGFQb3dNVzRXSzhXeUh4QjNBYjFhcERJemlCTHFHQ1dCN21zU0RFemsxWGlzMDNWYUpOWGFjV1FPQ1QzWW5pd2VnTHE1T1V5MmtYaFI4Uy8wQU9zTDNwZUhxTTZWZHQvRFE2TTRQYjNOT3haQWpzS0RQR1RsV0dYbkNjWjZNS0NzU3F3czd1b2JMekJqVTRFMDNSMlpLM21oMWoraFdpZm5Hb0VnSVZrTkpaMkJqYnBlL3hUR2lRbGNVbjVlR1M5ZmxXWGdwUitVY2pIalBmUk1oUXk5aE9CRTFUaWwxRDJ1Nnd4bHMxRGRzdVg5dmYxRHpCQlN5ZytwMDhPbHZpeUFzZFRCQmJ0aXZOaHYwaGlSVzEvZWMyTC9sVGlYQzhpK3NJdkJHT1AzSWRBY1djOXVtSW1Pa3ZHV0NLZGo3R25PcDJZZlBqVmx2R3lsWUUwUmFjeDlSc3EwM1doZjdDRnNIMDZTS09aMjc4SlhKT0tqVUUrS1c0Z1o1czlwdzhoa3JyUlJlTStLYTBYMENVN3U1UVA2WG1EUFVPK1BOY28rd0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRk9EMkxUUFJ2MDRvMXZwQlI1TEo0WFUydGNpa01COEdBMVVkSXdRWU1CYUFGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFBQVdHbVptNGRXd3VQWTNnY1FaR2tSeUI2dld2UEZoU1p2QWxoalVrR1RXWUM5VjBXR1VIaGs3aTBldDZoSlpZaWF6VnVpRFk2ZTJGU2hnck50R3FJZ3lMTllRVEJDUDNNdmVha1RSblNWVURnRVFzaDI1SVBCWWlCWXZDN0tuaUpKT0pqUGFSbEJKSUxxUUx5T05oMEQ4S1BUc3BqL1Y4cW8vd2hjZndENU9vcGVqUTU5aXI4Q0N0a2NUNlJEMGhsZUg1Qis4R0NuN0RHek14WU9BQVM0ZS93aUZlQ3F0S015K0hQWWZBdDdhYzg0R3hBNmpFbndaQ094bXkvWGZYRWwxTVR1TXRJVUE0MDAxeGlKdkRNU0xIWmEzM3JyL0s4dllWTFlmMk5xN2I0eUlOMTNrL0JRS3lwbWVRQlpFOGVac2pJZ2NsRkFKa1l6dEVjZlVnbzYvMTR1SkF4T3dLU0VCbWZ1QjMvaXRLb1Y0Qk84RXRucGNPRWtJRnV1VjRMbi9uUXhKRnZRNjVqMHByMDVLS2JHazFpWEF4aXF1a2xyOEpFeDMydWpCZWZpVWkxUTAyeWY3UFI3cDdVZ2d0Y3Q3RktRczRXbndRY2NoMW5ncDNvajhGSWVGQTJyTy8xQnZaQ09ocUJudjA1aVBJUk9ldVA5MmEzZ2x5NGNkbC92SFo0ZXJFZ1ZUandjWHdsVnhxQzVtMDNZbWpjN2hzdDhaRHpNTklWL0gxaytJeCtnTHlJODhaWUdTcitoVVV5cmVBbGJnaHd6azJGRXB2UVA2MDNQWHlJMXJpUXVsVmROeE5WZUM3Q05qK2J1M2JZem1Ed0dENTNDcjN2aDhvWmRTRnhrcVZ2amMvcnhLL3NSVUVKOVZuYWVFTytZTHlwcm5XVC8yMDNqN3c9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVRW1qNW1NV3RmcmM2UTAxNm1MNWtUWXpiSHRRd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOREl6TURnMU9Wb1hEVE0yTURreE1USXpNRGcxT1Zvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUE2Z0tBeFltbk1STU1XTGJMSVVrQXN1UUFaOWNhUi9EamQwdVVMcUxXemNtK0F5blpaeCtmT0k0Mk4xR0ZzRWJrZSs0enRsZWdjK1pIVWxmWjRWQ2JkcndXeFMzb3JPSlduaVlDZjFUWHFlNXdCKzN4MUp0RHQwNm92OUN1aGI0Y3dlKzBtSkpsa0tlUElnMFZOQkVBNjdyQVZnN3Z2UXBrOGp2WE4rK3JiRkhyMUJjbjZuZDlPR1h0VVlIdlNGbmtVZGtTVDFJN1NRbUQvU0ZjZ2RuZUlqVXF1UDFhNTdrS1lrWDh4blBnQkJ1ajF3eWdrMFl1YkF3RGtRVXhwWEZoTnB6em1jdDRTZER3SkFrYjNkK29ucFRLMk8vOVA2VXhnWlEyOHpSRExER3BubDNTWVhQUCtQZGFJcG1RSCtGbEZrQWgzaERpeGlGMit3RmtFM08zUjJBd3FXY3ZYVXdNeUFtUC9BbzcrQ2JKTS9uT1FuQ0kxZ2FLRDBYUnBxa1F1YmptKyt0M2tVTzdGd282eXcyZEY0YXZ4YlFlNVJya2lVRWxDWmlEamcxc3MveTJUMTlJbGIvR0NienB2aWVjQkVRTGZCazhWV2VjdE41WGRpNWNudFU1WjY3ZXl5Mk5VWTJXbkFteTZaZHZFZ3JzWUFac0R5UXZ1cGRhalZLckZXZ25YYWNHcGdSNWR3REFwcExtY2Z3QktjY1IyVjg1V0lzVk82WjdBWGd6RFYzYWI1S3pwY25sV0U4bjltd2xIbXVTMWw2c21hTzVNdS8xeG1SSHpibkhMc0ZvWHpNN0Q2cXd0WHY3cW5PdDErQktiL2t5OTNZZEkrVGl4QU5sc0k5bENwZHp3aEwrQ2k4dUxLT0pxYkIzdzY3UTRnd3JrTUZsUDhxd2JRTUNBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUI4R0ExVWRJd1FZTUJhQUZDdUFSc0F1Qk5HOGJraG5hbStVUWdEV0p1Vk5NQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBTndjVU1rcUZkUEkveGJUUW1VMzVvWHRJVXRGRlRncThnNHFwK3AwSllVR1c2S0RpbTFWbCszQ0VENjg3VGZKNHZkUlRIbFp5ZVN1cnBTVEo0OUFuTzBCU0ZsRzhxeTV4bDdLaklZb3gvVmh6ZkI2NkNNa1gwaXZXbmdIMjlMM05TR2FQL0doRHoxbnlvSDMyVWxEWmJYa2lMcElqZTBBV0U3WXpwS2VtSnRLblk1SjRrMmMzaVhSSDZsUVFUR0NNdXM4dHo0WjFUazJZYitzUTBzMDJveE5CaGNOc2hTazl6OWh4OSt4MTIxUFkvLzYxaEJzbEptRHlISEpDUjlQcEFTKzF0L3Z4bjM3bnZ3MG9FbFN4NlZCR1BsYkozcVRFNXZ0ejRpNmZ2ekV2cGNxQmZWYVAvNTRkTU9ydVh3VGFEZUhOK1FFdkxlNWxUeFJjWmZwckQwRmZmYjIwMEUvclRCZnhtNm5hWDNvenBRV2ZnRXVGbjg2WHVtSU1BZmpMcVorSG1TQ21UdFpiYkQ5NWY2MnBLWE8vYitoSXZXTmwxTGVFN1N0TU05ek1CMjE3WHZGUTFrbC9BNTFzR0xvYUxFRkRNeW5qU0YzOGJJNjZpZTdZZkxMeEpYQWFQYUFQSGMza05ocExJVFR2Y3pITmRtUzdWSER4QVpKaGVMRDZrNVRuWnNleDJTZnJqUTlpRDVrR09CN0ZKNExSTit5cm04VjY3eTYrelVkeDFUeFVPQktjV0VqZG5lK2R4UlJ2b3E1SCtOeHFrMHVqb2txS1d6UFpvV0RjL1hzNTZnaTZUMGF0K3ZXcGlQTmpRTG1hUDRFMXNCZE5JS1A3QnB4amhOcHhLOHZ2L2FnK3Bna2V5dkRwaGoyUVdUUDJaeitVYWdKTlJVQ0FGRk0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVUVtajVtTVd0ZnJjNlEwMTZtTDVrVFl6Ykh0UXdEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TkRJek1EZzFPVm9YRFRNMk1Ea3hNVEl6TURnMU9Wb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBNmdLQXhZbW5NUk1NV0xiTElVa0FzdVFBWjljYVIvRGpkMHVVTHFMV3pjbStBeW5aWngrZk9JNDJOMUdGc0Via2UrNHp0bGVnYytaSFVsZlo0VkNiZHJ3V3hTM29yT0pXbmlZQ2YxVFhxZTV3QiszeDFKdER0MDZvdjlDdWhiNGN3ZSswbUpKbGtLZVBJZzBWTkJFQTY3ckFWZzd2dlFwazhqdlhOKytyYkZIcjFCY242bmQ5T0dYdFVZSHZTRm5rVWRrU1QxSTdTUW1EL1NGY2dkbmVJalVxdVAxYTU3a0tZa1g4eG5QZ0JCdWoxd3lnazBZdWJBd0RrUVV4cFhGaE5wenptY3Q0U2REd0pBa2IzZCtvbnBUSzJPLzlQNlV4Z1pRMjh6UkRMREdwbmwzU1lYUFArUGRhSXBtUUgrRmxGa0FoM2hEaXhpRjIrd0ZrRTNPM1IyQXdxV2N2WFV3TXlBbVAvQW83K0NiSk0vbk9RbkNJMWdhS0QwWFJwcWtRdWJqbSsrdDNrVU83RndvNnl3MmRGNGF2eGJRZTVScmtpVUVsQ1ppRGpnMXNzL3kyVDE5SWxiL0dDYnpwdmllY0JFUUxmQms4VldlY3RONVhkaTVjbnRVNVo2N2V5eTJOVVkyV25BbXk2WmR2RWdyc1lBWnNEeVF2dXBkYWpWS3JGV2duWGFjR3BnUjVkd0RBcHBMbWNmd0JLY2NSMlY4NVdJc1ZPNlo3QVhnekRWM2FiNUt6cGNubFdFOG45bXdsSG11UzFsNnNtYU81TXUvMXhtUkh6Ym5ITHNGb1h6TTdENnF3dFh2N3FuT3QxK0JLYi9reTkzWWRJK1RpeEFObHNJOWxDcGR6d2hMK0NpOHVMS09KcWJCM3c2N1E0Z3dya01GbFA4cXdiUU1DQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRkN1QVJzQXVCTkc4YmtobmFtK1VRZ0RXSnVWTk1COEdBMVVkSXdRWU1CYUFGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQU53Y1VNa3FGZFBJL3hiVFFtVTM1b1h0SVV0RkZUZ3E4ZzRxcCtwMEpZVUdXNktEaW0xVmwrM0NFRDY4N1RmSjR2ZFJUSGxaeWVTdXJwU1RKNDlBbk8wQlNGbEc4cXk1eGw3S2pJWW94L1ZoemZCNjZDTWtYMGl2V25nSDI5TDNOU0dhUC9HaER6MW55b0gzMlVsRFpiWGtpTHBJamUwQVdFN1l6cEtlbUp0S25ZNUo0azJjM2lYUkg2bFFRVEdDTXVzOHR6NFoxVGsyWWIrc1EwczAyb3hOQmhjTnNoU2s5ejloeDkreDEyMVBZLy82MWhCc2xKbUR5SEhKQ1I5UHBBUysxdC92eG4zN252dzBvRWxTeDZWQkdQbGJKM3FURTV2dHo0aTZmdnpFdnBjcUJmVmFQLzU0ZE1PcnVYd1RhRGVITitRRXZMZTVsVHhSY1pmcHJEMEZmZmIyMDBFL3JUQmZ4bTZuYVgzb3pwUVdmZ0V1Rm44Nlh1bUlNQWZqTHFaK0htU0NtVHRaYmJEOTVmNjJwS1hPL2IraEl2V05sMUxlRTdTdE1NOXpNQjIxN1h2RlExa2wvQTUxc0dMb2FMRUZETXlualNGMzhiSTY2aWU3WWZMTHhKWEFhUGFBUEhjM2tOaHBMSVRUdmN6SE5kbVM3VkhEeEFaSmhlTEQ2azVUblpzZXgyU2ZyalE5aUQ1a0dPQjdGSjRMUk4reXJtOFY2N3k2K3pVZHgxVHhVT0JLY1dFamRuZStkeFJSdm9xNUgrTnhxazB1am9rcUtXelBab1dEYy9YczU2Z2k2VDBhdCt2V3BpUE5qUUxtYVA0RTFzQmROSUtQN0JweGpoTnB4Szh2di9hZytwZ2tleXZEcGhqMlFXVFAyWnorVWFnSk5SVUNBRkZNIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2ktcGVnL3NhL3dwdC1jZWwtZWdyZXNzIiwiZXhwIjoxNzg5NTE4NjAwLCJpYXQiOjE3ODk0MzIyMDAsImlzdGlvLmlvIjp7InRydXN0X2RvbWFpbiI6ImNsdXN0ZXIubG9jYWwiLCJ3b3JrbG9hZCI6eyJuYW1lIjoid3B0LWNlbC1lZ3Jlc3MiLCJuYW1lc3BhY2UiOiJpLXBlZyIsInBvZCI6IndwdC1jZWwtZWdyZXNzLTU4OWQ0NDg1ODQtZ3NsZmwifX0sImp0aSI6IjhiYjNhMzVkODEyYzI1ZjgzZjc5MDRiMDZiYTE1YTZhIiwiY25mIjp7Imp3ayI6eyJrdHkiOiJFQyIsImNydiI6IlAtMjU2IiwieCI6InlzdXJYcWZKZDE5RzZmenlrSDFRVjVPcFphYzdQR2ZEMm52STNfWkFJemsiLCJ5IjoiUVNFSFgxWUY4Y2tPcXdHTUNmUFNMekdsbTk3ZWcwdFVONGpkSWFPUXBMOCJ9fX0.A2VVqzGCCVxwry8qUyBGQd2CTiST4dWqCoVDk9AP7j5qGhPwv_EQhiOPE7YSKsxduEY9U3W9HRyLvxWPC1-n8rbqbifOhy4eq61HOVLZkvAmO3XcHCQMvRP5TYHXb5VNuH481VAaq9iIAGCb-75G1MzH-3egPeIYSKbDEdDUygcJYpDbmkfVOu7qGTo2HERSQRc2O6jV6VfjVOu-jciyct8qstkEAgxdM0usnX21VHEEEDYyQdeakSXWyuWxzNRlTFyzog-IW9YgGyTBU4IJI--or87lXL-T98LZFgJxbbkoQcikuk71sloXOCRgBMaW1Mbvqr4HMYTlVzAKT-OpxgHSWCQ4VX9IePvjvfeJbx8z7C55u_m1b3y4I0buMvxt5LY2whGeyOE_EbaUeUMzkZwVzQOaEpQkbtw9HKnxDusVAD85_VRtw7uqoo6bLLSaYYgtoNhOoSc7DBQu5gOmnSPZjmWtTZFOiSHYFpuli3rSrAoqFFRJgPnm0Z4qgtvSkMoj_fun0g8Wr5Lwe_XpBOtfeRPZP_cB--YW5i_FWFucohfKVgaMWisTeiAFVAqz0IUYrzYUsoXeKBWTH17AxyrygvSaPx_uD5KJlR7RFYy9yPpiJke9mpqkLothg_Nvm7fsyXKomadxZE9sfUqmdk2nMZB0D95v591eNZLesgg"
    ],
    "Workload-Proof-Token": [
      "eyJ0eXAiOiJhcHBsaWNhdGlvbi93cHQrand0IiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL2ktcGVnL3NhL3dwdC1jZWwtZWdyZXNzIiwiYXVkIjoiaHR0cHM6Ly9odHRwYmluLmh0dHBiaW4uc3ZjLmNsdXN0ZXIubG9jYWwiLCJleHAiOjE3ODk0MzIzMDQsImlhdCI6MTc4OTQzMjI0NCwianRpIjoiZjU1NzUxYWUtN2MyYy00OTcwLTk3NmUtMDhmMGVkMmI0NGZkIiwid3RoIjoiZXM2aWlCWmNBa2FtS2ttemc4R1NoNmtIN0R6V1Q1RHZjU3B2TUJyUFE5dyIsIm90aCI6eyJ4LWZvcndhcmRlZC13b3JrbG9hZC1pZGVudGl0eSI6InZqNlBOTUxnOGhCQW1RN3RuM3dNUEMwRWdvcWhBTW5xR2UzcVZBUk9kRTgiLCJ4LW9yaWdpbmFsLXdvcmtsb2FkLWlkZW50aXR5LXRva2VuIjoiTnNtRjlxUHMxVng5dWg1VXZjV2J2al9taWRoTno1WWEwY3ozMkdYY21ROCJ9fQ.Aq1BI3wgZDR1FHqLEfp2YB9ZHD3hhaKMB0r397Do6KNnPnvcDDEHdhwgY6BUlfRtpiUFje_mBXaM1ECSt0lIIw"
    ],
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/sleep-ns/sa/sleep, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress"
    ],
    "X-Original-Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWN3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE5ESXpNRGt4TTFvWERUTTJNRGt4TVRJek1Ea3hNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFDZlhSSHNkamU1dFN5R3dJWE5rT1BqaDdYQnp5a3prR1F5TXJmVnVNYjBZS1lsYkRuVkd6R2hnVTJFQWZoa2JyMW1wWGxnZXN5aDErQTZBV2tQWWg0UFZGRkJSNUlNNUFIWUc5LzdpRHQvaGM3c3phak9ERUtWcCt2WktQMFRjYmhtb2VmMlBqWFJnR1VqUWlvd2k5QlY0aVpvaC9nRkFDNVZzaThGMS9kdmZ5bUhTamNxcEkydXFNelRoNWE2RElZcUU2dFpieGdvamRKTThGUjV2dEtpcGFJaDFMYjIvMmRsdmFDNm5FejNHUXc1Q0gzSlYyM1pwQmxKN25BTHBJUjExa2kzci84c0RhUG93TVc0V0s4V3lIeEIzQWIxYXBESXppQkxxR0NXQjdtc1NERXprMVhpczAzVmFKTlhhY1dRT0NUM1luaXdlZ0xxNU9VeTJrWGhSOFMvMEFPc0wzcGVIcU02VmR0L0RRNk00UGIzTk94WkFqc0tEUEdUbFdHWG5DY1o2TUtDc1Nxd3M3dW9iTHpCalU0RTAzUjJaSzNtaDFqK2hXaWZuR29FZ0lWa05KWjJCamJwZS94VEdpUWxjVW41ZUdTOWZsV1hncFIrVWNqSGpQZlJNaFF5OWhPQkUxVGlsMUQydTZ3eGxzMURkc3VYOXZmMUR6QkJTeWcrcDA4T2x2aXlBc2RUQkJidGl2Tmh2MGhpUlcxL2VjMkwvbFRpWEM4aStzSXZCR09QM0lkQWNXYzl1bUltT2t2R1dDS2RqN0duT3AyWWZQalZsdkd5bFlFMFJhY3g5UnNxMDNXaGY3Q0ZzSDA2U0tPWjI3OEpYSk9LalVFK0tXNGdaNXM5cHc4aGtyclJSZU0rS2EwWDBDVTd1NVFQNlhtRFBVTytQTmNvK3dJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZPRDJMVFBSdjA0bzF2cEJSNUxKNFhVMnRjaWtNQjhHQTFVZEl3UVlNQmFBRkN1QVJzQXVCTkc4YmtobmFtK1VRZ0RXSnVWTk1BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQUFXR21abTRkV3d1UFkzZ2NRWkdrUnlCNnZXdlBGaFNadkFsaGpVa0dUV1lDOVYwV0dVSGhrN2kwZXQ2aEpaWWlhelZ1aURZNmUyRlNoZ3JOdEdxSWd5TE5ZUVRCQ1AzTXZlYWtUUm5TVlVEZ0VRc2gyNUlQQllpQll2QzdLbmlKSk9KalBhUmxCSklMcVFMeU9OaDBEOEtQVHNwai9WOHFvL3doY2Z3RDVPb3BlalE1OWlyOENDdGtjVDZSRDBobGVINUIrOEdDbjdER3pNeFlPQUFTNGUvd2lGZUNxdEtNeStIUFlmQXQ3YWM4NEd4QTZqRW53WkNPeG15L1hmWEVsMU1UdU10SVVBNDAwMXhpSnZETVNMSFphMzNyci9LOHZZVkxZZjJOcTdiNHlJTjEzay9CUUt5cG1lUUJaRThlWnNqSWdjbEZBSmtZenRFY2ZVZ282LzE0dUpBeE93S1NFQm1mdUIzL2l0S29WNEJPOEV0bnBjT0VrSUZ1dVY0TG4vblF4SkZ2UTY1ajBwcjA1S0tiR2sxaVhBeGlxdWtscjhKRXgzMnVqQmVmaVVpMVEwMnlmN1BSN3A3VWdndGN0N0ZLUXM0V253UWNjaDFuZ3Azb2o4RkllRkEyck8vMUJ2WkNPaHFCbnYwNWlQSVJPZXVQOTJhM2dseTRjZGwvdkhaNGVyRWdWVGp3Y1h3bFZ4cUM1bTAzWW1qYzdoc3Q4WkR6TU5JVi9IMWsrSXgrZ0x5STg4WllHU3IraFVVeXJlQWxiZ2h3emsyRkVwdlFQNjAzUFh5STFyaVF1bFZkTnhOVmVDN0NOaitidTNiWXptRHdHRDUzQ3Izdmg4b1pkU0Z4a3FWdmpjL3J4Sy9zUlVFSjlWbmFlRU8rWUx5cHJuV1QvMjAzajd3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5Y3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TkRJek1Ea3hNMW9YRFRNMk1Ea3hNVEl6TURreE0xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUUNmWFJIc2RqZTV0U3lHd0lYTmtPUGpoN1hCenlremtHUXlNcmZWdU1iMFlLWWxiRG5WR3pHaGdVMkVBZmhrYnIxbXBYbGdlc3loMStBNkFXa1BZaDRQVkZGQlI1SU01QUhZRzkvN2lEdC9oYzdzemFqT0RFS1ZwK3ZaS1AwVGNiaG1vZWYyUGpYUmdHVWpRaW93aTlCVjRpWm9oL2dGQUM1VnNpOEYxL2R2ZnltSFNqY3FwSTJ1cU16VGg1YTZESVlxRTZ0WmJ4Z29qZEpNOEZSNXZ0S2lwYUloMUxiMi8yZGx2YUM2bkV6M0dRdzVDSDNKVjIzWnBCbEo3bkFMcElSMTFraTNyLzhzRGFQb3dNVzRXSzhXeUh4QjNBYjFhcERJemlCTHFHQ1dCN21zU0RFemsxWGlzMDNWYUpOWGFjV1FPQ1QzWW5pd2VnTHE1T1V5MmtYaFI4Uy8wQU9zTDNwZUhxTTZWZHQvRFE2TTRQYjNOT3haQWpzS0RQR1RsV0dYbkNjWjZNS0NzU3F3czd1b2JMekJqVTRFMDNSMlpLM21oMWoraFdpZm5Hb0VnSVZrTkpaMkJqYnBlL3hUR2lRbGNVbjVlR1M5ZmxXWGdwUitVY2pIalBmUk1oUXk5aE9CRTFUaWwxRDJ1Nnd4bHMxRGRzdVg5dmYxRHpCQlN5ZytwMDhPbHZpeUFzZFRCQmJ0aXZOaHYwaGlSVzEvZWMyTC9sVGlYQzhpK3NJdkJHT1AzSWRBY1djOXVtSW1Pa3ZHV0NLZGo3R25PcDJZZlBqVmx2R3lsWUUwUmFjeDlSc3EwM1doZjdDRnNIMDZTS09aMjc4SlhKT0tqVUUrS1c0Z1o1czlwdzhoa3JyUlJlTStLYTBYMENVN3U1UVA2WG1EUFVPK1BOY28rd0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRk9EMkxUUFJ2MDRvMXZwQlI1TEo0WFUydGNpa01COEdBMVVkSXdRWU1CYUFGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFBQVdHbVptNGRXd3VQWTNnY1FaR2tSeUI2dld2UEZoU1p2QWxoalVrR1RXWUM5VjBXR1VIaGs3aTBldDZoSlpZaWF6VnVpRFk2ZTJGU2hnck50R3FJZ3lMTllRVEJDUDNNdmVha1RSblNWVURnRVFzaDI1SVBCWWlCWXZDN0tuaUpKT0pqUGFSbEJKSUxxUUx5T05oMEQ4S1BUc3BqL1Y4cW8vd2hjZndENU9vcGVqUTU5aXI4Q0N0a2NUNlJEMGhsZUg1Qis4R0NuN0RHek14WU9BQVM0ZS93aUZlQ3F0S015K0hQWWZBdDdhYzg0R3hBNmpFbndaQ094bXkvWGZYRWwxTVR1TXRJVUE0MDAxeGlKdkRNU0xIWmEzM3JyL0s4dllWTFlmMk5xN2I0eUlOMTNrL0JRS3lwbWVRQlpFOGVac2pJZ2NsRkFKa1l6dEVjZlVnbzYvMTR1SkF4T3dLU0VCbWZ1QjMvaXRLb1Y0Qk84RXRucGNPRWtJRnV1VjRMbi9uUXhKRnZRNjVqMHByMDVLS2JHazFpWEF4aXF1a2xyOEpFeDMydWpCZWZpVWkxUTAyeWY3UFI3cDdVZ2d0Y3Q3RktRczRXbndRY2NoMW5ncDNvajhGSWVGQTJyTy8xQnZaQ09ocUJudjA1aVBJUk9ldVA5MmEzZ2x5NGNkbC92SFo0ZXJFZ1ZUandjWHdsVnhxQzVtMDNZbWpjN2hzdDhaRHpNTklWL0gxaytJeCtnTHlJODhaWUdTcitoVVV5cmVBbGJnaHd6azJGRXB2UVA2MDNQWHlJMXJpUXVsVmROeE5WZUM3Q05qK2J1M2JZem1Ed0dENTNDcjN2aDhvWmRTRnhrcVZ2amMvcnhLL3NSVUVKOVZuYWVFTytZTHlwcm5XVC8yMDNqN3c9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVRW1qNW1NV3RmcmM2UTAxNm1MNWtUWXpiSHRRd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOREl6TURnMU9Wb1hEVE0yTURreE1USXpNRGcxT1Zvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUE2Z0tBeFltbk1STU1XTGJMSVVrQXN1UUFaOWNhUi9EamQwdVVMcUxXemNtK0F5blpaeCtmT0k0Mk4xR0ZzRWJrZSs0enRsZWdjK1pIVWxmWjRWQ2JkcndXeFMzb3JPSlduaVlDZjFUWHFlNXdCKzN4MUp0RHQwNm92OUN1aGI0Y3dlKzBtSkpsa0tlUElnMFZOQkVBNjdyQVZnN3Z2UXBrOGp2WE4rK3JiRkhyMUJjbjZuZDlPR1h0VVlIdlNGbmtVZGtTVDFJN1NRbUQvU0ZjZ2RuZUlqVXF1UDFhNTdrS1lrWDh4blBnQkJ1ajF3eWdrMFl1YkF3RGtRVXhwWEZoTnB6em1jdDRTZER3SkFrYjNkK29ucFRLMk8vOVA2VXhnWlEyOHpSRExER3BubDNTWVhQUCtQZGFJcG1RSCtGbEZrQWgzaERpeGlGMit3RmtFM08zUjJBd3FXY3ZYVXdNeUFtUC9BbzcrQ2JKTS9uT1FuQ0kxZ2FLRDBYUnBxa1F1YmptKyt0M2tVTzdGd282eXcyZEY0YXZ4YlFlNVJya2lVRWxDWmlEamcxc3MveTJUMTlJbGIvR0NienB2aWVjQkVRTGZCazhWV2VjdE41WGRpNWNudFU1WjY3ZXl5Mk5VWTJXbkFteTZaZHZFZ3JzWUFac0R5UXZ1cGRhalZLckZXZ25YYWNHcGdSNWR3REFwcExtY2Z3QktjY1IyVjg1V0lzVk82WjdBWGd6RFYzYWI1S3pwY25sV0U4bjltd2xIbXVTMWw2c21hTzVNdS8xeG1SSHpibkhMc0ZvWHpNN0Q2cXd0WHY3cW5PdDErQktiL2t5OTNZZEkrVGl4QU5sc0k5bENwZHp3aEwrQ2k4dUxLT0pxYkIzdzY3UTRnd3JrTUZsUDhxd2JRTUNBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUI4R0ExVWRJd1FZTUJhQUZDdUFSc0F1Qk5HOGJraG5hbStVUWdEV0p1Vk5NQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBTndjVU1rcUZkUEkveGJUUW1VMzVvWHRJVXRGRlRncThnNHFwK3AwSllVR1c2S0RpbTFWbCszQ0VENjg3VGZKNHZkUlRIbFp5ZVN1cnBTVEo0OUFuTzBCU0ZsRzhxeTV4bDdLaklZb3gvVmh6ZkI2NkNNa1gwaXZXbmdIMjlMM05TR2FQL0doRHoxbnlvSDMyVWxEWmJYa2lMcElqZTBBV0U3WXpwS2VtSnRLblk1SjRrMmMzaVhSSDZsUVFUR0NNdXM4dHo0WjFUazJZYitzUTBzMDJveE5CaGNOc2hTazl6OWh4OSt4MTIxUFkvLzYxaEJzbEptRHlISEpDUjlQcEFTKzF0L3Z4bjM3bnZ3MG9FbFN4NlZCR1BsYkozcVRFNXZ0ejRpNmZ2ekV2cGNxQmZWYVAvNTRkTU9ydVh3VGFEZUhOK1FFdkxlNWxUeFJjWmZwckQwRmZmYjIwMEUvclRCZnhtNm5hWDNvenBRV2ZnRXVGbjg2WHVtSU1BZmpMcVorSG1TQ21UdFpiYkQ5NWY2MnBLWE8vYitoSXZXTmwxTGVFN1N0TU05ek1CMjE3WHZGUTFrbC9BNTFzR0xvYUxFRkRNeW5qU0YzOGJJNjZpZTdZZkxMeEpYQWFQYUFQSGMza05ocExJVFR2Y3pITmRtUzdWSER4QVpKaGVMRDZrNVRuWnNleDJTZnJqUTlpRDVrR09CN0ZKNExSTit5cm04VjY3eTYrelVkeDFUeFVPQktjV0VqZG5lK2R4UlJ2b3E1SCtOeHFrMHVqb2txS1d6UFpvV0RjL1hzNTZnaTZUMGF0K3ZXcGlQTmpRTG1hUDRFMXNCZE5JS1A3QnB4amhOcHhLOHZ2L2FnK3Bna2V5dkRwaGoyUVdUUDJaeitVYWdKTlJVQ0FGRk0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVUVtajVtTVd0ZnJjNlEwMTZtTDVrVFl6Ykh0UXdEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TkRJek1EZzFPVm9YRFRNMk1Ea3hNVEl6TURnMU9Wb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBNmdLQXhZbW5NUk1NV0xiTElVa0FzdVFBWjljYVIvRGpkMHVVTHFMV3pjbStBeW5aWngrZk9JNDJOMUdGc0Via2UrNHp0bGVnYytaSFVsZlo0VkNiZHJ3V3hTM29yT0pXbmlZQ2YxVFhxZTV3QiszeDFKdER0MDZvdjlDdWhiNGN3ZSswbUpKbGtLZVBJZzBWTkJFQTY3ckFWZzd2dlFwazhqdlhOKytyYkZIcjFCY242bmQ5T0dYdFVZSHZTRm5rVWRrU1QxSTdTUW1EL1NGY2dkbmVJalVxdVAxYTU3a0tZa1g4eG5QZ0JCdWoxd3lnazBZdWJBd0RrUVV4cFhGaE5wenptY3Q0U2REd0pBa2IzZCtvbnBUSzJPLzlQNlV4Z1pRMjh6UkRMREdwbmwzU1lYUFArUGRhSXBtUUgrRmxGa0FoM2hEaXhpRjIrd0ZrRTNPM1IyQXdxV2N2WFV3TXlBbVAvQW83K0NiSk0vbk9RbkNJMWdhS0QwWFJwcWtRdWJqbSsrdDNrVU83RndvNnl3MmRGNGF2eGJRZTVScmtpVUVsQ1ppRGpnMXNzL3kyVDE5SWxiL0dDYnpwdmllY0JFUUxmQms4VldlY3RONVhkaTVjbnRVNVo2N2V5eTJOVVkyV25BbXk2WmR2RWdyc1lBWnNEeVF2dXBkYWpWS3JGV2duWGFjR3BnUjVkd0RBcHBMbWNmd0JLY2NSMlY4NVdJc1ZPNlo3QVhnekRWM2FiNUt6cGNubFdFOG45bXdsSG11UzFsNnNtYU81TXUvMXhtUkh6Ym5ITHNGb1h6TTdENnF3dFh2N3FuT3QxK0JLYi9reTkzWWRJK1RpeEFObHNJOWxDcGR6d2hMK0NpOHVMS09KcWJCM3c2N1E0Z3dya01GbFA4cXdiUU1DQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRkN1QVJzQXVCTkc4YmtobmFtK1VRZ0RXSnVWTk1COEdBMVVkSXdRWU1CYUFGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQU53Y1VNa3FGZFBJL3hiVFFtVTM1b1h0SVV0RkZUZ3E4ZzRxcCtwMEpZVUdXNktEaW0xVmwrM0NFRDY4N1RmSjR2ZFJUSGxaeWVTdXJwU1RKNDlBbk8wQlNGbEc4cXk1eGw3S2pJWW94L1ZoemZCNjZDTWtYMGl2V25nSDI5TDNOU0dhUC9HaER6MW55b0gzMlVsRFpiWGtpTHBJamUwQVdFN1l6cEtlbUp0S25ZNUo0azJjM2lYUkg2bFFRVEdDTXVzOHR6NFoxVGsyWWIrc1EwczAyb3hOQmhjTnNoU2s5ejloeDkreDEyMVBZLy82MWhCc2xKbUR5SEhKQ1I5UHBBUysxdC92eG4zN252dzBvRWxTeDZWQkdQbGJKM3FURTV2dHo0aTZmdnpFdnBjcUJmVmFQLzU0ZE1PcnVYd1RhRGVITitRRXZMZTVsVHhSY1pmcHJEMEZmZmIyMDBFL3JUQmZ4bTZuYVgzb3pwUVdmZ0V1Rm44Nlh1bUlNQWZqTHFaK0htU0NtVHRaYmJEOTVmNjJwS1hPL2IraEl2V05sMUxlRTdTdE1NOXpNQjIxN1h2RlExa2wvQTUxc0dMb2FMRUZETXlualNGMzhiSTY2aWU3WWZMTHhKWEFhUGFBUEhjM2tOaHBMSVRUdmN6SE5kbVM3VkhEeEFaSmhlTEQ2azVUblpzZXgyU2ZyalE5aUQ1a0dPQjdGSjRMUk4reXJtOFY2N3k2K3pVZHgxVHhVT0JLY1dFamRuZStkeFJSdm9xNUgrTnhxazB1am9rcUtXelBab1dEYy9YczU2Z2k2VDBhdCt2V3BpUE5qUUxtYVA0RTFzQmROSUtQN0JweGpoTnB4Szh2di9hZytwZ2tleXZEcGhqMlFXVFAyWnorVWFnSk5SVUNBRkZNIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL3NsZWVwLW5zL3NhL3NsZWVwIiwiZXhwIjoxNzg5NTE4NDI2LCJpYXQiOjE3ODk0MzIwMjYsImlzdGlvLmlvIjp7InRydXN0X2RvbWFpbiI6ImNsdXN0ZXIubG9jYWwiLCJ3b3JrbG9hZCI6eyJuYW1lIjoic2xlZXAiLCJuYW1lc3BhY2UiOiJzbGVlcC1ucyIsInBvZCI6InNsZWVwLTY3Yjk2NmRjN2ItcTVtanoifX0sImp0aSI6IjMxNWZkOGM4YWNjYjc4ZjdlZTdkYWVlNjAyMzJiMzI3IiwiY25mIjp7Imp3ayI6eyJrdHkiOiJFQyIsImNydiI6IlAtMjU2IiwieCI6InJnenpkbDNESEM1V3lyR2VPS2hkb3NUSncwaGJjWHRpUjl1TE51MVdiTWMiLCJ5IjoiVmloUWpnSGxkRWxJRjRIX0ZCS1VtY3Y0SG5ubnhHQS15MUkwSXhCcXBkRSJ9fX0.C2uqxqIfdklZvmhkRqN8ZTViX5jpul4shRE7grvkDij4R6XCNbvwjCJ2zFfwr8_dafm-8J7FheedgEH2YMOcPsaBy1CuydI8mkrqboKskEix_9Ewx3I10_6QyYMYOA7hl6Yuf7zgx7fVCelEl21IBhvigDN3V2FhpInuVL1mYUaM66W3th_XIFXsdUzLxVzlzECqXys4BAjXKrptYGhOh9qt6pkZnimMOJFZX2Ro9LSGwceYeecfcFeIK3jVaHfW-Z4lYsOOKXxu7jJL4mbbK6xKxDSM8GU1QdQRHKk--8GnQUO2EELdrrikVPzTqpy6VT6tmvpNZLSjZjO8uyZ8ycfgwARa-70Bwzb1io5afAMqbhFudV0mMasxHEYYqp5ZF-ehgsuOZgI3Cv6E2oycUgQaMHo_a7stUXKrbqOT3YUeiaYhu0YVstH-YCU0ny0yH3wWz_jdhRzOsYmkO5IYM4MC63x9zr_neF-b_uVZfvNlns90ItuAQkdghmhxtBu8_j1jqISAz7udpWV18fapwxplToyJoK63Cor48qB2GWiXRzGKAY9_YsWubpSYSHTAhiKqThUDagRjXq-3FNPaDkjdhqCd5H8lMCK6TKiadY8DlKbAuqCPDmzxGo9DoD20_Du9ZaJsIrfrByd-XHxGe4Q0PLtwshKhLDhJwPIDk0M"
    ]
  }
}
```

## Front `httpbin` with a waypoint (a.k.a Set up `sleep → wpt-cel-egress → httpbin-waypoint → httpbin`)

```bash
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: waypoint-params
  namespace: httpbin
spec:
  workloadClaims:
    enabled: true
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: httpbin-waypoint
  namespace: httpbin
  labels:
    istio.io/waypoint-for: all
spec:
  gatewayClassName: enterprise-agentgateway-waypoint
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: waypoint-params
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF

kubectl label namespace httpbin istio.io/use-waypoint=httpbin-waypoint --overwrite
kubectl label namespace httpbin istio.io/ingress-use-waypoint=true --overwrite
```

Namespace-level labels, not Service-level: confirmed live that this works identically (waypoint logs show the request genuinely routed through `httpbin-waypoint` with the correct `src.identity`). The difference only matters if a *second* Service ever gets added to this namespace — a namespace-level label makes the waypoint the default for every Service in it, whereas a Service-level label opts in one Service at a time (and can still override the namespace default for that Service specifically). With only `httpbin` in this namespace, there's no observable difference.

Verify `sleep → wpt-cel-egress → httpbin-waypoint → httpbin` with no policies:
```bash
kubectl exec -n sleep-ns deploy/sleep -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/headers'
```
```
HTTP/1.1 200 OK
Access-Control-Allow-Credentials: true
Access-Control-Allow-Origin: *
Content-Type: application/json; charset=utf-8
Date: Tue, 15 Sep 2026 00:33:26 GMT
Transfer-Encoding: chunked

{
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Host": [
      "httpbin.httpbin.svc.cluster.local"
    ],
    "User-Agent": [
      "curl/8.22.0"
    ],
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/sleep-ns/sa/sleep, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress"
    ],
    "X-Original-Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWN3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE5ESXpNRGt4TTFvWERUTTJNRGt4TVRJek1Ea3hNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFDZlhSSHNkamU1dFN5R3dJWE5rT1BqaDdYQnp5a3prR1F5TXJmVnVNYjBZS1lsYkRuVkd6R2hnVTJFQWZoa2JyMW1wWGxnZXN5aDErQTZBV2tQWWg0UFZGRkJSNUlNNUFIWUc5LzdpRHQvaGM3c3phak9ERUtWcCt2WktQMFRjYmhtb2VmMlBqWFJnR1VqUWlvd2k5QlY0aVpvaC9nRkFDNVZzaThGMS9kdmZ5bUhTamNxcEkydXFNelRoNWE2RElZcUU2dFpieGdvamRKTThGUjV2dEtpcGFJaDFMYjIvMmRsdmFDNm5FejNHUXc1Q0gzSlYyM1pwQmxKN25BTHBJUjExa2kzci84c0RhUG93TVc0V0s4V3lIeEIzQWIxYXBESXppQkxxR0NXQjdtc1NERXprMVhpczAzVmFKTlhhY1dRT0NUM1luaXdlZ0xxNU9VeTJrWGhSOFMvMEFPc0wzcGVIcU02VmR0L0RRNk00UGIzTk94WkFqc0tEUEdUbFdHWG5DY1o2TUtDc1Nxd3M3dW9iTHpCalU0RTAzUjJaSzNtaDFqK2hXaWZuR29FZ0lWa05KWjJCamJwZS94VEdpUWxjVW41ZUdTOWZsV1hncFIrVWNqSGpQZlJNaFF5OWhPQkUxVGlsMUQydTZ3eGxzMURkc3VYOXZmMUR6QkJTeWcrcDA4T2x2aXlBc2RUQkJidGl2Tmh2MGhpUlcxL2VjMkwvbFRpWEM4aStzSXZCR09QM0lkQWNXYzl1bUltT2t2R1dDS2RqN0duT3AyWWZQalZsdkd5bFlFMFJhY3g5UnNxMDNXaGY3Q0ZzSDA2U0tPWjI3OEpYSk9LalVFK0tXNGdaNXM5cHc4aGtyclJSZU0rS2EwWDBDVTd1NVFQNlhtRFBVTytQTmNvK3dJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZPRDJMVFBSdjA0bzF2cEJSNUxKNFhVMnRjaWtNQjhHQTFVZEl3UVlNQmFBRkN1QVJzQXVCTkc4YmtobmFtK1VRZ0RXSnVWTk1BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQUFXR21abTRkV3d1UFkzZ2NRWkdrUnlCNnZXdlBGaFNadkFsaGpVa0dUV1lDOVYwV0dVSGhrN2kwZXQ2aEpaWWlhelZ1aURZNmUyRlNoZ3JOdEdxSWd5TE5ZUVRCQ1AzTXZlYWtUUm5TVlVEZ0VRc2gyNUlQQllpQll2QzdLbmlKSk9KalBhUmxCSklMcVFMeU9OaDBEOEtQVHNwai9WOHFvL3doY2Z3RDVPb3BlalE1OWlyOENDdGtjVDZSRDBobGVINUIrOEdDbjdER3pNeFlPQUFTNGUvd2lGZUNxdEtNeStIUFlmQXQ3YWM4NEd4QTZqRW53WkNPeG15L1hmWEVsMU1UdU10SVVBNDAwMXhpSnZETVNMSFphMzNyci9LOHZZVkxZZjJOcTdiNHlJTjEzay9CUUt5cG1lUUJaRThlWnNqSWdjbEZBSmtZenRFY2ZVZ282LzE0dUpBeE93S1NFQm1mdUIzL2l0S29WNEJPOEV0bnBjT0VrSUZ1dVY0TG4vblF4SkZ2UTY1ajBwcjA1S0tiR2sxaVhBeGlxdWtscjhKRXgzMnVqQmVmaVVpMVEwMnlmN1BSN3A3VWdndGN0N0ZLUXM0V253UWNjaDFuZ3Azb2o4RkllRkEyck8vMUJ2WkNPaHFCbnYwNWlQSVJPZXVQOTJhM2dseTRjZGwvdkhaNGVyRWdWVGp3Y1h3bFZ4cUM1bTAzWW1qYzdoc3Q4WkR6TU5JVi9IMWsrSXgrZ0x5STg4WllHU3IraFVVeXJlQWxiZ2h3emsyRkVwdlFQNjAzUFh5STFyaVF1bFZkTnhOVmVDN0NOaitidTNiWXptRHdHRDUzQ3Izdmg4b1pkU0Z4a3FWdmpjL3J4Sy9zUlVFSjlWbmFlRU8rWUx5cHJuV1QvMjAzajd3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5Y3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TkRJek1Ea3hNMW9YRFRNMk1Ea3hNVEl6TURreE0xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUUNmWFJIc2RqZTV0U3lHd0lYTmtPUGpoN1hCenlremtHUXlNcmZWdU1iMFlLWWxiRG5WR3pHaGdVMkVBZmhrYnIxbXBYbGdlc3loMStBNkFXa1BZaDRQVkZGQlI1SU01QUhZRzkvN2lEdC9oYzdzemFqT0RFS1ZwK3ZaS1AwVGNiaG1vZWYyUGpYUmdHVWpRaW93aTlCVjRpWm9oL2dGQUM1VnNpOEYxL2R2ZnltSFNqY3FwSTJ1cU16VGg1YTZESVlxRTZ0WmJ4Z29qZEpNOEZSNXZ0S2lwYUloMUxiMi8yZGx2YUM2bkV6M0dRdzVDSDNKVjIzWnBCbEo3bkFMcElSMTFraTNyLzhzRGFQb3dNVzRXSzhXeUh4QjNBYjFhcERJemlCTHFHQ1dCN21zU0RFemsxWGlzMDNWYUpOWGFjV1FPQ1QzWW5pd2VnTHE1T1V5MmtYaFI4Uy8wQU9zTDNwZUhxTTZWZHQvRFE2TTRQYjNOT3haQWpzS0RQR1RsV0dYbkNjWjZNS0NzU3F3czd1b2JMekJqVTRFMDNSMlpLM21oMWoraFdpZm5Hb0VnSVZrTkpaMkJqYnBlL3hUR2lRbGNVbjVlR1M5ZmxXWGdwUitVY2pIalBmUk1oUXk5aE9CRTFUaWwxRDJ1Nnd4bHMxRGRzdVg5dmYxRHpCQlN5ZytwMDhPbHZpeUFzZFRCQmJ0aXZOaHYwaGlSVzEvZWMyTC9sVGlYQzhpK3NJdkJHT1AzSWRBY1djOXVtSW1Pa3ZHV0NLZGo3R25PcDJZZlBqVmx2R3lsWUUwUmFjeDlSc3EwM1doZjdDRnNIMDZTS09aMjc4SlhKT0tqVUUrS1c0Z1o1czlwdzhoa3JyUlJlTStLYTBYMENVN3U1UVA2WG1EUFVPK1BOY28rd0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRk9EMkxUUFJ2MDRvMXZwQlI1TEo0WFUydGNpa01COEdBMVVkSXdRWU1CYUFGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFBQVdHbVptNGRXd3VQWTNnY1FaR2tSeUI2dld2UEZoU1p2QWxoalVrR1RXWUM5VjBXR1VIaGs3aTBldDZoSlpZaWF6VnVpRFk2ZTJGU2hnck50R3FJZ3lMTllRVEJDUDNNdmVha1RSblNWVURnRVFzaDI1SVBCWWlCWXZDN0tuaUpKT0pqUGFSbEJKSUxxUUx5T05oMEQ4S1BUc3BqL1Y4cW8vd2hjZndENU9vcGVqUTU5aXI4Q0N0a2NUNlJEMGhsZUg1Qis4R0NuN0RHek14WU9BQVM0ZS93aUZlQ3F0S015K0hQWWZBdDdhYzg0R3hBNmpFbndaQ094bXkvWGZYRWwxTVR1TXRJVUE0MDAxeGlKdkRNU0xIWmEzM3JyL0s4dllWTFlmMk5xN2I0eUlOMTNrL0JRS3lwbWVRQlpFOGVac2pJZ2NsRkFKa1l6dEVjZlVnbzYvMTR1SkF4T3dLU0VCbWZ1QjMvaXRLb1Y0Qk84RXRucGNPRWtJRnV1VjRMbi9uUXhKRnZRNjVqMHByMDVLS2JHazFpWEF4aXF1a2xyOEpFeDMydWpCZWZpVWkxUTAyeWY3UFI3cDdVZ2d0Y3Q3RktRczRXbndRY2NoMW5ncDNvajhGSWVGQTJyTy8xQnZaQ09ocUJudjA1aVBJUk9ldVA5MmEzZ2x5NGNkbC92SFo0ZXJFZ1ZUandjWHdsVnhxQzVtMDNZbWpjN2hzdDhaRHpNTklWL0gxaytJeCtnTHlJODhaWUdTcitoVVV5cmVBbGJnaHd6azJGRXB2UVA2MDNQWHlJMXJpUXVsVmROeE5WZUM3Q05qK2J1M2JZem1Ed0dENTNDcjN2aDhvWmRTRnhrcVZ2amMvcnhLL3NSVUVKOVZuYWVFTytZTHlwcm5XVC8yMDNqN3c9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVRW1qNW1NV3RmcmM2UTAxNm1MNWtUWXpiSHRRd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOREl6TURnMU9Wb1hEVE0yTURreE1USXpNRGcxT1Zvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUE2Z0tBeFltbk1STU1XTGJMSVVrQXN1UUFaOWNhUi9EamQwdVVMcUxXemNtK0F5blpaeCtmT0k0Mk4xR0ZzRWJrZSs0enRsZWdjK1pIVWxmWjRWQ2JkcndXeFMzb3JPSlduaVlDZjFUWHFlNXdCKzN4MUp0RHQwNm92OUN1aGI0Y3dlKzBtSkpsa0tlUElnMFZOQkVBNjdyQVZnN3Z2UXBrOGp2WE4rK3JiRkhyMUJjbjZuZDlPR1h0VVlIdlNGbmtVZGtTVDFJN1NRbUQvU0ZjZ2RuZUlqVXF1UDFhNTdrS1lrWDh4blBnQkJ1ajF3eWdrMFl1YkF3RGtRVXhwWEZoTnB6em1jdDRTZER3SkFrYjNkK29ucFRLMk8vOVA2VXhnWlEyOHpSRExER3BubDNTWVhQUCtQZGFJcG1RSCtGbEZrQWgzaERpeGlGMit3RmtFM08zUjJBd3FXY3ZYVXdNeUFtUC9BbzcrQ2JKTS9uT1FuQ0kxZ2FLRDBYUnBxa1F1YmptKyt0M2tVTzdGd282eXcyZEY0YXZ4YlFlNVJya2lVRWxDWmlEamcxc3MveTJUMTlJbGIvR0NienB2aWVjQkVRTGZCazhWV2VjdE41WGRpNWNudFU1WjY3ZXl5Mk5VWTJXbkFteTZaZHZFZ3JzWUFac0R5UXZ1cGRhalZLckZXZ25YYWNHcGdSNWR3REFwcExtY2Z3QktjY1IyVjg1V0lzVk82WjdBWGd6RFYzYWI1S3pwY25sV0U4bjltd2xIbXVTMWw2c21hTzVNdS8xeG1SSHpibkhMc0ZvWHpNN0Q2cXd0WHY3cW5PdDErQktiL2t5OTNZZEkrVGl4QU5sc0k5bENwZHp3aEwrQ2k4dUxLT0pxYkIzdzY3UTRnd3JrTUZsUDhxd2JRTUNBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUI4R0ExVWRJd1FZTUJhQUZDdUFSc0F1Qk5HOGJraG5hbStVUWdEV0p1Vk5NQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBTndjVU1rcUZkUEkveGJUUW1VMzVvWHRJVXRGRlRncThnNHFwK3AwSllVR1c2S0RpbTFWbCszQ0VENjg3VGZKNHZkUlRIbFp5ZVN1cnBTVEo0OUFuTzBCU0ZsRzhxeTV4bDdLaklZb3gvVmh6ZkI2NkNNa1gwaXZXbmdIMjlMM05TR2FQL0doRHoxbnlvSDMyVWxEWmJYa2lMcElqZTBBV0U3WXpwS2VtSnRLblk1SjRrMmMzaVhSSDZsUVFUR0NNdXM4dHo0WjFUazJZYitzUTBzMDJveE5CaGNOc2hTazl6OWh4OSt4MTIxUFkvLzYxaEJzbEptRHlISEpDUjlQcEFTKzF0L3Z4bjM3bnZ3MG9FbFN4NlZCR1BsYkozcVRFNXZ0ejRpNmZ2ekV2cGNxQmZWYVAvNTRkTU9ydVh3VGFEZUhOK1FFdkxlNWxUeFJjWmZwckQwRmZmYjIwMEUvclRCZnhtNm5hWDNvenBRV2ZnRXVGbjg2WHVtSU1BZmpMcVorSG1TQ21UdFpiYkQ5NWY2MnBLWE8vYitoSXZXTmwxTGVFN1N0TU05ek1CMjE3WHZGUTFrbC9BNTFzR0xvYUxFRkRNeW5qU0YzOGJJNjZpZTdZZkxMeEpYQWFQYUFQSGMza05ocExJVFR2Y3pITmRtUzdWSER4QVpKaGVMRDZrNVRuWnNleDJTZnJqUTlpRDVrR09CN0ZKNExSTit5cm04VjY3eTYrelVkeDFUeFVPQktjV0VqZG5lK2R4UlJ2b3E1SCtOeHFrMHVqb2txS1d6UFpvV0RjL1hzNTZnaTZUMGF0K3ZXcGlQTmpRTG1hUDRFMXNCZE5JS1A3QnB4amhOcHhLOHZ2L2FnK3Bna2V5dkRwaGoyUVdUUDJaeitVYWdKTlJVQ0FGRk0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVUVtajVtTVd0ZnJjNlEwMTZtTDVrVFl6Ykh0UXdEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TkRJek1EZzFPVm9YRFRNMk1Ea3hNVEl6TURnMU9Wb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBNmdLQXhZbW5NUk1NV0xiTElVa0FzdVFBWjljYVIvRGpkMHVVTHFMV3pjbStBeW5aWngrZk9JNDJOMUdGc0Via2UrNHp0bGVnYytaSFVsZlo0VkNiZHJ3V3hTM29yT0pXbmlZQ2YxVFhxZTV3QiszeDFKdER0MDZvdjlDdWhiNGN3ZSswbUpKbGtLZVBJZzBWTkJFQTY3ckFWZzd2dlFwazhqdlhOKytyYkZIcjFCY242bmQ5T0dYdFVZSHZTRm5rVWRrU1QxSTdTUW1EL1NGY2dkbmVJalVxdVAxYTU3a0tZa1g4eG5QZ0JCdWoxd3lnazBZdWJBd0RrUVV4cFhGaE5wenptY3Q0U2REd0pBa2IzZCtvbnBUSzJPLzlQNlV4Z1pRMjh6UkRMREdwbmwzU1lYUFArUGRhSXBtUUgrRmxGa0FoM2hEaXhpRjIrd0ZrRTNPM1IyQXdxV2N2WFV3TXlBbVAvQW83K0NiSk0vbk9RbkNJMWdhS0QwWFJwcWtRdWJqbSsrdDNrVU83RndvNnl3MmRGNGF2eGJRZTVScmtpVUVsQ1ppRGpnMXNzL3kyVDE5SWxiL0dDYnpwdmllY0JFUUxmQms4VldlY3RONVhkaTVjbnRVNVo2N2V5eTJOVVkyV25BbXk2WmR2RWdyc1lBWnNEeVF2dXBkYWpWS3JGV2duWGFjR3BnUjVkd0RBcHBMbWNmd0JLY2NSMlY4NVdJc1ZPNlo3QVhnekRWM2FiNUt6cGNubFdFOG45bXdsSG11UzFsNnNtYU81TXUvMXhtUkh6Ym5ITHNGb1h6TTdENnF3dFh2N3FuT3QxK0JLYi9reTkzWWRJK1RpeEFObHNJOWxDcGR6d2hMK0NpOHVMS09KcWJCM3c2N1E0Z3dya01GbFA4cXdiUU1DQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRkN1QVJzQXVCTkc4YmtobmFtK1VRZ0RXSnVWTk1COEdBMVVkSXdRWU1CYUFGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQU53Y1VNa3FGZFBJL3hiVFFtVTM1b1h0SVV0RkZUZ3E4ZzRxcCtwMEpZVUdXNktEaW0xVmwrM0NFRDY4N1RmSjR2ZFJUSGxaeWVTdXJwU1RKNDlBbk8wQlNGbEc4cXk1eGw3S2pJWW94L1ZoemZCNjZDTWtYMGl2V25nSDI5TDNOU0dhUC9HaER6MW55b0gzMlVsRFpiWGtpTHBJamUwQVdFN1l6cEtlbUp0S25ZNUo0azJjM2lYUkg2bFFRVEdDTXVzOHR6NFoxVGsyWWIrc1EwczAyb3hOQmhjTnNoU2s5ejloeDkreDEyMVBZLy82MWhCc2xKbUR5SEhKQ1I5UHBBUysxdC92eG4zN252dzBvRWxTeDZWQkdQbGJKM3FURTV2dHo0aTZmdnpFdnBjcUJmVmFQLzU0ZE1PcnVYd1RhRGVITitRRXZMZTVsVHhSY1pmcHJEMEZmZmIyMDBFL3JUQmZ4bTZuYVgzb3pwUVdmZ0V1Rm44Nlh1bUlNQWZqTHFaK0htU0NtVHRaYmJEOTVmNjJwS1hPL2IraEl2V05sMUxlRTdTdE1NOXpNQjIxN1h2RlExa2wvQTUxc0dMb2FMRUZETXlualNGMzhiSTY2aWU3WWZMTHhKWEFhUGFBUEhjM2tOaHBMSVRUdmN6SE5kbVM3VkhEeEFaSmhlTEQ2azVUblpzZXgyU2ZyalE5aUQ1a0dPQjdGSjRMUk4reXJtOFY2N3k2K3pVZHgxVHhVT0JLY1dFamRuZStkeFJSdm9xNUgrTnhxazB1am9rcUtXelBab1dEYy9YczU2Z2k2VDBhdCt2V3BpUE5qUUxtYVA0RTFzQmROSUtQN0JweGpoTnB4Szh2di9hZytwZ2tleXZEcGhqMlFXVFAyWnorVWFnSk5SVUNBRkZNIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL3NsZWVwLW5zL3NhL3NsZWVwIiwiZXhwIjoxNzg5NTE4NDI2LCJpYXQiOjE3ODk0MzIwMjYsImlzdGlvLmlvIjp7InRydXN0X2RvbWFpbiI6ImNsdXN0ZXIubG9jYWwiLCJ3b3JrbG9hZCI6eyJuYW1lIjoic2xlZXAiLCJuYW1lc3BhY2UiOiJzbGVlcC1ucyIsInBvZCI6InNsZWVwLTY3Yjk2NmRjN2ItcTVtanoifX0sImp0aSI6IjMxNWZkOGM4YWNjYjc4ZjdlZTdkYWVlNjAyMzJiMzI3IiwiY25mIjp7Imp3ayI6eyJrdHkiOiJFQyIsImNydiI6IlAtMjU2IiwieCI6InJnenpkbDNESEM1V3lyR2VPS2hkb3NUSncwaGJjWHRpUjl1TE51MVdiTWMiLCJ5IjoiVmloUWpnSGxkRWxJRjRIX0ZCS1VtY3Y0SG5ubnhHQS15MUkwSXhCcXBkRSJ9fX0.C2uqxqIfdklZvmhkRqN8ZTViX5jpul4shRE7grvkDij4R6XCNbvwjCJ2zFfwr8_dafm-8J7FheedgEH2YMOcPsaBy1CuydI8mkrqboKskEix_9Ewx3I10_6QyYMYOA7hl6Yuf7zgx7fVCelEl21IBhvigDN3V2FhpInuVL1mYUaM66W3th_XIFXsdUzLxVzlzECqXys4BAjXKrptYGhOh9qt6pkZnimMOJFZX2Ro9LSGwceYeecfcFeIK3jVaHfW-Z4lYsOOKXxu7jJL4mbbK6xKxDSM8GU1QdQRHKk--8GnQUO2EELdrrikVPzTqpy6VT6tmvpNZLSjZjO8uyZ8ycfgwARa-70Bwzb1io5afAMqbhFudV0mMasxHEYYqp5ZF-ehgsuOZgI3Cv6E2oycUgQaMHo_a7stUXKrbqOT3YUeiaYhu0YVstH-YCU0ny0yH3wWz_jdhRzOsYmkO5IYM4MC63x9zr_neF-b_uVZfvNlns90ItuAQkdghmhxtBu8_j1jqISAz7udpWV18fapwxplToyJoK63Cor48qB2GWiXRzGKAY9_YsWubpSYSHTAhiKqThUDagRjXq-3FNPaDkjdhqCd5H8lMCK6TKiadY8DlKbAuqCPDmzxGo9DoD20_Du9ZaJsIrfrByd-XHxGe4Q0PLtwshKhLDhJwPIDk0M"
    ]
  }
}
```

### Enforce WPT on the waypoint and stamp a proof header (a.k.a. Set up `sleep → wpt-cel-egress → httpbin-waypoint → httpbin` wtih two policies)

```bash
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: wpt-cel-echo-enforce
  namespace: httpbin
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-waypoint
  traffic:
    entWptEnforcement:
      mode: "RequireProof"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wpt-cel-echo-proof
  namespace: httpbin
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: httpbin
    port: 8000
  rules:
  - filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        add:
        - name: X-GatewayTest-Waypoint-Proof
          value: wpt-proof
    backendRefs:
    - group: ""
      kind: Service
      name: httpbin
      port: 8000
EOF
```

Verify `sleep → wpt-cel-egress → httpbin-waypoint → httpbin` wtih two policies:
```bash
kubectl exec -n sleep-ns deploy/sleep -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/headers'
```
```
HTTP/1.1 200 OK
Access-Control-Allow-Credentials: true
Access-Control-Allow-Origin: *
Content-Type: application/json; charset=utf-8
Date: Tue, 15 Sep 2026 00:34:52 GMT
Transfer-Encoding: chunked

{
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Host": [
      "httpbin.httpbin.svc.cluster.local"
    ],
    "User-Agent": [
      "curl/8.22.0"
    ],
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/sleep-ns/sa/sleep, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress"
    ],
    "X-Gatewaytest-Waypoint-Proof": [
      "wpt-proof"
    ],
    "X-Original-Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWN3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE5ESXpNRGt4TTFvWERUTTJNRGt4TVRJek1Ea3hNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFDZlhSSHNkamU1dFN5R3dJWE5rT1BqaDdYQnp5a3prR1F5TXJmVnVNYjBZS1lsYkRuVkd6R2hnVTJFQWZoa2JyMW1wWGxnZXN5aDErQTZBV2tQWWg0UFZGRkJSNUlNNUFIWUc5LzdpRHQvaGM3c3phak9ERUtWcCt2WktQMFRjYmhtb2VmMlBqWFJnR1VqUWlvd2k5QlY0aVpvaC9nRkFDNVZzaThGMS9kdmZ5bUhTamNxcEkydXFNelRoNWE2RElZcUU2dFpieGdvamRKTThGUjV2dEtpcGFJaDFMYjIvMmRsdmFDNm5FejNHUXc1Q0gzSlYyM1pwQmxKN25BTHBJUjExa2kzci84c0RhUG93TVc0V0s4V3lIeEIzQWIxYXBESXppQkxxR0NXQjdtc1NERXprMVhpczAzVmFKTlhhY1dRT0NUM1luaXdlZ0xxNU9VeTJrWGhSOFMvMEFPc0wzcGVIcU02VmR0L0RRNk00UGIzTk94WkFqc0tEUEdUbFdHWG5DY1o2TUtDc1Nxd3M3dW9iTHpCalU0RTAzUjJaSzNtaDFqK2hXaWZuR29FZ0lWa05KWjJCamJwZS94VEdpUWxjVW41ZUdTOWZsV1hncFIrVWNqSGpQZlJNaFF5OWhPQkUxVGlsMUQydTZ3eGxzMURkc3VYOXZmMUR6QkJTeWcrcDA4T2x2aXlBc2RUQkJidGl2Tmh2MGhpUlcxL2VjMkwvbFRpWEM4aStzSXZCR09QM0lkQWNXYzl1bUltT2t2R1dDS2RqN0duT3AyWWZQalZsdkd5bFlFMFJhY3g5UnNxMDNXaGY3Q0ZzSDA2U0tPWjI3OEpYSk9LalVFK0tXNGdaNXM5cHc4aGtyclJSZU0rS2EwWDBDVTd1NVFQNlhtRFBVTytQTmNvK3dJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZPRDJMVFBSdjA0bzF2cEJSNUxKNFhVMnRjaWtNQjhHQTFVZEl3UVlNQmFBRkN1QVJzQXVCTkc4YmtobmFtK1VRZ0RXSnVWTk1BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQUFXR21abTRkV3d1UFkzZ2NRWkdrUnlCNnZXdlBGaFNadkFsaGpVa0dUV1lDOVYwV0dVSGhrN2kwZXQ2aEpaWWlhelZ1aURZNmUyRlNoZ3JOdEdxSWd5TE5ZUVRCQ1AzTXZlYWtUUm5TVlVEZ0VRc2gyNUlQQllpQll2QzdLbmlKSk9KalBhUmxCSklMcVFMeU9OaDBEOEtQVHNwai9WOHFvL3doY2Z3RDVPb3BlalE1OWlyOENDdGtjVDZSRDBobGVINUIrOEdDbjdER3pNeFlPQUFTNGUvd2lGZUNxdEtNeStIUFlmQXQ3YWM4NEd4QTZqRW53WkNPeG15L1hmWEVsMU1UdU10SVVBNDAwMXhpSnZETVNMSFphMzNyci9LOHZZVkxZZjJOcTdiNHlJTjEzay9CUUt5cG1lUUJaRThlWnNqSWdjbEZBSmtZenRFY2ZVZ282LzE0dUpBeE93S1NFQm1mdUIzL2l0S29WNEJPOEV0bnBjT0VrSUZ1dVY0TG4vblF4SkZ2UTY1ajBwcjA1S0tiR2sxaVhBeGlxdWtscjhKRXgzMnVqQmVmaVVpMVEwMnlmN1BSN3A3VWdndGN0N0ZLUXM0V253UWNjaDFuZ3Azb2o4RkllRkEyck8vMUJ2WkNPaHFCbnYwNWlQSVJPZXVQOTJhM2dseTRjZGwvdkhaNGVyRWdWVGp3Y1h3bFZ4cUM1bTAzWW1qYzdoc3Q4WkR6TU5JVi9IMWsrSXgrZ0x5STg4WllHU3IraFVVeXJlQWxiZ2h3emsyRkVwdlFQNjAzUFh5STFyaVF1bFZkTnhOVmVDN0NOaitidTNiWXptRHdHRDUzQ3Izdmg4b1pkU0Z4a3FWdmpjL3J4Sy9zUlVFSjlWbmFlRU8rWUx5cHJuV1QvMjAzajd3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5Y3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TkRJek1Ea3hNMW9YRFRNMk1Ea3hNVEl6TURreE0xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUUNmWFJIc2RqZTV0U3lHd0lYTmtPUGpoN1hCenlremtHUXlNcmZWdU1iMFlLWWxiRG5WR3pHaGdVMkVBZmhrYnIxbXBYbGdlc3loMStBNkFXa1BZaDRQVkZGQlI1SU01QUhZRzkvN2lEdC9oYzdzemFqT0RFS1ZwK3ZaS1AwVGNiaG1vZWYyUGpYUmdHVWpRaW93aTlCVjRpWm9oL2dGQUM1VnNpOEYxL2R2ZnltSFNqY3FwSTJ1cU16VGg1YTZESVlxRTZ0WmJ4Z29qZEpNOEZSNXZ0S2lwYUloMUxiMi8yZGx2YUM2bkV6M0dRdzVDSDNKVjIzWnBCbEo3bkFMcElSMTFraTNyLzhzRGFQb3dNVzRXSzhXeUh4QjNBYjFhcERJemlCTHFHQ1dCN21zU0RFemsxWGlzMDNWYUpOWGFjV1FPQ1QzWW5pd2VnTHE1T1V5MmtYaFI4Uy8wQU9zTDNwZUhxTTZWZHQvRFE2TTRQYjNOT3haQWpzS0RQR1RsV0dYbkNjWjZNS0NzU3F3czd1b2JMekJqVTRFMDNSMlpLM21oMWoraFdpZm5Hb0VnSVZrTkpaMkJqYnBlL3hUR2lRbGNVbjVlR1M5ZmxXWGdwUitVY2pIalBmUk1oUXk5aE9CRTFUaWwxRDJ1Nnd4bHMxRGRzdVg5dmYxRHpCQlN5ZytwMDhPbHZpeUFzZFRCQmJ0aXZOaHYwaGlSVzEvZWMyTC9sVGlYQzhpK3NJdkJHT1AzSWRBY1djOXVtSW1Pa3ZHV0NLZGo3R25PcDJZZlBqVmx2R3lsWUUwUmFjeDlSc3EwM1doZjdDRnNIMDZTS09aMjc4SlhKT0tqVUUrS1c0Z1o1czlwdzhoa3JyUlJlTStLYTBYMENVN3U1UVA2WG1EUFVPK1BOY28rd0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRk9EMkxUUFJ2MDRvMXZwQlI1TEo0WFUydGNpa01COEdBMVVkSXdRWU1CYUFGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFBQVdHbVptNGRXd3VQWTNnY1FaR2tSeUI2dld2UEZoU1p2QWxoalVrR1RXWUM5VjBXR1VIaGs3aTBldDZoSlpZaWF6VnVpRFk2ZTJGU2hnck50R3FJZ3lMTllRVEJDUDNNdmVha1RSblNWVURnRVFzaDI1SVBCWWlCWXZDN0tuaUpKT0pqUGFSbEJKSUxxUUx5T05oMEQ4S1BUc3BqL1Y4cW8vd2hjZndENU9vcGVqUTU5aXI4Q0N0a2NUNlJEMGhsZUg1Qis4R0NuN0RHek14WU9BQVM0ZS93aUZlQ3F0S015K0hQWWZBdDdhYzg0R3hBNmpFbndaQ094bXkvWGZYRWwxTVR1TXRJVUE0MDAxeGlKdkRNU0xIWmEzM3JyL0s4dllWTFlmMk5xN2I0eUlOMTNrL0JRS3lwbWVRQlpFOGVac2pJZ2NsRkFKa1l6dEVjZlVnbzYvMTR1SkF4T3dLU0VCbWZ1QjMvaXRLb1Y0Qk84RXRucGNPRWtJRnV1VjRMbi9uUXhKRnZRNjVqMHByMDVLS2JHazFpWEF4aXF1a2xyOEpFeDMydWpCZWZpVWkxUTAyeWY3UFI3cDdVZ2d0Y3Q3RktRczRXbndRY2NoMW5ncDNvajhGSWVGQTJyTy8xQnZaQ09ocUJudjA1aVBJUk9ldVA5MmEzZ2x5NGNkbC92SFo0ZXJFZ1ZUandjWHdsVnhxQzVtMDNZbWpjN2hzdDhaRHpNTklWL0gxaytJeCtnTHlJODhaWUdTcitoVVV5cmVBbGJnaHd6azJGRXB2UVA2MDNQWHlJMXJpUXVsVmROeE5WZUM3Q05qK2J1M2JZem1Ed0dENTNDcjN2aDhvWmRTRnhrcVZ2amMvcnhLL3NSVUVKOVZuYWVFTytZTHlwcm5XVC8yMDNqN3c9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVRW1qNW1NV3RmcmM2UTAxNm1MNWtUWXpiSHRRd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOREl6TURnMU9Wb1hEVE0yTURreE1USXpNRGcxT1Zvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUE2Z0tBeFltbk1STU1XTGJMSVVrQXN1UUFaOWNhUi9EamQwdVVMcUxXemNtK0F5blpaeCtmT0k0Mk4xR0ZzRWJrZSs0enRsZWdjK1pIVWxmWjRWQ2JkcndXeFMzb3JPSlduaVlDZjFUWHFlNXdCKzN4MUp0RHQwNm92OUN1aGI0Y3dlKzBtSkpsa0tlUElnMFZOQkVBNjdyQVZnN3Z2UXBrOGp2WE4rK3JiRkhyMUJjbjZuZDlPR1h0VVlIdlNGbmtVZGtTVDFJN1NRbUQvU0ZjZ2RuZUlqVXF1UDFhNTdrS1lrWDh4blBnQkJ1ajF3eWdrMFl1YkF3RGtRVXhwWEZoTnB6em1jdDRTZER3SkFrYjNkK29ucFRLMk8vOVA2VXhnWlEyOHpSRExER3BubDNTWVhQUCtQZGFJcG1RSCtGbEZrQWgzaERpeGlGMit3RmtFM08zUjJBd3FXY3ZYVXdNeUFtUC9BbzcrQ2JKTS9uT1FuQ0kxZ2FLRDBYUnBxa1F1YmptKyt0M2tVTzdGd282eXcyZEY0YXZ4YlFlNVJya2lVRWxDWmlEamcxc3MveTJUMTlJbGIvR0NienB2aWVjQkVRTGZCazhWV2VjdE41WGRpNWNudFU1WjY3ZXl5Mk5VWTJXbkFteTZaZHZFZ3JzWUFac0R5UXZ1cGRhalZLckZXZ25YYWNHcGdSNWR3REFwcExtY2Z3QktjY1IyVjg1V0lzVk82WjdBWGd6RFYzYWI1S3pwY25sV0U4bjltd2xIbXVTMWw2c21hTzVNdS8xeG1SSHpibkhMc0ZvWHpNN0Q2cXd0WHY3cW5PdDErQktiL2t5OTNZZEkrVGl4QU5sc0k5bENwZHp3aEwrQ2k4dUxLT0pxYkIzdzY3UTRnd3JrTUZsUDhxd2JRTUNBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUI4R0ExVWRJd1FZTUJhQUZDdUFSc0F1Qk5HOGJraG5hbStVUWdEV0p1Vk5NQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBTndjVU1rcUZkUEkveGJUUW1VMzVvWHRJVXRGRlRncThnNHFwK3AwSllVR1c2S0RpbTFWbCszQ0VENjg3VGZKNHZkUlRIbFp5ZVN1cnBTVEo0OUFuTzBCU0ZsRzhxeTV4bDdLaklZb3gvVmh6ZkI2NkNNa1gwaXZXbmdIMjlMM05TR2FQL0doRHoxbnlvSDMyVWxEWmJYa2lMcElqZTBBV0U3WXpwS2VtSnRLblk1SjRrMmMzaVhSSDZsUVFUR0NNdXM4dHo0WjFUazJZYitzUTBzMDJveE5CaGNOc2hTazl6OWh4OSt4MTIxUFkvLzYxaEJzbEptRHlISEpDUjlQcEFTKzF0L3Z4bjM3bnZ3MG9FbFN4NlZCR1BsYkozcVRFNXZ0ejRpNmZ2ekV2cGNxQmZWYVAvNTRkTU9ydVh3VGFEZUhOK1FFdkxlNWxUeFJjWmZwckQwRmZmYjIwMEUvclRCZnhtNm5hWDNvenBRV2ZnRXVGbjg2WHVtSU1BZmpMcVorSG1TQ21UdFpiYkQ5NWY2MnBLWE8vYitoSXZXTmwxTGVFN1N0TU05ek1CMjE3WHZGUTFrbC9BNTFzR0xvYUxFRkRNeW5qU0YzOGJJNjZpZTdZZkxMeEpYQWFQYUFQSGMza05ocExJVFR2Y3pITmRtUzdWSER4QVpKaGVMRDZrNVRuWnNleDJTZnJqUTlpRDVrR09CN0ZKNExSTit5cm04VjY3eTYrelVkeDFUeFVPQktjV0VqZG5lK2R4UlJ2b3E1SCtOeHFrMHVqb2txS1d6UFpvV0RjL1hzNTZnaTZUMGF0K3ZXcGlQTmpRTG1hUDRFMXNCZE5JS1A3QnB4amhOcHhLOHZ2L2FnK3Bna2V5dkRwaGoyUVdUUDJaeitVYWdKTlJVQ0FGRk0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVUVtajVtTVd0ZnJjNlEwMTZtTDVrVFl6Ykh0UXdEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TkRJek1EZzFPVm9YRFRNMk1Ea3hNVEl6TURnMU9Wb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBNmdLQXhZbW5NUk1NV0xiTElVa0FzdVFBWjljYVIvRGpkMHVVTHFMV3pjbStBeW5aWngrZk9JNDJOMUdGc0Via2UrNHp0bGVnYytaSFVsZlo0VkNiZHJ3V3hTM29yT0pXbmlZQ2YxVFhxZTV3QiszeDFKdER0MDZvdjlDdWhiNGN3ZSswbUpKbGtLZVBJZzBWTkJFQTY3ckFWZzd2dlFwazhqdlhOKytyYkZIcjFCY242bmQ5T0dYdFVZSHZTRm5rVWRrU1QxSTdTUW1EL1NGY2dkbmVJalVxdVAxYTU3a0tZa1g4eG5QZ0JCdWoxd3lnazBZdWJBd0RrUVV4cFhGaE5wenptY3Q0U2REd0pBa2IzZCtvbnBUSzJPLzlQNlV4Z1pRMjh6UkRMREdwbmwzU1lYUFArUGRhSXBtUUgrRmxGa0FoM2hEaXhpRjIrd0ZrRTNPM1IyQXdxV2N2WFV3TXlBbVAvQW83K0NiSk0vbk9RbkNJMWdhS0QwWFJwcWtRdWJqbSsrdDNrVU83RndvNnl3MmRGNGF2eGJRZTVScmtpVUVsQ1ppRGpnMXNzL3kyVDE5SWxiL0dDYnpwdmllY0JFUUxmQms4VldlY3RONVhkaTVjbnRVNVo2N2V5eTJOVVkyV25BbXk2WmR2RWdyc1lBWnNEeVF2dXBkYWpWS3JGV2duWGFjR3BnUjVkd0RBcHBMbWNmd0JLY2NSMlY4NVdJc1ZPNlo3QVhnekRWM2FiNUt6cGNubFdFOG45bXdsSG11UzFsNnNtYU81TXUvMXhtUkh6Ym5ITHNGb1h6TTdENnF3dFh2N3FuT3QxK0JLYi9reTkzWWRJK1RpeEFObHNJOWxDcGR6d2hMK0NpOHVMS09KcWJCM3c2N1E0Z3dya01GbFA4cXdiUU1DQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRkN1QVJzQXVCTkc4YmtobmFtK1VRZ0RXSnVWTk1COEdBMVVkSXdRWU1CYUFGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQU53Y1VNa3FGZFBJL3hiVFFtVTM1b1h0SVV0RkZUZ3E4ZzRxcCtwMEpZVUdXNktEaW0xVmwrM0NFRDY4N1RmSjR2ZFJUSGxaeWVTdXJwU1RKNDlBbk8wQlNGbEc4cXk1eGw3S2pJWW94L1ZoemZCNjZDTWtYMGl2V25nSDI5TDNOU0dhUC9HaER6MW55b0gzMlVsRFpiWGtpTHBJamUwQVdFN1l6cEtlbUp0S25ZNUo0azJjM2lYUkg2bFFRVEdDTXVzOHR6NFoxVGsyWWIrc1EwczAyb3hOQmhjTnNoU2s5ejloeDkreDEyMVBZLy82MWhCc2xKbUR5SEhKQ1I5UHBBUysxdC92eG4zN252dzBvRWxTeDZWQkdQbGJKM3FURTV2dHo0aTZmdnpFdnBjcUJmVmFQLzU0ZE1PcnVYd1RhRGVITitRRXZMZTVsVHhSY1pmcHJEMEZmZmIyMDBFL3JUQmZ4bTZuYVgzb3pwUVdmZ0V1Rm44Nlh1bUlNQWZqTHFaK0htU0NtVHRaYmJEOTVmNjJwS1hPL2IraEl2V05sMUxlRTdTdE1NOXpNQjIxN1h2RlExa2wvQTUxc0dMb2FMRUZETXlualNGMzhiSTY2aWU3WWZMTHhKWEFhUGFBUEhjM2tOaHBMSVRUdmN6SE5kbVM3VkhEeEFaSmhlTEQ2azVUblpzZXgyU2ZyalE5aUQ1a0dPQjdGSjRMUk4reXJtOFY2N3k2K3pVZHgxVHhVT0JLY1dFamRuZStkeFJSdm9xNUgrTnhxazB1am9rcUtXelBab1dEYy9YczU2Z2k2VDBhdCt2V3BpUE5qUUxtYVA0RTFzQmROSUtQN0JweGpoTnB4Szh2di9hZytwZ2tleXZEcGhqMlFXVFAyWnorVWFnSk5SVUNBRkZNIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL3NsZWVwLW5zL3NhL3NsZWVwIiwiZXhwIjoxNzg5NTE4NDI2LCJpYXQiOjE3ODk0MzIwMjYsImlzdGlvLmlvIjp7InRydXN0X2RvbWFpbiI6ImNsdXN0ZXIubG9jYWwiLCJ3b3JrbG9hZCI6eyJuYW1lIjoic2xlZXAiLCJuYW1lc3BhY2UiOiJzbGVlcC1ucyIsInBvZCI6InNsZWVwLTY3Yjk2NmRjN2ItcTVtanoifX0sImp0aSI6IjMxNWZkOGM4YWNjYjc4ZjdlZTdkYWVlNjAyMzJiMzI3IiwiY25mIjp7Imp3ayI6eyJrdHkiOiJFQyIsImNydiI6IlAtMjU2IiwieCI6InJnenpkbDNESEM1V3lyR2VPS2hkb3NUSncwaGJjWHRpUjl1TE51MVdiTWMiLCJ5IjoiVmloUWpnSGxkRWxJRjRIX0ZCS1VtY3Y0SG5ubnhHQS15MUkwSXhCcXBkRSJ9fX0.C2uqxqIfdklZvmhkRqN8ZTViX5jpul4shRE7grvkDij4R6XCNbvwjCJ2zFfwr8_dafm-8J7FheedgEH2YMOcPsaBy1CuydI8mkrqboKskEix_9Ewx3I10_6QyYMYOA7hl6Yuf7zgx7fVCelEl21IBhvigDN3V2FhpInuVL1mYUaM66W3th_XIFXsdUzLxVzlzECqXys4BAjXKrptYGhOh9qt6pkZnimMOJFZX2Ro9LSGwceYeecfcFeIK3jVaHfW-Z4lYsOOKXxu7jJL4mbbK6xKxDSM8GU1QdQRHKk--8GnQUO2EELdrrikVPzTqpy6VT6tmvpNZLSjZjO8uyZ8ycfgwARa-70Bwzb1io5afAMqbhFudV0mMasxHEYYqp5ZF-ehgsuOZgI3Cv6E2oycUgQaMHo_a7stUXKrbqOT3YUeiaYhu0YVstH-YCU0ny0yH3wWz_jdhRzOsYmkO5IYM4MC63x9zr_neF-b_uVZfvNlns90ItuAQkdghmhxtBu8_j1jqISAz7udpWV18fapwxplToyJoK63Cor48qB2GWiXRzGKAY9_YsWubpSYSHTAhiKqThUDagRjXq-3FNPaDkjdhqCd5H8lMCK6TKiadY8DlKbAuqCPDmzxGo9DoD20_Du9ZaJsIrfrByd-XHxGe4Q0PLtwshKhLDhJwPIDk0M"
    ]
  }
}
```

## Add an ingress gateway in front of the waypoint (a.k.a. Set up `sleep → wpt-cel-egress → wpt-cel-ingress → httpbin-waypoint → httpbin`)

Insert a second gateway between `wpt-cel-egress` and `httpbin`'s waypoint, extending the chain by one more hop: `sleep → wpt-cel-egress → wpt-cel-ingress → agentgateway-waypoint → httpbin`. `wpt-cel-ingress` is built identically to `wpt-cel-egress` (same GatewayClass, same tunnel label, same `SourceDelegation`/`emitProof` + `entWptEnforcement: RequireProof` pair) — each hop that holds these policies both validates the proof it received and mints a new one of its own before forwarding.

```bash
kubectl create namespace i-pig

kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: wpt-cel-ingress-params
  namespace: i-pig
spec:
  workloadClaims:
    enabled: true
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: wpt-cel-ingress
  namespace: i-pig
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    labels:
      networking.istio.io/tunnel: "http"
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: wpt-cel-ingress-params
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
  name: wpt-cel-ingress-enforce
  namespace: i-pig
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: wpt-cel-ingress
  traffic:
    entWptEnforcement:
      mode: "RequireProof"
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: wpt-cel-ingress-emit
  namespace: i-pig
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: wpt-cel-ingress
  backend:
    workloadIdentity:
      mode: SourceDelegation
      emitProof: true
      proofLifetime: 60s
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wpt-cel-ingress-to-echo
  namespace: httpbin
spec:
  parentRefs:
  - name: wpt-cel-ingress
    namespace: i-pig
  rules:
  - backendRefs:
    - group: ""
      kind: Service
      name: httpbin
      port: 8000
EOF
```

Re-point `wpt-cel-egress-to-echo` at `wpt-cel-ingress` instead of `httpbin` directly. This is a cross-namespace backendRef (the `HTTPRoute` lives in `httpbin`, the `Service` it now points to is in `default`), which Gateway API requires an explicit `ReferenceGrant` for — without it, the request fails with `500 backend does not exist`.

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-httpbin-to-default-services
  namespace: i-pig
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: httpbin
  to:
  - group: ""
    kind: Service
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wpt-cel-egress-to-echo
  namespace: httpbin
spec:
  parentRefs:
  - name: wpt-cel-egress
    namespace: i-peg
  rules:
  - backendRefs:
    - group: ""
      kind: Service
      name: wpt-cel-ingress
      namespace: i-pig
      port: 8080
EOF
```

Verify `sleep → wpt-cel-egress → wpt-cel-ingress → httpbin-waypoint → httpbin`:
```bash
kubectl exec -n sleep-ns deploy/sleep -- sh -c 'curl -si --max-time 15 http://wpt-cel-egress.i-peg.svc.cluster.local:8080/headers'
```
```
HTTP/1.1 200 OK
Access-Control-Allow-Credentials: true
Access-Control-Allow-Origin: *
Content-Type: application/json; charset=utf-8
Date: Tue, 15 Sep 2026 00:39:02 GMT
Transfer-Encoding: chunked

{
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Host": [
      "httpbin.httpbin.svc.cluster.local"
    ],
    "User-Agent": [
      "curl/8.22.0"
    ],
    "X-Forwarded-Workload-Identity": [
      "spiffe://cluster.local/ns/sleep-ns/sa/sleep, spiffe://cluster.local/ns/i-peg/sa/wpt-cel-egress, spiffe://cluster.local/ns/i-pig/sa/wpt-cel-ingress"
    ],
    "X-Gatewaytest-Waypoint-Proof": [
      "wpt-proof"
    ],
    "X-Original-Workload-Identity-Token": [
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IndpdCtqd3QiLCJ4NWMiOlsiTUlJRlR6Q0NBemVnQXdJQkFnSVVSeGFyU1BrSlptclY0MEVyVXFCeHVDcHRkOWN3RFFZSktvWklodmNOQVFFTEJRQXdGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1CNFhEVEkyTURreE5ESXpNRGt4TTFvWERUTTJNRGt4TVRJek1Ea3hNMW93SHpFZE1Cc0dBMVVFQ2d3VVZHVnpkQ0JKYm5SbGNtMWxaR2xoZEdVZ1EwRXdnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFDZlhSSHNkamU1dFN5R3dJWE5rT1BqaDdYQnp5a3prR1F5TXJmVnVNYjBZS1lsYkRuVkd6R2hnVTJFQWZoa2JyMW1wWGxnZXN5aDErQTZBV2tQWWg0UFZGRkJSNUlNNUFIWUc5LzdpRHQvaGM3c3phak9ERUtWcCt2WktQMFRjYmhtb2VmMlBqWFJnR1VqUWlvd2k5QlY0aVpvaC9nRkFDNVZzaThGMS9kdmZ5bUhTamNxcEkydXFNelRoNWE2RElZcUU2dFpieGdvamRKTThGUjV2dEtpcGFJaDFMYjIvMmRsdmFDNm5FejNHUXc1Q0gzSlYyM1pwQmxKN25BTHBJUjExa2kzci84c0RhUG93TVc0V0s4V3lIeEIzQWIxYXBESXppQkxxR0NXQjdtc1NERXprMVhpczAzVmFKTlhhY1dRT0NUM1luaXdlZ0xxNU9VeTJrWGhSOFMvMEFPc0wzcGVIcU02VmR0L0RRNk00UGIzTk94WkFqc0tEUEdUbFdHWG5DY1o2TUtDc1Nxd3M3dW9iTHpCalU0RTAzUjJaSzNtaDFqK2hXaWZuR29FZ0lWa05KWjJCamJwZS94VEdpUWxjVW41ZUdTOWZsV1hncFIrVWNqSGpQZlJNaFF5OWhPQkUxVGlsMUQydTZ3eGxzMURkc3VYOXZmMUR6QkJTeWcrcDA4T2x2aXlBc2RUQkJidGl2Tmh2MGhpUlcxL2VjMkwvbFRpWEM4aStzSXZCR09QM0lkQWNXYzl1bUltT2t2R1dDS2RqN0duT3AyWWZQalZsdkd5bFlFMFJhY3g5UnNxMDNXaGY3Q0ZzSDA2U0tPWjI3OEpYSk9LalVFK0tXNGdaNXM5cHc4aGtyclJSZU0rS2EwWDBDVTd1NVFQNlhtRFBVTytQTmNvK3dJREFRQUJvNEdLTUlHSE1CSUdBMVVkRXdFQi93UUlNQVlCQWY4Q0FRQXdEZ1lEVlIwUEFRSC9CQVFEQWdFR01DRUdBMVVkRVFRYU1CaUdGbk53YVdabVpUb3ZMMk5zZFhOMFpYSXViRzlqWVd3d0hRWURWUjBPQkJZRUZPRDJMVFBSdjA0bzF2cEJSNUxKNFhVMnRjaWtNQjhHQTFVZEl3UVlNQmFBRkN1QVJzQXVCTkc4YmtobmFtK1VRZ0RXSnVWTk1BMEdDU3FHU0liM0RRRUJDd1VBQTRJQ0FRQUFXR21abTRkV3d1UFkzZ2NRWkdrUnlCNnZXdlBGaFNadkFsaGpVa0dUV1lDOVYwV0dVSGhrN2kwZXQ2aEpaWWlhelZ1aURZNmUyRlNoZ3JOdEdxSWd5TE5ZUVRCQ1AzTXZlYWtUUm5TVlVEZ0VRc2gyNUlQQllpQll2QzdLbmlKSk9KalBhUmxCSklMcVFMeU9OaDBEOEtQVHNwai9WOHFvL3doY2Z3RDVPb3BlalE1OWlyOENDdGtjVDZSRDBobGVINUIrOEdDbjdER3pNeFlPQUFTNGUvd2lGZUNxdEtNeStIUFlmQXQ3YWM4NEd4QTZqRW53WkNPeG15L1hmWEVsMU1UdU10SVVBNDAwMXhpSnZETVNMSFphMzNyci9LOHZZVkxZZjJOcTdiNHlJTjEzay9CUUt5cG1lUUJaRThlWnNqSWdjbEZBSmtZenRFY2ZVZ282LzE0dUpBeE93S1NFQm1mdUIzL2l0S29WNEJPOEV0bnBjT0VrSUZ1dVY0TG4vblF4SkZ2UTY1ajBwcjA1S0tiR2sxaVhBeGlxdWtscjhKRXgzMnVqQmVmaVVpMVEwMnlmN1BSN3A3VWdndGN0N0ZLUXM0V253UWNjaDFuZ3Azb2o4RkllRkEyck8vMUJ2WkNPaHFCbnYwNWlQSVJPZXVQOTJhM2dseTRjZGwvdkhaNGVyRWdWVGp3Y1h3bFZ4cUM1bTAzWW1qYzdoc3Q4WkR6TU5JVi9IMWsrSXgrZ0x5STg4WllHU3IraFVVeXJlQWxiZ2h3emsyRkVwdlFQNjAzUFh5STFyaVF1bFZkTnhOVmVDN0NOaitidTNiWXptRHdHRDUzQ3Izdmg4b1pkU0Z4a3FWdmpjL3J4Sy9zUlVFSjlWbmFlRU8rWUx5cHJuV1QvMjAzajd3PT0iLCJNSUlGVHpDQ0F6ZWdBd0lCQWdJVVJ4YXJTUGtKWm1yVjQwRXJVcUJ4dUNwdGQ5Y3dEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TkRJek1Ea3hNMW9YRFRNMk1Ea3hNVEl6TURreE0xb3dIekVkTUJzR0ExVUVDZ3dVVkdWemRDQkpiblJsY20xbFpHbGhkR1VnUTBFd2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJS0FvSUNBUUNmWFJIc2RqZTV0U3lHd0lYTmtPUGpoN1hCenlremtHUXlNcmZWdU1iMFlLWWxiRG5WR3pHaGdVMkVBZmhrYnIxbXBYbGdlc3loMStBNkFXa1BZaDRQVkZGQlI1SU01QUhZRzkvN2lEdC9oYzdzemFqT0RFS1ZwK3ZaS1AwVGNiaG1vZWYyUGpYUmdHVWpRaW93aTlCVjRpWm9oL2dGQUM1VnNpOEYxL2R2ZnltSFNqY3FwSTJ1cU16VGg1YTZESVlxRTZ0WmJ4Z29qZEpNOEZSNXZ0S2lwYUloMUxiMi8yZGx2YUM2bkV6M0dRdzVDSDNKVjIzWnBCbEo3bkFMcElSMTFraTNyLzhzRGFQb3dNVzRXSzhXeUh4QjNBYjFhcERJemlCTHFHQ1dCN21zU0RFemsxWGlzMDNWYUpOWGFjV1FPQ1QzWW5pd2VnTHE1T1V5MmtYaFI4Uy8wQU9zTDNwZUhxTTZWZHQvRFE2TTRQYjNOT3haQWpzS0RQR1RsV0dYbkNjWjZNS0NzU3F3czd1b2JMekJqVTRFMDNSMlpLM21oMWoraFdpZm5Hb0VnSVZrTkpaMkJqYnBlL3hUR2lRbGNVbjVlR1M5ZmxXWGdwUitVY2pIalBmUk1oUXk5aE9CRTFUaWwxRDJ1Nnd4bHMxRGRzdVg5dmYxRHpCQlN5ZytwMDhPbHZpeUFzZFRCQmJ0aXZOaHYwaGlSVzEvZWMyTC9sVGlYQzhpK3NJdkJHT1AzSWRBY1djOXVtSW1Pa3ZHV0NLZGo3R25PcDJZZlBqVmx2R3lsWUUwUmFjeDlSc3EwM1doZjdDRnNIMDZTS09aMjc4SlhKT0tqVUUrS1c0Z1o1czlwdzhoa3JyUlJlTStLYTBYMENVN3U1UVA2WG1EUFVPK1BOY28rd0lEQVFBQm80R0tNSUdITUJJR0ExVWRFd0VCL3dRSU1BWUJBZjhDQVFBd0RnWURWUjBQQVFIL0JBUURBZ0VHTUNFR0ExVWRFUVFhTUJpR0ZuTndhV1ptWlRvdkwyTnNkWE4wWlhJdWJHOWpZV3d3SFFZRFZSME9CQllFRk9EMkxUUFJ2MDRvMXZwQlI1TEo0WFUydGNpa01COEdBMVVkSXdRWU1CYUFGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUEwR0NTcUdTSWIzRFFFQkN3VUFBNElDQVFBQVdHbVptNGRXd3VQWTNnY1FaR2tSeUI2dld2UEZoU1p2QWxoalVrR1RXWUM5VjBXR1VIaGs3aTBldDZoSlpZaWF6VnVpRFk2ZTJGU2hnck50R3FJZ3lMTllRVEJDUDNNdmVha1RSblNWVURnRVFzaDI1SVBCWWlCWXZDN0tuaUpKT0pqUGFSbEJKSUxxUUx5T05oMEQ4S1BUc3BqL1Y4cW8vd2hjZndENU9vcGVqUTU5aXI4Q0N0a2NUNlJEMGhsZUg1Qis4R0NuN0RHek14WU9BQVM0ZS93aUZlQ3F0S015K0hQWWZBdDdhYzg0R3hBNmpFbndaQ094bXkvWGZYRWwxTVR1TXRJVUE0MDAxeGlKdkRNU0xIWmEzM3JyL0s4dllWTFlmMk5xN2I0eUlOMTNrL0JRS3lwbWVRQlpFOGVac2pJZ2NsRkFKa1l6dEVjZlVnbzYvMTR1SkF4T3dLU0VCbWZ1QjMvaXRLb1Y0Qk84RXRucGNPRWtJRnV1VjRMbi9uUXhKRnZRNjVqMHByMDVLS2JHazFpWEF4aXF1a2xyOEpFeDMydWpCZWZpVWkxUTAyeWY3UFI3cDdVZ2d0Y3Q3RktRczRXbndRY2NoMW5ncDNvajhGSWVGQTJyTy8xQnZaQ09ocUJudjA1aVBJUk9ldVA5MmEzZ2x5NGNkbC92SFo0ZXJFZ1ZUandjWHdsVnhxQzVtMDNZbWpjN2hzdDhaRHpNTklWL0gxaytJeCtnTHlJODhaWUdTcitoVVV5cmVBbGJnaHd6azJGRXB2UVA2MDNQWHlJMXJpUXVsVmROeE5WZUM3Q05qK2J1M2JZem1Ed0dENTNDcjN2aDhvWmRTRnhrcVZ2amMvcnhLL3NSVUVKOVZuYWVFTytZTHlwcm5XVC8yMDNqN3c9PSIsIk1JSUZEekNDQXZlZ0F3SUJBZ0lVRW1qNW1NV3RmcmM2UTAxNm1MNWtUWXpiSHRRd0RRWUpLb1pJaHZjTkFRRUxCUUF3RnpFVk1CTUdBMVVFQ2d3TVZHVnpkQ0JTYjI5MElFTkJNQjRYRFRJMk1Ea3hOREl6TURnMU9Wb1hEVE0yTURreE1USXpNRGcxT1Zvd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUlJQ0lqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FnOEFNSUlDQ2dLQ0FnRUE2Z0tBeFltbk1STU1XTGJMSVVrQXN1UUFaOWNhUi9EamQwdVVMcUxXemNtK0F5blpaeCtmT0k0Mk4xR0ZzRWJrZSs0enRsZWdjK1pIVWxmWjRWQ2JkcndXeFMzb3JPSlduaVlDZjFUWHFlNXdCKzN4MUp0RHQwNm92OUN1aGI0Y3dlKzBtSkpsa0tlUElnMFZOQkVBNjdyQVZnN3Z2UXBrOGp2WE4rK3JiRkhyMUJjbjZuZDlPR1h0VVlIdlNGbmtVZGtTVDFJN1NRbUQvU0ZjZ2RuZUlqVXF1UDFhNTdrS1lrWDh4blBnQkJ1ajF3eWdrMFl1YkF3RGtRVXhwWEZoTnB6em1jdDRTZER3SkFrYjNkK29ucFRLMk8vOVA2VXhnWlEyOHpSRExER3BubDNTWVhQUCtQZGFJcG1RSCtGbEZrQWgzaERpeGlGMit3RmtFM08zUjJBd3FXY3ZYVXdNeUFtUC9BbzcrQ2JKTS9uT1FuQ0kxZ2FLRDBYUnBxa1F1YmptKyt0M2tVTzdGd282eXcyZEY0YXZ4YlFlNVJya2lVRWxDWmlEamcxc3MveTJUMTlJbGIvR0NienB2aWVjQkVRTGZCazhWV2VjdE41WGRpNWNudFU1WjY3ZXl5Mk5VWTJXbkFteTZaZHZFZ3JzWUFac0R5UXZ1cGRhalZLckZXZ25YYWNHcGdSNWR3REFwcExtY2Z3QktjY1IyVjg1V0lzVk82WjdBWGd6RFYzYWI1S3pwY25sV0U4bjltd2xIbXVTMWw2c21hTzVNdS8xeG1SSHpibkhMc0ZvWHpNN0Q2cXd0WHY3cW5PdDErQktiL2t5OTNZZEkrVGl4QU5sc0k5bENwZHp3aEwrQ2k4dUxLT0pxYkIzdzY3UTRnd3JrTUZsUDhxd2JRTUNBd0VBQWFOVE1GRXdIUVlEVlIwT0JCWUVGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUI4R0ExVWRJd1FZTUJhQUZDdUFSc0F1Qk5HOGJraG5hbStVUWdEV0p1Vk5NQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEUVlKS29aSWh2Y05BUUVMQlFBRGdnSUJBTndjVU1rcUZkUEkveGJUUW1VMzVvWHRJVXRGRlRncThnNHFwK3AwSllVR1c2S0RpbTFWbCszQ0VENjg3VGZKNHZkUlRIbFp5ZVN1cnBTVEo0OUFuTzBCU0ZsRzhxeTV4bDdLaklZb3gvVmh6ZkI2NkNNa1gwaXZXbmdIMjlMM05TR2FQL0doRHoxbnlvSDMyVWxEWmJYa2lMcElqZTBBV0U3WXpwS2VtSnRLblk1SjRrMmMzaVhSSDZsUVFUR0NNdXM4dHo0WjFUazJZYitzUTBzMDJveE5CaGNOc2hTazl6OWh4OSt4MTIxUFkvLzYxaEJzbEptRHlISEpDUjlQcEFTKzF0L3Z4bjM3bnZ3MG9FbFN4NlZCR1BsYkozcVRFNXZ0ejRpNmZ2ekV2cGNxQmZWYVAvNTRkTU9ydVh3VGFEZUhOK1FFdkxlNWxUeFJjWmZwckQwRmZmYjIwMEUvclRCZnhtNm5hWDNvenBRV2ZnRXVGbjg2WHVtSU1BZmpMcVorSG1TQ21UdFpiYkQ5NWY2MnBLWE8vYitoSXZXTmwxTGVFN1N0TU05ek1CMjE3WHZGUTFrbC9BNTFzR0xvYUxFRkRNeW5qU0YzOGJJNjZpZTdZZkxMeEpYQWFQYUFQSGMza05ocExJVFR2Y3pITmRtUzdWSER4QVpKaGVMRDZrNVRuWnNleDJTZnJqUTlpRDVrR09CN0ZKNExSTit5cm04VjY3eTYrelVkeDFUeFVPQktjV0VqZG5lK2R4UlJ2b3E1SCtOeHFrMHVqb2txS1d6UFpvV0RjL1hzNTZnaTZUMGF0K3ZXcGlQTmpRTG1hUDRFMXNCZE5JS1A3QnB4amhOcHhLOHZ2L2FnK3Bna2V5dkRwaGoyUVdUUDJaeitVYWdKTlJVQ0FGRk0iLCJNSUlGRHpDQ0F2ZWdBd0lCQWdJVUVtajVtTVd0ZnJjNlEwMTZtTDVrVFl6Ykh0UXdEUVlKS29aSWh2Y05BUUVMQlFBd0Z6RVZNQk1HQTFVRUNnd01WR1Z6ZENCU2IyOTBJRU5CTUI0WERUSTJNRGt4TkRJek1EZzFPVm9YRFRNMk1Ea3hNVEl6TURnMU9Wb3dGekVWTUJNR0ExVUVDZ3dNVkdWemRDQlNiMjkwSUVOQk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBNmdLQXhZbW5NUk1NV0xiTElVa0FzdVFBWjljYVIvRGpkMHVVTHFMV3pjbStBeW5aWngrZk9JNDJOMUdGc0Via2UrNHp0bGVnYytaSFVsZlo0VkNiZHJ3V3hTM29yT0pXbmlZQ2YxVFhxZTV3QiszeDFKdER0MDZvdjlDdWhiNGN3ZSswbUpKbGtLZVBJZzBWTkJFQTY3ckFWZzd2dlFwazhqdlhOKytyYkZIcjFCY242bmQ5T0dYdFVZSHZTRm5rVWRrU1QxSTdTUW1EL1NGY2dkbmVJalVxdVAxYTU3a0tZa1g4eG5QZ0JCdWoxd3lnazBZdWJBd0RrUVV4cFhGaE5wenptY3Q0U2REd0pBa2IzZCtvbnBUSzJPLzlQNlV4Z1pRMjh6UkRMREdwbmwzU1lYUFArUGRhSXBtUUgrRmxGa0FoM2hEaXhpRjIrd0ZrRTNPM1IyQXdxV2N2WFV3TXlBbVAvQW83K0NiSk0vbk9RbkNJMWdhS0QwWFJwcWtRdWJqbSsrdDNrVU83RndvNnl3MmRGNGF2eGJRZTVScmtpVUVsQ1ppRGpnMXNzL3kyVDE5SWxiL0dDYnpwdmllY0JFUUxmQms4VldlY3RONVhkaTVjbnRVNVo2N2V5eTJOVVkyV25BbXk2WmR2RWdyc1lBWnNEeVF2dXBkYWpWS3JGV2duWGFjR3BnUjVkd0RBcHBMbWNmd0JLY2NSMlY4NVdJc1ZPNlo3QVhnekRWM2FiNUt6cGNubFdFOG45bXdsSG11UzFsNnNtYU81TXUvMXhtUkh6Ym5ITHNGb1h6TTdENnF3dFh2N3FuT3QxK0JLYi9reTkzWWRJK1RpeEFObHNJOWxDcGR6d2hMK0NpOHVMS09KcWJCM3c2N1E0Z3dya01GbFA4cXdiUU1DQXdFQUFhTlRNRkV3SFFZRFZSME9CQllFRkN1QVJzQXVCTkc4YmtobmFtK1VRZ0RXSnVWTk1COEdBMVVkSXdRWU1CYUFGQ3VBUnNBdUJORzhia2huYW0rVVFnRFdKdVZOTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RFFZSktvWklodmNOQVFFTEJRQURnZ0lCQU53Y1VNa3FGZFBJL3hiVFFtVTM1b1h0SVV0RkZUZ3E4ZzRxcCtwMEpZVUdXNktEaW0xVmwrM0NFRDY4N1RmSjR2ZFJUSGxaeWVTdXJwU1RKNDlBbk8wQlNGbEc4cXk1eGw3S2pJWW94L1ZoemZCNjZDTWtYMGl2V25nSDI5TDNOU0dhUC9HaER6MW55b0gzMlVsRFpiWGtpTHBJamUwQVdFN1l6cEtlbUp0S25ZNUo0azJjM2lYUkg2bFFRVEdDTXVzOHR6NFoxVGsyWWIrc1EwczAyb3hOQmhjTnNoU2s5ejloeDkreDEyMVBZLy82MWhCc2xKbUR5SEhKQ1I5UHBBUysxdC92eG4zN252dzBvRWxTeDZWQkdQbGJKM3FURTV2dHo0aTZmdnpFdnBjcUJmVmFQLzU0ZE1PcnVYd1RhRGVITitRRXZMZTVsVHhSY1pmcHJEMEZmZmIyMDBFL3JUQmZ4bTZuYVgzb3pwUVdmZ0V1Rm44Nlh1bUlNQWZqTHFaK0htU0NtVHRaYmJEOTVmNjJwS1hPL2IraEl2V05sMUxlRTdTdE1NOXpNQjIxN1h2RlExa2wvQTUxc0dMb2FMRUZETXlualNGMzhiSTY2aWU3WWZMTHhKWEFhUGFBUEhjM2tOaHBMSVRUdmN6SE5kbVM3VkhEeEFaSmhlTEQ2azVUblpzZXgyU2ZyalE5aUQ1a0dPQjdGSjRMUk4reXJtOFY2N3k2K3pVZHgxVHhVT0JLY1dFamRuZStkeFJSdm9xNUgrTnhxazB1am9rcUtXelBab1dEYy9YczU2Z2k2VDBhdCt2V3BpUE5qUUxtYVA0RTFzQmROSUtQN0JweGpoTnB4Szh2di9hZytwZ2tleXZEcGhqMlFXVFAyWnorVWFnSk5SVUNBRkZNIl19.eyJpc3MiOiJodHRwczovL2lzdGlvZC5pc3Rpby1zeXN0ZW0uc3ZjLmNsdXN0ZXIubG9jYWwiLCJzdWIiOiJzcGlmZmU6Ly9jbHVzdGVyLmxvY2FsL25zL3NsZWVwLW5zL3NhL3NsZWVwIiwiZXhwIjoxNzg5NTE4NDI2LCJpYXQiOjE3ODk0MzIwMjYsImlzdGlvLmlvIjp7InRydXN0X2RvbWFpbiI6ImNsdXN0ZXIubG9jYWwiLCJ3b3JrbG9hZCI6eyJuYW1lIjoic2xlZXAiLCJuYW1lc3BhY2UiOiJzbGVlcC1ucyIsInBvZCI6InNsZWVwLTY3Yjk2NmRjN2ItcTVtanoifX0sImp0aSI6IjMxNWZkOGM4YWNjYjc4ZjdlZTdkYWVlNjAyMzJiMzI3IiwiY25mIjp7Imp3ayI6eyJrdHkiOiJFQyIsImNydiI6IlAtMjU2IiwieCI6InJnenpkbDNESEM1V3lyR2VPS2hkb3NUSncwaGJjWHRpUjl1TE51MVdiTWMiLCJ5IjoiVmloUWpnSGxkRWxJRjRIX0ZCS1VtY3Y0SG5ubnhHQS15MUkwSXhCcXBkRSJ9fX0.C2uqxqIfdklZvmhkRqN8ZTViX5jpul4shRE7grvkDij4R6XCNbvwjCJ2zFfwr8_dafm-8J7FheedgEH2YMOcPsaBy1CuydI8mkrqboKskEix_9Ewx3I10_6QyYMYOA7hl6Yuf7zgx7fVCelEl21IBhvigDN3V2FhpInuVL1mYUaM66W3th_XIFXsdUzLxVzlzECqXys4BAjXKrptYGhOh9qt6pkZnimMOJFZX2Ro9LSGwceYeecfcFeIK3jVaHfW-Z4lYsOOKXxu7jJL4mbbK6xKxDSM8GU1QdQRHKk--8GnQUO2EELdrrikVPzTqpy6VT6tmvpNZLSjZjO8uyZ8ycfgwARa-70Bwzb1io5afAMqbhFudV0mMasxHEYYqp5ZF-ehgsuOZgI3Cv6E2oycUgQaMHo_a7stUXKrbqOT3YUeiaYhu0YVstH-YCU0ny0yH3wWz_jdhRzOsYmkO5IYM4MC63x9zr_neF-b_uVZfvNlns90ItuAQkdghmhxtBu8_j1jqISAz7udpWV18fapwxplToyJoK63Cor48qB2GWiXRzGKAY9_YsWubpSYSHTAhiKqThUDagRjXq-3FNPaDkjdhqCd5H8lMCK6TKiadY8DlKbAuqCPDmzxGo9DoD20_Du9ZaJsIrfrByd-XHxGe4Q0PLtwshKhLDhJwPIDk0M"
    ]
  }
}
```

Three entries in `X-Forwarded-Workload-Identity` now — `sleep`, `wpt-cel-egress`, `wpt-cel-ingress` — each appended by the hop that vouched for the request, in order.


## Teardown

```bash
kind delete cluster --name ${KIND_CLUSTER}
# and Ctrl-C the `sudo cloud-provider-kind` terminal
```


