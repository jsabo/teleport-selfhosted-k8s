# 03 — OpenShift: Teleport Enterprise behind a passthrough Route

Self-hosted Teleport Enterprise on **OpenShift 4.x**: SQLite standalone,
single replica, exposed through an OpenShift **Route with passthrough
termination** instead of a LoadBalancer Service.

```
 browser / tsh
      │ https + ALPN
      ▼
 teleport.apps.<cluster>.<base-domain>:443     (or your own domain — Step 0)
      │ OpenShift router (HAProxy) — passthrough: raw TLS, SNI-matched
      ▼
 proxy pod :3080 ──► auth pod ──► PVC (SQLite state + session recordings)
```

**Requirements:** OpenShift 4.x with `cluster-admin`, `helm` ≥ 3.4.2,
`kubectl`/`oc`, `openssl`, and `license.pem` at the repo root (same as
[01](../01-quickstart/) / [02](../02-identity-security/)).

Unlike 01/02 this walkthrough doesn't use the k3s test bed or `/etc/hosts`
tricks — it assumes a real OpenShift cluster with real DNS.

---

## 0 — Determine your cluster name

`clusterName` is permanent — it cannot be changed post-install without
wiping all data. It must exactly match the Route hostname that users
connect to.

**Option 1 — a name under the OpenShift apps domain** (zero extra DNS work;
the wildcard `*.apps...` record already exists):

```bash
APPS_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export CLUSTER_NAME="teleport.${APPS_DOMAIN}"
export KUBE_CLUSTER_NAME=$(oc get infrastructure/cluster -o jsonpath='{.status.infrastructureName}')
echo $CLUSTER_NAME        # e.g. teleport.apps.ocp.example.com
echo $KUBE_CLUSTER_NAME   # e.g. ocp
```

**Option 2 — any public DNS name you control** (e.g. `teleport.example.com`,
independent of the domain OpenShift was installed with). The router matches
passthrough Routes by SNI, so any hostname works as long as it resolves to
the router:

```bash
export CLUSTER_NAME="teleport.example.com"
export KUBE_CLUSTER_NAME=$(oc get infrastructure/cluster -o jsonpath='{.status.infrastructureName}')

# Find the router's load balancer address, then create a CNAME to it
# in YOUR domain's DNS zone:   teleport.example.com → <router LB hostname>
oc -n openshift-ingress get svc router-default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

> **Custom-domain notes:**
> - The OpenShift install's base domain is irrelevant here — it only
>   constrained what the *installer* could create in Route53. Routes can
>   serve any hostname.
> - Planning to use **Application Access**? Apps are served at
>   `<app>.${CLUSTER_NAME}`, which needs a wildcard DNS record
>   (`*.teleport.example.com` → same CNAME), the wildcard in the cert SAN, and a
>   second Route with `wildcardPolicy: Subdomain` — which the default
>   IngressController rejects until you set
>   `spec.routeAdmission.wildcardPolicy: WildcardsAllowed` on it.

> **Why this matters:** `clusterName` must exactly match the Route hostname,
> and the cert you provide must have it in the SAN. A mismatch means Teleport
> won't find a matching cert for the incoming SNI, won't configure ALPN for
> that connection, and `tsh login` fails with
> `"missing selected ALPN property"` after password+OTP succeed — even with
> `--insecure`. `clusterName` is also embedded in all issued certs and join
> tokens, so it is truly permanent.

---

## 1 — Helm repo + namespace

```bash
helm repo add teleport https://charts.releases.teleport.dev
helm repo update

kubectl create namespace teleport
kubectl label namespace teleport --overwrite \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=baseline
```

---

## 2 — OpenShift SCC permissions

Teleport runs as UID 9999, outside OpenShift's default restricted UID range:

```bash
oc adm policy add-scc-to-user anyuid \
  system:serviceaccount:teleport:teleport-cluster \
  -n teleport

oc adm policy add-scc-to-user anyuid \
  system:serviceaccount:teleport:teleport-cluster-proxy \
  -n teleport
