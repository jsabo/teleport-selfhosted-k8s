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
# The auth service's SNI is the hex-encoded cluster name (see Step 6).
# Hex doubles the length and DNS labels cap at 63 chars, so names longer
# than 31 chars need the wildcard auth route variant in Step 6:
export CLUSTER_NAME_HEX=$(printf '%s' "$CLUSTER_NAME" | xxd -p | tr -d '\n')
[ ${#CLUSTER_NAME} -le 31 ] && echo "exact auth route OK" \
  || echo "name > 31 chars: use route-auth-sni-wildcard.yaml in Step 6"
echo $CLUSTER_NAME        # e.g. teleport.apps.ocp.example.com
echo $KUBE_CLUSTER_NAME   # e.g. ocp
echo $CLUSTER_NAME_HEX    # e.g. 74656c65706f72742e617070732e6f63702e6578616d706c652e636f6d
```

**Option 2 — any public DNS name you control** (e.g. `teleport.example.com`,
independent of the domain OpenShift was installed with). The router matches
passthrough Routes by SNI, so any hostname works as long as it resolves to
the router:

```bash
export CLUSTER_NAME="teleport.example.com"
export KUBE_CLUSTER_NAME=$(oc get infrastructure/cluster -o jsonpath='{.status.infrastructureName}')
# The auth service's SNI is the hex-encoded cluster name (see Step 6).
# Hex doubles the length and DNS labels cap at 63 chars, so names longer
# than 31 chars need the wildcard auth route variant in Step 6:
export CLUSTER_NAME_HEX=$(printf '%s' "$CLUSTER_NAME" | xxd -p | tr -d '\n')
[ ${#CLUSTER_NAME} -le 31 ] && echo "exact auth route OK" \
  || echo "name > 31 chars: use route-auth-sni-wildcard.yaml in Step 6"

# Find the router's load balancer address, then create a CNAME to it
# in YOUR domain's DNS zone:   teleport.example.com → <router LB hostname>
oc -n openshift-ingress get svc router-default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

> **Custom-domain notes:**
> - The OpenShift install's base domain is irrelevant here — it only
>   constrained what the *installer* could create in Route53. Routes can
>   serve any hostname.
> - **Application Access is optional — Step 8.** Apps are served at
>   `<app>.${CLUSTER_NAME}`, which additionally needs a wildcard DNS record,
>   a wildcard Route, and an IngressController setting; the wildcard cert
>   SAN is already included by every cert path here. Everything else in
>   this guide (web UI, ssh, kube, db) works without Step 8.

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

Three paths. Pick one and stay on it — each has a matching Step 4 and its
own values file in Step 5:

| Path | Your certificate comes from | Step 4 | Values file |
|---|---|---|---|
| **Option A** | Self-signed (demo CA generated below) | 4A | `values-self-signed.yaml` |
| **Option B** | A publicly trusted CA (purchased, Let's Encrypt, …) | 4B | `values-public-ca.yaml` |
| **Option C** | Your private/corporate PKI | 4C | `values-corporate-pki.yaml` |

### Option A — Self-signed (demo CA; no public DNS / air-gapped)

The CSR here has the same shape as the real-CA paths in
[`../ssl-certificates.md`](../ssl-certificates.md) — wildcard CN, both SANs
— so all three options read identically. (The CN itself only matters to
public-CA order forms; for self-signed it's cosmetic.)

Run as one block — `$CLUSTER_NAME` must be exported from Step 0. Note the
heredoc uses an *unquoted* `EOF` so `${CLUSTER_NAME}` expands:

```bash
# The demo CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 1825 -key ca.key -out ca.crt \
  -subj "/CN=Teleport CA/O=Demo Org"

# Key + CSR — one config file carries the SANs for both the CSR and signing
cat > teleport-csr.cnf <<EOF
[req]
distinguished_name = dn
req_extensions     = req_ext
prompt             = no

[dn]
CN = *.${CLUSTER_NAME}

[req_ext]
subjectAltName = DNS:*.${CLUSTER_NAME}, DNS:${CLUSTER_NAME}
EOF

openssl req -new -newkey rsa:2048 -nodes \
  -keyout server.key -out server.csr \
  -config teleport-csr.cnf

# Sign with the demo CA, reusing the same config file's SAN section
openssl x509 -req -days 825 -in server.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -extfile teleport-csr.cnf -extensions req_ext

openssl x509 -noout -ext subjectAltName -in server.crt
```

Expected output:
```
X509v3 Subject Alternative Name:
    DNS:*.teleport.apps.ocp.example.com, DNS:teleport.apps.ocp.example.com
```

> Self-signed is the one path where the CA cert rides along inside
> `chain.crt` (Step 4A) — there is no public root for clients to find, so
> the chain carries its own. The other paths omit the root.

Then continue to **Step 4A**.

### Option B — Publicly trusted CA

Full guide: [`../ssl-certificates.md`](../ssl-certificates.md) — CSR
generation, finding and verifying the intermediates, obtaining the root,
and proving the chain end-to-end. Follow it with `CLUSTER_NAME` as the
certificate name; you end up with two files:

- `chain.crt` — your leaf cert followed by the intermediates (root omitted)
- `teleport.example.com.key` — the private key from the CSR step (named
  after your cluster name)

Prove the chain before it goes in the cluster — **against the Teleport
image's own trust bundle, not just your laptop's**. The proxy verifies its
configured chain against the *container's* CA bundle at startup and
crash-loops if it can't; a recently established public root (e.g. SSL.com's
2022 roots) can be trusted by your OS but missing from the image:

```bash
# Extract the trust bundle actually inside the image you'll deploy:
CID=$(docker create public.ecr.aws/gravitational/teleport-ent-distroless:18.10.1)
docker cp $CID:/etc/ssl/certs/ca-certificates.crt image-ca-bundle.crt
docker rm $CID

openssl verify -CAfile image-ca-bundle.crt -untrusted intermediates.crt teleport_example_com.crt
# → teleport_example_com.crt: OK
```

If that fails with `unable to get local issuer certificate`, your CA's root
is newer than the image's bundle: fetch the CA's **cross-signed root** from
their repository and append it to `chain.crt` (leaf → intermediates →
cross-signed root). Details: the crashloop note in
[`../ssl-certificates.md`](../ssl-certificates.md).

The cert must have `${CLUSTER_NAME}` in its SAN. No CA secret is needed on
this path. Continue to **Step 4B**.

### Option C — Private/corporate PKI

Same chain mechanics as Option B — submit a CSR to your PKI team (Path B in
[`../ssl-certificates.md`](../ssl-certificates.md)), get back the leaf and
the issuing chain, assemble `chain.crt` (leaf, then intermediates), verify
with `openssl verify -CAfile corporate-root-ca.crt -untrusted
intermediates.crt <leaf>`. The cert must have `${CLUSTER_NAME}` in its SAN,
and the intermediates must be in `chain.crt` — a leaf-only secret fails on
clients even when the root is trusted.

What's different from Option B is **trust — in both directions**:

1. **The Teleport pods must trust your CA.** The Proxy Service verifies its
   own cert chain against the container's trust store at startup and
   crash-loops if the issuing root isn't there (`unable to verify HTTPS
   certificate chain` … `x509: certificate signed by unknown authority`) —
   and a corporate root never is. Step 4C builds the CA secret that fixes
   this, and `values-corporate-pki.yaml` mounts it.
2. **Clients must trust your CA too** — the corporate root in the OS trust
   store of every workstation (browser/tsh) and every node you enroll (see
   [install-ssh-nodes.md](install-ssh-nodes.md)). On corporate-managed
   devices it usually already is. Verify from a client after Step 6:
   `curl https://${CLUSTER_NAME}/webapi/ping` (no `-k`).

Continue to **Step 4C**.

---

## 4 — Kubernetes secrets

### Step 4A — Self-signed (Option A)

Two TLS-related secrets: the server cert/key pair, and the demo CA.

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

### Step 4B — Publicly trusted CA (Option B)

Standard TLS secret — no CA secret on this path.

```bash
kubectl create secret tls teleport-tls \
  --cert=chain.crt --key=teleport.example.com.key \
  -n teleport
# --key is the private key from the CSR step of ../ssl-certificates.md —
# yours is named after your cluster name

kubectl create secret generic license \
  --from-file=license.pem=../license.pem \
  -n teleport
```

### Step 4C — Private/corporate PKI (Option C)

Three secrets: the TLS pair, the license, and the CA bundle the pods will
trust. Build the CA bundle as **the image's own trust bundle + your
corporate root** — not the root alone:

```bash
kubectl create secret tls teleport-tls \
  --cert=chain.crt --key=<your-private-key>.key \
  -n teleport

kubectl create secret generic license \
  --from-file=license.pem=../license.pem \
  -n teleport

# Build the CA bundle. The values file sets SSL_CERT_FILE, which REPLACES
# the container's default Mozilla bundle for ALL of Teleport's TLS — inbound
# verification AND outbound calls. Root-only would boot the proxy but break
# every future outbound connection to public endpoints (Okta/Entra SSO,
# webhooks, plugins). Appending your root to the image's own bundle keeps
# both working:
CID=$(docker create public.ecr.aws/gravitational/teleport-ent-distroless:18.10.1)
docker cp $CID:/etc/ssl/certs/ca-certificates.crt image-ca-bundle.crt
docker rm $CID

cat image-ca-bundle.crt corporate-root-ca.crt > ca.pem

kubectl create secret generic teleport-tls-ca \
  --from-file=ca.pem=ca.pem \
  -n teleport
```

> The bundle comes from the image, so **rebuild this secret whenever you
> upgrade Teleport** (extract from the new image tag, re-append your root,
> recreate the secret, restart the pods).

---

## 5 — Configure and install

Set `VALUES_FILE` to match the option you took in Steps 3–4 — each file is
complete for its path; nothing needs editing beyond the placeholders:

```bash
# Option A — self-signed demo CA:
export VALUES_FILE=values-self-signed.yaml

# Option B — publicly trusted CA:
export VALUES_FILE=values-public-ca.yaml

# Option C — private/corporate PKI (mounts the Step 4C CA bundle):
export VALUES_FILE=values-corporate-pki.yaml
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

> **Keep `proxyListenerMode: multiplex` at the chart level** (all three
> values files already do). It configures three things at once: the auth service's
> `proxy_listener_mode`, the proxy pod's own listeners, and the proxy
> Service ports. Hand-placing `proxy_listener_mode` inside
> `auth.teleportConfig` instead leaves the proxy half-configured in
> `separate` mode (the chart default).

---

## 6 — Create the OpenShift Routes

The router matches passthrough traffic **by SNI**, and Teleport announces
three different SNI names over port 443 — so Teleport needs **three**
passthrough Routes, all pointing at the same Service:

| SNI the client sends | Used by | Cert Teleport presents | Client verifies against |
|---|---|---|---|
| `${CLUSTER_NAME}` | web UI, tsh ssh/db, agent joins | **Your cert** (Step 3) | OS trust store |
| `${CLUSTER_NAME_HEX}.teleport.cluster.local` | auth gRPC — `tsh login`, `tctl` | Teleport's internal cert (`*.teleport.cluster.local`) | Host CA tsh downloads at login |
| `kube-teleport-proxy-alpn.${CLUSTER_NAME}` | Kubernetes access | Teleport's internal cert (it auto-adds `*.${CLUSTER_NAME}` to its own cert for exactly this) | Teleport CA pinned in the kubeconfig |

Two useful consequences of that last column: the Routes only carry *names*
— for the auth and kube SNIs, the certificate that answers is Teleport's
own, so **your cert never needs to cover them**; and the only client that
ever verifies a `*.${CLUSTER_NAME}` name against *your* cert is a browser
opening an app URL (Step 8).

(The hex encoding is deliberate on Teleport's part — it hides the dots so
the whole cluster name fits in **one label** under `teleport.cluster.local`,
which is what lets wildcards like Teleport's own internal
`*.teleport.cluster.local` certificate match it. The extra names need
**no DNS records**: clients always dial `${CLUSTER_NAME}`; these names
travel only inside the TLS handshake, which is what HAProxy routes on.)

> **Cluster name longer than 31 characters?** The hex label then exceeds
> DNS's 63-character limit and the exact `teleport-auth-sni` Route is
> rejected (`spec.host ... must be no more than 63 characters`) — the other
> two Routes still apply fine. Use the wildcard variant instead: allow
> wildcard routes on the IngressController (the Step 8b patch), then
> `oc apply -f route-auth-sni-wildcard.yaml` — it serves
> `*.teleport.cluster.local`, matching the hex label at any length. Use one
> auth route or the other, not both.

> **Restrictive networks: the auth SNI may be dropped before it reaches the
> router.** `teleport.cluster.local` is intentionally not DNS-resolvable —
> it's an SNI-only routing label — and SNI-filtering middleware (next-gen
> firewalls, F5s doing SNI-based pool selection) may silently drop TLS for
> domains it doesn't recognize. The tell: `tsh login` times out *after*
> password+MFA (`context deadline exceeded`, not a certificate error), and
> the Step 6 `openssl -servername <hex>.teleport.cluster.local` check
> **hangs**, while the same command with any name under your real domain
> answers instantly. Fixes: have the network team permit TLS to the
> router's address with SNI `*.teleport.cluster.local` (the clean fix — no
> client changes), or set `TELEPORT_TLS_ROUTING_CONN_UPGRADE=true` on
> clients as an interim (tunnels the auth channel over WebSocket using the
> normal, permitted hostname).

Apply all three (order of the `sed` expressions matters —
`CLUSTER_NAME_HEX` first, since `CLUSTER_NAME` is a substring of it):

```bash
sed -e "s/CLUSTER_NAME_HEX/${CLUSTER_NAME_HEX}/g" \
    -e "s/CLUSTER_NAME/${CLUSTER_NAME}/g" \
    route-passthrough.yaml | oc apply -f -
```

Verify all three Routes were admitted, DNS resolves, and the auth SNI
reaches Teleport (not the router's default certificate):

```bash
oc get routes -n teleport
# teleport, teleport-auth-sni, teleport-kube-sni — all passthrough/None

curl -k https://${CLUSTER_NAME}/webapi/ping | jq .server_version

# The auth SNI must be answered by Teleport's internal cert — if this shows
# the router's *.apps... certificate instead, the teleport-auth-sni Route
# isn't matching and tsh login will fail after password+MFA:
openssl s_client -connect ${CLUSTER_NAME}:443 \
  -servername ${CLUSTER_NAME_HEX}.teleport.cluster.local </dev/null 2>/dev/null \
  | openssl x509 -noout -subject
# expect a Teleport-issued cert (CN=<cluster name>), NOT *.apps...
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
# --kubernetes-groups fills the {{internal.kubernetes_groups}} trait the
# preset access role uses — without it, kubectl through Teleport is denied
# with "Your user's Teleport role does not allow Kubernetes access".
kubectl exec -n teleport deployment/teleport-cluster-auth -- \
  tctl users add admin --roles=editor,access,auditor \
  --kubernetes-groups=system:masters
```

Open the printed invite URL in a browser, then log in:

**Option A (self-signed):**
```bash
TELEPORT_TLS_ROUTING_CONN_UPGRADE=true \
  tsh login --proxy=${CLUSTER_NAME}:443 --user=admin --insecure
```

**Option B or C (CA-issued cert, trusted by this machine):**
```bash
tsh login --proxy=${CLUSTER_NAME}:443 --user=admin
```

> Flag-free login depends on the `teleport-auth-sni` Route from Step 6 —
> without it, login fails *after* password+MFA with a certificate error
> naming `<hex>.teleport.cluster.local` (see Troubleshooting).

The chart registers the OpenShift cluster itself as a Kubernetes resource,
so you can immediately test Kubernetes access (this also exercises the
`teleport-kube-sni` Route from Step 6):

```bash
tsh kube ls
tsh kube login KUBE_CLUSTER_NAME
kubectl get pods -n teleport   # now routed through Teleport
```

> `tsh kube login` switches your default kubectl context to Teleport. To go
> back to direct cluster-admin access, switch contexts
> (`kubectl config get-contexts`) or use `oc` with your admin kubeconfig.

> **Why Option A requires both flags:** `--insecure` is needed because the
> cert isn't trusted by the client. However, `--insecure` causes tsh to take
> a code path where the server does not select ALPN for the post-auth gRPC
> channel, so `tsh login --insecure` alone fails with
> `"missing selected ALPN property"`. `TELEPORT_TLS_ROUTING_CONN_UPGRADE=true`
> sidesteps this by tunneling the gRPC connection over WebSocket
> (`/webapi/connectionupgrade`) instead of relying on ALPN negotiation.
>
> **Why Options B and C need no flags:** After the initial HTTPS login, tsh
> downloads Teleport's internal host CA. Subsequent gRPC connections use that
> host CA — not the system trust store — to verify Teleport's internal
> service cert for `teleport.cluster.local`. This works regardless of what
> external cert you provided, as long as `--insecure` is not set. (Option C
> only needs the corporate root in the client's OS trust store for the
> *initial* HTTPS connection — standard on corporate-managed machines.)

---

## 8 — Application Access routing (optional)

Teleport serves every registered application at `<app>.${CLUSTER_NAME}`.
This step sets up everything OpenShift-side that App Access needs — the
wildcard DNS, router admission, and the wildcard Route. Registering apps
themselves is out of scope here: apps run on an **app agent** (e.g. the
`teleport-kube-agent` chart with `roles: app`), not on the
`teleport-cluster` chart — enable app agents later and their apps work
immediately through the routing laid down now. Three pieces:

**8a — Wildcard DNS.** `*.${CLUSTER_NAME}` must resolve to the router:

- Custom domain (Step 0 Option 2): add `*.teleport.example.com` → CNAME →
  the same router LB hostname as your main record.
- Apps-domain name (Step 0 Option 1): already covered — the cluster's
  existing `*.apps...` wildcard record matches `<app>.teleport.apps...`.

**8b — Allow wildcard routes.** The default IngressController rejects
them. This is a cluster-wide router setting — clear it with your cluster
admin:

```bash
oc patch ingresscontroller/default -n openshift-ingress-operator \
  --type=merge -p '{"spec":{"routeAdmission":{"wildcardPolicy":"WildcardsAllowed"}}}'
```

**8c — Apply the wildcard Route** (separate file, since it's rejected on
unpatched clusters):

```bash
sed "s/CLUSTER_NAME/${CLUSTER_NAME}/g" route-apps-wildcard.yaml | oc apply -f -

# Verify it was ADMITTED — "RouteNotAdmitted" here means 8b didn't land:
oc get route teleport-apps-wildcard -n teleport \
  -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}{"\n"}'
# expect: True

# Any app subdomain must now reach Teleport (its cert, not the router's):
openssl s_client -connect ${CLUSTER_NAME}:443 \
  -servername myapp.${CLUSTER_NAME} </dev/null 2>/dev/null \
  | openssl x509 -noout -subject
```

That `openssl` check is the full proof of this step — any single-label
subdomain now reaches Teleport with a valid cert. When you later deploy an
app agent and register applications, they're served at
`https://<app>.${CLUSTER_NAME}` through this routing with no further
OpenShift changes.

---

## Upgrading

```bash
helm repo update
helm upgrade teleport-cluster teleport/teleport-cluster \
  --namespace teleport \
  --version <new-version> \
  --values ${VALUES_FILE}   # the same file you installed with
```

Teleport supports one minor version at a time (18.x → 19.x, not 18.x → 20.x).

> **Option C:** also rebuild the `teleport-tls-ca` secret from the *new*
> image's trust bundle before upgrading (Step 4C), then restart the pods.

---

## Uninstalling

```bash
helm uninstall teleport-cluster -n teleport
oc delete route teleport teleport-auth-sni teleport-kube-sni -n teleport
oc delete route teleport-apps-wildcard -n teleport --ignore-not-found   # if you did Step 8
kubectl delete namespace teleport
```

Deletes the PVC and all cluster data — not recoverable. The Step 8b
IngressController setting persists; revert it if nothing else needs
wildcard routes:

```bash
oc patch ingresscontroller/default -n openshift-ingress-operator \
  --type=merge -p '{"spec":{"routeAdmission":{"wildcardPolicy":"WildcardsDisallowed"}}}'
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Pods `Pending` / `CreateContainerConfigError` | Re-run Step 2 SCC commands, then `kubectl rollout restart deployment -n teleport` |
| `certificate signed by unknown authority` in browser/tsh | Import `ca.crt` (or the corporate root) into the OS trust store, or use `tsh login --insecure` for testing |
| Proxy pods CrashLoopBackOff: `unable to verify HTTPS certificate chain in /etc/teleport-tls/tls.crt` | The proxy verifies its own cert chain against the **container's** trust store at startup and exits on failure. Option C → create the `teleport-tls-ca` secret (Step 4C) and install with `values-corporate-pki.yaml`. Option B with a root newer than the image's bundle → append the CA's **cross-signed root** to `chain.crt` and recreate the secret (the Option B pre-check catches this before install; see also [`../ssl-certificates.md`](../ssl-certificates.md), crashloop note) |
| Outbound TLS failures after Option C (SSO connector can't reach the IdP, webhooks/plugins fail with `certificate signed by unknown authority`) | The `teleport-tls-ca` secret replaced the container's Mozilla bundle with less than a full bundle. Rebuild it as **image bundle + corporate root** (Step 4C) and restart the pods |
| `transport: authentication handshake failed: context deadline exceeded` on `tsh login` | The HTTPS phase works but the ALPN-routed gRPC connection can't complete — something between tsh and Teleport is terminating TLS. Check, in order: (1) the Route is `termination: passthrough` (not edge/reencrypt): `oc get route teleport -n teleport -o jsonpath='{.spec.tls.termination}'`; (2) multiplex took effect: `curl -sk https://${CLUSTER_NAME}/webapi/ping \| jq .proxy.tls_routing_enabled` must be `true`; (3) the cert the client sees is the one in the secret — compare `openssl s_client` and secret fingerprints (see [`../ssl-certificates.md`](../ssl-certificates.md) Step 8). Differing fingerprints = a TLS-inspecting middlebox or edge-terminating hop; try `TELEPORT_TLS_ROUTING_CONN_UPGRADE=true tsh login ...` to confirm and work around |
| `missing selected ALPN property` after password+OTP (with `--insecure`) | `--insecure` causes a code path where the server does not select ALPN for the post-auth gRPC channel. Use `TELEPORT_TLS_ROUTING_CONN_UPGRADE=true tsh login ... --insecure` — the WebSocket upgrade bypasses ALPN negotiation entirely |
| `missing selected ALPN property` after password+OTP (without `--insecure`) | `clusterName` doesn't match the Route hostname — reinstall required. Ensure `clusterName`, `public_addr`, `rp_id`, and the Route `host` all use the same FQDN |
| cert error on `teleport.cluster.local` after importing self-signed CA | CA import only helps with the external cert. tsh's post-auth gRPC channel uses Teleport's internal host CA (downloaded during login), which is separate from your self-signed CA. CA import cannot substitute for a CA-issued cert (Options B/C). Use `TELEPORT_TLS_ROUTING_CONN_UPGRADE=true --insecure` for self-signed setups |
| `The Route "teleport-auth-sni" is invalid: spec.host ... must be no more than 63 characters` | Your cluster name is longer than 31 characters, so its hex label breaks the DNS label limit. Use the wildcard variant: `WildcardsAllowed` on the IngressController (Step 8b patch), then `oc apply -f route-auth-sni-wildcard.yaml` (see the long-name note in Step 6) |
| `tsh login` fails after password+MFA: `certificate is valid for *.apps.<cluster>.<domain>, not <hex>.teleport.cluster.local` | The `teleport-auth-sni` Route is missing or its host doesn't match `hex(clusterName)` — the router answered the auth connection with its default cert. Re-run Step 6 (all three Routes) and check with the `openssl s_client -servername` command there. The kube equivalent names `kube-teleport-proxy-alpn.<clusterName>` and means the `teleport-kube-sni` Route is missing |
| `tsh login` **times out** after password+MFA (`transport: authentication handshake failed: context deadline exceeded`) and the Step 6 auth-SNI `openssl` check *hangs* (an unmatched SNI would get the router's default cert instantly instead) | SNI-filtering middleware between clients and the router is silently dropping TLS with SNI under `teleport.cluster.local` (not DNS-resolvable, so "unknown domain" to such devices). Confirm by comparing against `-servername anything.<your-apps-domain>` (instant answer). Fix at the network: permit TLS to the router with SNI `*.teleport.cluster.local`; interim: `TELEPORT_TLS_ROUTING_CONN_UPGRADE=true` on clients — see the restrictive-networks note in Step 6 |
| `Your user's Teleport role does not allow Kubernetes access` | The user has no `kubernetes_groups` trait (the preset `access` role fills its groups from `{{internal.kubernetes_groups}}`). For an existing user: `tctl users update <user> --set-kubernetes-groups=system:masters`, then `tsh logout` + login again — traits only land in newly issued certs |
| Wildcard route not admitted (`RouteNotAdmitted` in status) | The IngressController still has `wildcardPolicy: WildcardsDisallowed` — run the Step 8b patch, then recreate the route (`oc delete route teleport-apps-wildcard -n teleport` and re-apply) |
| App URL (`<app>.<cluster-name>`) shows the router's default cert, a 503, or doesn't resolve | One of Step 8's three pieces is missing: wildcard DNS record (8a), `WildcardsAllowed` (8b), or the `teleport-apps-wildcard` Route (8c). The `openssl s_client -servername` check in 8c pinpoints which side |
| `webauthn rp_id mismatch` | `rp_id` in the values file must equal the hostname in the browser URL (i.e. `clusterName`) |
| Route admitted but `curl` times out | SCC permissions may be wrong — check pods are `Running` and not `CreateContainerConfigError` |
| Cluster state gone after a pod restart | `persistence.enabled` must be `true` (all three values files here set it, with a 10Gi PVC). With SQLite standalone, disabling persistence means every auth pod restart wipes users, CAs, and all issued certs |
| `tctl` access from local machine | `export KUBECONFIG=<path>; kubectl exec -n teleport deployment/teleport-cluster-auth -- tctl <cmd>` |

---

## Enrolling SSH nodes

See [install-ssh-nodes.md](install-ssh-nodes.md) for enrolling Linux nodes
into this cluster. For nodes connecting through a self-signed or corporate
PKI cert, distribute the CA cert and add it to the system trust store on
each node before starting the Teleport service.
