# Self-hosted Teleport Enterprise on Kubernetes, via Helm

Copy-paste walkthroughs for running **Teleport Enterprise** on Kubernetes
with the official Helm charts. Everything works on **any** Kubernetes —
vanilla, OpenShift, EKS/GKE/AKS; the local [k3s-in-Docker](k3s/) cluster used
by the local walkthroughs is just the easiest test bed, and nothing in the
values files depends on it.

## Pick your deployment

| Directory | What you get | Platform | Storage | ~Time |
|---|---|---|---|---|
| [`01-quickstart/`](01-quickstart/) | Zero Trust Access, one Helm release, **no databases** | Local k3s (this repo) | SQLite + files on a PVC (non-HA) | 15 min |
| [`02-identity-security/`](02-identity-security/) | Zero Trust Access **+ Identity Security** (Access Graph) | Local k3s (this repo) | PostgreSQL + MinIO (HA-capable) | 45 min |
| [`03-openshift/`](03-openshift/) | 01 on a real cluster — SCCs, passthrough Route, real DNS + certs | **Your OpenShift** cluster | SQLite + files on a PVC (non-HA) | 30 min + DNS/cert lead time |

Run 01 and 02 **one at a time** — both serve the proxy on port 443 of the
local cluster. 03 targets your own OpenShift cluster and skips the k3s setup
entirely.

Getting a real certificate (public CA or corporate PKI) — CSR, intermediates,
root, and full-chain verification: [`ssl-certificates.md`](ssl-certificates.md).

## The one rule that makes or breaks the install

> **The Teleport `clusterName`, the DNS name clients resolve, and the TLS
> certificate SANs must all be the same string.**

This repo uses `teleport.demo.test` everywhere. The name is **permanent** —
Teleport bakes it into its own CAs at first start; changing it later means
rebuilding the cluster. (`.test` is IANA-reserved, so a missing hosts entry
fails fast instead of hitting a real site.)

## One-time setup