```

If pods show `CreateContainerConfigError` after install, re-run these then:
```bash
kubectl rollout restart deployment -n teleport
```

---

## 3 — TLS certificate

### Option A — Self-signed (no public DNS / air-gapped)

Run as one block — `$CLUSTER_NAME` must be exported from Step 0:

```bash
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 1825 -key ca.key -out ca.crt \
  -subj "/CN=Teleport CA/O=Demo Org"

openssl genrsa -out server.key 4096
openssl req -new -key server.key -out server.csr \
  -subj "/CN=${CLUSTER_NAME}/O=Demo Org"

cat > server.ext <<EOF
[SAN]
subjectAltName=DNS:${CLUSTER_NAME},DNS:*.${CLUSTER_NAME},IP:127.0.0.1
EOF

openssl x509 -req -days 825 -in server.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -extfile server.ext -extensions SAN

openssl x509 -noout -text -in server.crt | grep -A2 "Subject Alternative"
```

Expected output:
```
X509v3 Subject Alternative Name:
    DNS:teleport.apps.ocp.example.com, DNS:*.teleport.apps.ocp.example.com, IP Address:127.0.0.1
```

Then continue to Step 4A.

### Option B — CA-signed cert (public CA or corporate PKI)

Full guide: [`../ssl-certificates.md`](../ssl-certificates.md) — CSR
generation, finding and verifying the intermediates, obtaining the root,
and proving the chain end-to-end. Follow it with `CLUSTER_NAME` as the
certificate name; you end up with two files:

- `chain.crt` — your leaf cert followed by the intermediates (root omitted)
- `teleport.example.com.key` — the private key from the CSR step (named
  after your cluster name)

Prove the chain before it goes in the cluster:

```bash
openssl verify -CAfile root.crt -untrusted intermediates.crt teleport_example_com.crt
# → teleport_example_com.crt: OK
```

The cert must have `${CLUSTER_NAME}` in its SAN. No self-signed CA is needed.

> **Private/corporate PKI:** two extra requirements beyond the chain:
>
> 1. **The pods must trust your CA.** The Proxy Service verifies its own
>    cert chain against the container's trust store at startup and
>    crash-loops if the root isn't there (`unable to verify HTTPS
>    certificate chain` … `x509: certificate signed by unknown authority`) —
>    and a corporate root never is. Create the CA secret in Step 4B and
>    uncomment `existingCASecretName` in `values-trusted.yaml`.
> 2. **Clients must trust your CA too** — the corporate root in the OS
>    trust store of every workstation (browser/tsh) and every node you
>    enroll (see [install-ssh-nodes.md](install-ssh-nodes.md)). On
>    corporate-managed devices it usually already is. Verify from a client:
>    `curl https://${CLUSTER_NAME}/webapi/ping` (no `-k`).
>
> Also make sure the issuing/intermediate CA certs are included in
> `chain.crt` after the leaf; a leaf-only secret fails on clients even when
> the root is trusted.

---

## 4 — Kubernetes secrets

### Step 4A — Self-signed cert

Two secrets: one for the server cert/key pair, one for the CA. Use
`values-self-signed.yaml` in Step 5.

```bash
cat server.crt ca.crt > chain.crt

kubectl create secret tls teleport-tls \
  --cert=chain.crt --key=server.key \
  -n teleport

kubectl create secret generic teleport-tls-ca \
  --from-file=ca.pem=ca.crt \
  -n teleport

kubectl create secret generic license \
  --from-file=license.pem=../license.pem \
  -n teleport
```

### Step 4B — CA-signed cert

Standard TLS secret — no CA secret needed. Use `values-trusted.yaml` in Step 5.

```bash
kubectl create secret tls teleport-tls \
  --cert=chain.crt --key=teleport.example.com.key \
  -n teleport
# --key is the private key from the CSR step of ../ssl-certificates.md —
# yours is named after your cluster name

kubectl create secret generic license \
  --from-file=license.pem=../license.pem \
  -n teleport

# PRIVATE/CORPORATE PKI ONLY — the pods must trust your CA (see the note
# in Step 3B). Also uncomment existingCASecretName in values-trusted.yaml.
kubectl create secret generic teleport-tls-ca \
  --from-file=ca.pem=corporate-root-ca.crt \
  -n teleport
```

