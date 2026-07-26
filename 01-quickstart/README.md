# 01 — Quickstart: Teleport Enterprise, non-HA

The absolute minimum self-hosted Teleport Enterprise: one Helm release,
**no databases anywhere**. Perfect for a first install, a POC, or
understanding what Teleport needs before adding real backends.

```
 browser / tsh
      │ https (trusts the demo CA)
      ▼
 teleport.demo.test:443 ──► proxy pods ──► auth pod ──► PVC
 (/etc/hosts → 127.0.0.1)                              (SQLite state +
                                                        session recordings)
```

Want Identity Security (Access Graph) or HA-capable storage? That's
[`../02-identity-security/`](../02-identity-security/) — Access Graph requires
PostgreSQL, so it lives with the other databases.

**Before you start:** the [root README's one-time setup](../README.md#one-time-setup)
(license, k3s, certs, hosts entry, CA trust), then from this directory:

```bash
export KUBECONFIG="$(cd .. && pwd)/k3s/kubeconfig/kubeconfig.yaml"
kubectl get nodes    # sanity check: one node, STATUS Ready
```

## 1. Namespace, license, and TLS secrets

```bash
kubectl create namespace teleport
kubectl label namespace teleport --overwrite \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=baseline

# Enterprise license (file key must be exactly license.pem)
kubectl -n teleport create secret generic license \
  --from-file=license.pem=../license.pem

# Proxy certificate (chain + key) and the demo CA
kubectl -n teleport create secret tls teleport-tls \
  --cert=../demo-pki/out/teleport-chain.crt --key=../demo-pki/out/teleport.key
kubectl -n teleport create secret generic teleport-tls-ca \
  --from-file=ca.pem=../demo-pki/out/ca.crt
```

## 2. Install Teleport

Every setting is explained in [`teleport-cluster-values.yaml`](teleport-cluster-values.yaml).

```bash
helm repo add teleport https://charts.releases.teleport.dev
helm repo update

helm install teleport-cluster teleport/teleport-cluster \
  --namespace teleport \
  --version 18.10.1 \
  --values teleport-cluster-values.yaml \
  --wait --timeout 10m
```

Verify — one auth pod, two proxy pods (expected — see the values file), and
Teleport answering over your cert:

```bash
kubectl -n teleport get pods
curl --cacert ../demo-pki/out/ca.crt https://teleport.demo.test/webapi/ping
```

## 3. First login

```bash
kubectl -n teleport exec deploy/teleport-cluster-auth -- \
  tctl users add admin --roles=editor,access,auditor
```

Open the printed `https://teleport.demo.test:443/web/invite/...` link, set a
password + passkey, and you're in — no certificate warning, because your
machine trusts the demo CA. Then from a terminal:

```bash
tsh login --proxy=teleport.demo.test:443 --user=admin
tsh status
```

## Where everything lives

```bash
kubectl -n teleport get pvc    # SQLite backend + session recordings,
                               # mounted at /var/lib/teleport in the auth pod
```

That PVC **is** the cluster: back it up and you've backed up Teleport.
It's also why `highAvailability.replicaCount` must stay 1 here — a file
backend can't be shared between pods.

## Teardown

```bash
helm -n teleport uninstall teleport-cluster
kubectl delete namespace teleport   # takes a minute — volume finalizers drain
# or nuke the whole cluster: cd ../k3s && docker compose down -v
```