Prerequisites: Docker, `kubectl`, `helm`, [`tsh`](https://goteleport.com/download/),
and a Teleport **Enterprise license** (with the Identity Security entitlement
for the Access Graph parts).

> **Heading straight to [`03-openshift/`](03-openshift/)?** You only need
> step 1 (the license). Steps 2–5 — the k3s cluster, demo PKI, hosts entry,
> and CA trust — exist for the local walkthroughs; 03 uses your real cluster,
> real DNS, and real certificates instead.

```bash
# 1. Your license, at the repo root (gitignored — never commit it)
cp /path/to/license.pem .

# 2. The local Kubernetes cluster
cd k3s && docker compose up -d
export KUBECONFIG="$(pwd)/kubeconfig/kubeconfig.yaml"
kubectl get nodes    # wait for STATUS Ready (~20s)
cd ..

# 3. The demo PKI: one CA, certs for the proxy and Access Graph
bash demo-pki/make-certs.sh

# 4. DNS: point the cluster name at the proxy. (Application Access hostnames
#    — e.g. grafana.teleport.demo.test — get added to this same line later;
#    hosts files can't wildcard, but the cert's *.SAN already covers them.)
echo "127.0.0.1 teleport.demo.test" | sudo tee -a /etc/hosts

# 5. Trust the demo CA — browser and tsh then work with no flags/warnings
#    macOS:
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain demo-pki/out/ca.crt
#    Linux: sudo cp demo-pki/out/ca.crt /usr/local/share/ca-certificates/teleport-demo.crt && sudo update-ca-certificates
```

**Now open [`01-quickstart/`](01-quickstart/), [`02-identity-security/`](02-identity-security/),
or [`03-openshift/`](03-openshift/) and follow it top to bottom.**

Managing the k3s cluster afterwards:

```bash
cd k3s
docker compose down        # stop, keep cluster state
docker compose down -v     # full reset — wipes the cluster
```

Reset (`down -v`, then `up -d`) when switching between 01 and 02. New
terminal? Re-run the `export KUBECONFIG` from step 2 — every README assumes it.

---

## Reference

### Why not ACME / Let's Encrypt?

The chart has `acme: true`, but Teleport's built-in ACME uses the
**TLS-ALPN-01** challenge: Let's Encrypt must reach your proxy on **public
port 443**. A laptop cluster can't satisfy that, so this repo brings its own
CA instead — which is also the honest demo of the clusterName/DNS/SAN rule.

For a real deployment with a real domain, use
[cert-manager with a DNS-01 solver](https://cert-manager.io/docs/configuration/acme/dns01/):
it proves domain ownership by publishing TXT records through your DNS
provider's API, needs zero inbound connectivity, and can issue the wildcard
cert. Point `tls.existingSecretName` at the resulting secret and you're done —
nothing else in the values files changes.

### Using a purchased certificate (Namecheap, GoDaddy, …)

A commercially purchased cert drops into this setup the same way — the values
files already read the cert from the `teleport-tls` secret. The full
walkthrough — generating the CSR, finding and verifying the intermediates,
obtaining the root, and proving the chain before it goes in the cluster — is
[`ssl-certificates.md`](ssl-certificates.md); the short version follows.

**Buy a wildcard cert** for your cluster name. Application Access serves every
app at a subdomain of the proxy (`grafana.teleport.example.com`), so the cert
needs SANs for **both** `teleport.example.com` and `*.teleport.example.com`.
Commercial wildcard certs normally include the base name automatically, but
verify before you buy. The one rule still applies: that name must also be the
Teleport `clusterName` and the DNS record clients resolve.

```bash
# 1. Build the full chain — leaf first, then the intermediate bundle the CA
#    sent alongside it (Namecheap calls it a .ca-bundle). Browsers won't trust
#    a bare leaf.
cat teleport_example_com.crt teleport_example_com.ca-bundle > chain.crt

# 2. Create the secret the values files already point at
kubectl create secret tls teleport-tls \
  --cert=chain.crt --key=teleport.example.com.key \
  -n teleport
```

Then in the values file, keep `acme: false` and `tls.existingSecretName:
teleport-tls`, but **delete the `existingCASecretName` line** (and skip
creating `teleport-tls-ca`) — a public CA is already trusted everywhere, and
when `existingCASecretName` is set, Teleport trusts *only* that bundle.

With a real cert you also skip the rest of the demo PKI: no `make-certs.sh`,
no trusting the demo CA (setup step 5), no `--insecure` fallback. Create a
real DNS record (plus a wildcard record for app access) instead of the
`/etc/hosts` entry.

One thing ACME gives you that a purchased cert doesn't: renewal. When you
reissue, rebuild `chain.crt`, recreate the `teleport-tls` secret, and run
`kubectl rollout restart deployment/teleport-cluster-proxy -n teleport` — the
proxy does not pick up a changed secret on its own.

### Can't (or don't want to) trust the CA?

The fallback for `tsh` is:

```bash
TELEPORT_TLS_ROUTING_CONN_UPGRADE=true tsh login --proxy=teleport.demo.test:443 --user=admin --insecure
```

`--insecure` alone is not enough — with TLS multiplexing, the post-auth
connection upgrade also has to be told to proceed, hence the env var.

### Running on something other than k3s

The values files contain nothing k3s-specific. What changes elsewhere:

- **Cloud (EKS/GKE/AKS)** — `service.type: LoadBalancer` gets a real load
  balancer; create a DNS record for its address instead of the hosts entry,
  and use cert-manager or a purchased cert (both above) instead of
  `make-certs.sh`.
- **OpenShift** — full walkthrough in [`03-openshift/`](03-openshift/):
  `anyuid` SCCs for the Teleport service accounts, a **passthrough Route**
  (Teleport must terminate its own TLS — edge/reencrypt breaks tsh), and
  real DNS + certificates instead of the demo PKI.
- **Any other on-prem cluster** — you only need *some* way to get TCP 443 to
  the proxy Service (MetalLB, ingress-nginx in ssl-passthrough mode, or a
  NodePort behind your own LB).

### Undoing the host changes

```bash
cd k3s && docker compose down -v

# macOS:
sudo sed -i '' '/teleport\.demo\.test/d' /etc/hosts
sudo security delete-certificate -c "Teleport Demo CA" /Library/Keychains/System.keychain

# Linux:
sudo sed -i '/teleport\.demo\.test/d' /etc/hosts
sudo rm /usr/local/share/ca-certificates/teleport-demo.crt && sudo update-ca-certificates --fresh
```