---

## 5 — Configure and install

Set `VALUES_FILE` to match the cert path you took in Steps 3–4:

```bash
# Self-signed cert (Step 3A/4A):
export VALUES_FILE=values-self-signed.yaml

# CA-signed cert (Step 3B/4B):
export VALUES_FILE=values-trusted.yaml
```

Replace placeholders (`KUBE_CLUSTER_NAME` must be replaced first — the
token `CLUSTER_NAME` is a substring of the token `KUBE_CLUSTER_NAME`, so
running the replacements in the other order would mangle it):

```bash
sed -i.bak \
  -e "s/KUBE_CLUSTER_NAME/${KUBE_CLUSTER_NAME}/g" \
  -e "s/CLUSTER_NAME/${CLUSTER_NAME}/g" \
  ${VALUES_FILE} && rm ${VALUES_FILE}.bak
```

Install:

```bash
helm install teleport-cluster teleport/teleport-cluster \
  --namespace teleport \
  --version 18.10.1 \
  --values ${VALUES_FILE} \
  --wait --timeout 5m
```

Verify both pods are running:

```bash
kubectl get pods -n teleport
# teleport-cluster-auth-xxx    1/1   Running
# teleport-cluster-proxy-xxx   1/1   Running
```

> **Keep `proxyListenerMode: multiplex` at the chart level** (both values
> files already do). It configures three things at once: the auth service's
> `proxy_listener_mode`, the proxy pod's own listeners, and the proxy
> Service ports. Hand-placing `proxy_listener_mode` inside
> `auth.teleportConfig` instead leaves the proxy half-configured in
> `separate` mode (the chart default).

---

## 6 — Create the OpenShift Route

Apply the passthrough Route (no TLS termination at HAProxy — raw TCP
forwarded to Teleport):

```bash
sed "s/CLUSTER_NAME/${CLUSTER_NAME}/g" route-passthrough.yaml | oc apply -f -
```

Verify the Route was admitted and DNS resolves:

```bash
oc get route teleport -n teleport
curl -k https://${CLUSTER_NAME}/webapi/ping | jq .server_version
```

(`-k` skips TLS verification for the self-signed cert. To avoid needing `-k`
on every check, import `ca.crt` into your system trust store — see
Troubleshooting.)

Test the WebSocket connection upgrade (Teleport's L7-proxy detection path):

```bash
curl -k --no-alpn -i \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  https://${CLUSTER_NAME}/webapi/connectionupgrade
# Expect: HTTP/1.1 101 Switching Protocols
```

---

## 7 — First admin user

```bash
kubectl exec -n teleport deployment/teleport-cluster-auth -- \
  tctl users add admin --roles=editor,access,auditor
```

Open the printed invite URL in a browser, then log in:

**Self-signed cert (Step 3A/4A):**
```bash
TELEPORT_TLS_ROUTING_CONN_UPGRADE=true \
  tsh login --proxy=${CLUSTER_NAME}:443 --user=admin --insecure
```

**CA-signed cert (Step 3B/4B):**
```bash
tsh login --proxy=${CLUSTER_NAME}:443 --user=admin
```

> **Why self-signed requires both flags:** `--insecure` is needed because the
> cert isn't publicly trusted. However, `--insecure` causes tsh to take a
> code path where the server does not select ALPN for the post-auth gRPC
> channel, so `tsh login --insecure` alone fails with
> `"missing selected ALPN property"`. `TELEPORT_TLS_ROUTING_CONN_UPGRADE=true`
> sidesteps this by tunneling the gRPC connection over WebSocket
> (`/webapi/connectionupgrade`) instead of relying on ALPN negotiation.
>
> **Why a CA-signed cert needs no flags:** After the initial HTTPS login, tsh
> downloads Teleport's internal host CA. Subsequent gRPC connections use that
> host CA — not the system trust store — to verify Teleport's internal
> service cert for `teleport.cluster.local`. This works regardless of what
> external cert you provided, as long as `--insecure` is not set.

---

## Upgrading

```bash
helm repo update
helm upgrade teleport-cluster teleport/teleport-cluster \
  --namespace teleport \
  --version <new-version> \
  --values values-self-signed.yaml   # or values-trusted.yaml
```

Teleport supports one minor version at a time (18.x → 19.x, not 18.x → 20.x).

---

## Uninstalling

```bash
helm uninstall teleport-cluster -n teleport
oc delete route teleport -n teleport
kubectl delete namespace teleport
```

Deletes the PVC and all cluster data — not recoverable.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Pods `Pending` / `CreateContainerConfigError` | Re-run Step 2 SCC commands, then `kubectl rollout restart deployment -n teleport` |
| `certificate signed by unknown authority` in browser/tsh | Import `ca.crt` (or the corporate root) into the OS trust store, or use `tsh login --insecure` for testing |
| Proxy pods CrashLoopBackOff: `unable to verify HTTPS certificate chain in /etc/teleport-tls/tls.crt` | The proxy verifies its own cert chain against the **container's** trust store at startup and exits on failure. Private/corporate PKI → create the `teleport-tls-ca` secret (Step 4B) and set `existingCASecretName` in the values. Public CA whose root is newer than the image's bundle → append the CA's **cross-signed root** to `chain.crt` and recreate the secret (see [`../ssl-certificates.md`](../ssl-certificates.md), crashloop note) |
| `transport: authentication handshake failed: context deadline exceeded` on `tsh login` | The HTTPS phase works but the ALPN-routed gRPC connection can't complete — something between tsh and Teleport is terminating TLS. Check, in order: (1) the Route is `termination: passthrough` (not edge/reencrypt): `oc get route teleport -n teleport -o jsonpath='{.spec.tls.termination}'`; (2) multiplex took effect: `curl -sk https://${CLUSTER_NAME}/webapi/ping \| jq .proxy.tls_routing_enabled` must be `true`; (3) the cert the client sees is the one in the secret — compare `openssl s_client` and secret fingerprints (see [`../ssl-certificates.md`](../ssl-certificates.md) Step 8). Differing fingerprints = a TLS-inspecting middlebox or edge-terminating hop; try `TELEPORT_TLS_ROUTING_CONN_UPGRADE=true tsh login ...` to confirm and work around |
| `missing selected ALPN property` after password+OTP (with `--insecure`) | `--insecure` causes a code path where the server does not select ALPN for the post-auth gRPC channel. Use `TELEPORT_TLS_ROUTING_CONN_UPGRADE=true tsh login ... --insecure` — the WebSocket upgrade bypasses ALPN negotiation entirely |
| `missing selected ALPN property` after password+OTP (without `--insecure`) | `clusterName` doesn't match the Route hostname — reinstall required. Ensure `clusterName`, `public_addr`, `rp_id`, and the Route `host` all use the same FQDN |
| cert error on `teleport.cluster.local` after importing self-signed CA | CA import only helps with the external cert. tsh's post-auth gRPC channel uses Teleport's internal host CA (downloaded during login), which is separate from your self-signed CA. CA import cannot substitute for a CA-signed cert. Use `TELEPORT_TLS_ROUTING_CONN_UPGRADE=true --insecure` for self-signed setups |
| `webauthn rp_id mismatch` | `rp_id` in the values file must equal the hostname in the browser URL (i.e. `clusterName`) |
| Route admitted but `curl` times out | SCC permissions may be wrong — check pods are `Running` and not `CreateContainerConfigError` |
| Cluster state gone after a pod restart | `persistence.enabled` must be `true` (both values files here set it, with a 10Gi PVC). With SQLite standalone, disabling persistence means every auth pod restart wipes users, CAs, and all issued certs |
| `tctl` access from local machine | `export KUBECONFIG=<path>; kubectl exec -n teleport deployment/teleport-cluster-auth -- tctl <cmd>` |

---

## Enrolling SSH nodes

See [install-ssh-nodes.md](install-ssh-nodes.md) for enrolling Linux nodes
into this cluster. For nodes connecting through a self-signed or corporate
PKI cert, distribute the CA cert and add it to the system trust store on
each node before starting the Teleport service.
