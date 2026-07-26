# 02 — PostgreSQL + MinIO: real backends, HA-capable

The same Teleport Enterprise as [`../01-quickstart/`](../01-quickstart/), plus
**Identity Security (Access Graph)**, with all state moved out of the pods:

```
 browser / tsh
      │ https (trusts the demo CA)
      ▼
 teleport.demo.test:443 ──► proxy ──► auth ──┬──► PostgreSQL (CNPG)
 (/etc/hosts → 127.0.0.1)                    │      teleport_backend = cluster state
                                             │      teleport_audit   = audit events
                                             ├──► MinIO
                                             │      s3://teleport-sessions = recordings
                                             └──► Access Graph ──► PostgreSQL (access_graph)
```

Two trust relationships make the auth ↔ Access Graph link work (steps 3 and 6):
the auth pod verifies Access Graph's certificate against **our demo CA**, and
Access Graph verifies the auth pod against **Teleport's own host CA**.

Auth everywhere is deliberately simple — passwords for Postgres, access keys
for MinIO — fine in-cluster for a demo; production would use client certs or
cloud IAM.

**Before you start:** the [root README's one-time setup](../README.md#one-time-setup)
(license, k3s, certs, hosts entry, CA trust). If `01-quickstart` is running,
reset first — both want port 443: `cd ../k3s && docker compose down -v &&
docker compose up -d`. Then from this directory:

```bash
export KUBECONFIG="$(cd .. && pwd)/k3s/kubeconfig/kubeconfig.yaml"
kubectl get nodes    # sanity check: one node, STATUS Ready
```

## 1. Build the Postgres image (the wal2json requirement)

Teleport's Postgres backend needs the **wal2json** logical-decoding plugin,
and no stock Postgres image includes it — managed clouds (RDS, Azure)
preinstall it; self-hosted means adding one package. That's the entire
[`postgres-image/Dockerfile`](postgres-image/Dockerfile):

```bash
docker build -t cnpg-wal2json:17 postgres-image/

# Load it into the local k3s cluster (containerd doesn't see Docker's images).
# On a real cluster: push to your registry instead and update imageName in
# cnpg-cluster.yaml.
docker save cnpg-wal2json:17 | docker exec -i k3s-k3s-1 \
  ctr --namespace k8s.io images import -
```

## 2. Install the backends: PostgreSQL and MinIO

One Postgres cluster with three databases (see
[`cnpg-cluster.yaml`](cnpg-cluster.yaml)), one MinIO with one bucket (see
[`minio-values.yaml`](minio-values.yaml)).

```bash
# CloudNativePG operator
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --version 0.29.0 \
  --wait

# Postgres cluster
kubectl create namespace teleport
kubectl label namespace teleport --overwrite \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=baseline
kubectl -n teleport apply -f cnpg-cluster.yaml
kubectl -n teleport wait --for=condition=Ready cluster/teleport-db --timeout=300s

# MinIO with a teleport-sessions bucket
helm repo add minio https://charts.min.io/
helm install minio minio/minio \
  --namespace minio --create-namespace \
  --version 5.4.0 \
  --values minio-values.yaml \
  --wait --timeout 10m
```

## 3. License and TLS secrets

```bash
# Enterprise license (file key must be exactly license.pem)
kubectl -n teleport create secret generic license \
  --from-file=license.pem=../license.pem

# Proxy certificate (chain + key) and the demo CA
kubectl -n teleport create secret tls teleport-tls \
  --cert=../demo-pki/out/teleport-chain.crt --key=../demo-pki/out/teleport.key
kubectl -n teleport create secret generic teleport-tls-ca \
  --from-file=ca.pem=../demo-pki/out/ca.crt

# The demo CA again, as a file the auth pod mounts to verify Access Graph
# (the first trust relationship from the diagram)
kubectl -n teleport create configmap teleport-access-graph-ca \
  --from-file=ca.pem=../demo-pki/out/ca.crt
```

## 4. Install Teleport

The Postgres and MinIO wiring is all in
[`teleport-cluster-values.yaml`](teleport-cluster-values.yaml) — every
setting explained. The `--wait` doubles as the backend test: the auth pod
only goes Ready if it can reach Postgres (with wal2json) and MinIO.

```bash
helm repo add teleport https://charts.releases.teleport.dev
helm install teleport-cluster teleport/teleport-cluster \
  --namespace teleport \
  --version 18.10.0 \
  --values teleport-cluster-values.yaml \
  --wait --timeout 10m
```

Verify it's genuinely running on Postgres — the backend tables exist and
Teleport answers over your cert:

```bash
kubectl -n teleport exec teleport-db-1 -c postgres -- \
  psql -U postgres -d teleport_backend -c '\dt'
curl --cacert ../demo-pki/out/ca.crt https://teleport.demo.test/webapi/ping
```

> The auth pod logs Access Graph connection errors until step 6 — expected;
> it retries.

## 5. First login

```bash
kubectl -n teleport exec deploy/teleport-cluster-auth -- \
  tctl users add admin --roles=editor,access,auditor
```

Open the invite link, set password + passkey (no certificate warning), then:

```bash
tsh login --proxy=teleport.demo.test:443 --user=admin
```

## 6. Identity Security (Access Graph)

Three inputs, one per command — its database, its certificate, and the
Teleport host CA it uses to trust the auth pod (the second trust relationship
from the diagram):

```bash
kubectl create namespace teleport-access-graph

# 6a. Its database: the access_graph DB from cnpg-cluster.yaml
kubectl -n teleport-access-graph create secret generic teleport-access-graph-postgres \
  --from-literal=uri="postgresql://teleport:teleport-demo-password@teleport-db-rw.teleport.svc.cluster.local:5432/access_graph?sslmode=require"

# 6b. Its certificate (SAN = its in-cluster Service DNS name)
kubectl -n teleport-access-graph create secret tls teleport-access-graph-tls \
  --cert=../demo-pki/out/access-graph-chain.crt --key=../demo-pki/out/access-graph.key

# 6c. Teleport's host CA, exported from the running cluster
kubectl -n teleport exec deploy/teleport-cluster-auth -- \
  tctl auth export --type=tls-host > ../demo-pki/out/teleport-host-ca.pem

helm install teleport-access-graph teleport/teleport-access-graph \
  --namespace teleport-access-graph \
  --version 1.30.0 \
  --values access-graph-values.yaml \
  --set-file 'clusterHostCAs[0]=../demo-pki/out/teleport-host-ca.pem' \
  --wait --timeout 5m

# One more step: the proxy pods looked for Access Graph when THEY started
# (step 4 — before it existed) and only recheck on a backoff that grows to
# 10 minutes. Until they reconnect, the Identity Security pages show
# "Unexpected end of JSON input" errors. Restart the proxies and they find
# it immediately. (Auth needs no restart — it retries every 5 seconds.)
kubectl -n teleport rollout restart deployment/teleport-cluster-proxy
kubectl -n teleport rollout status deployment/teleport-cluster-proxy --timeout=120s
```

In the web UI: **Identity Security** in the left nav → Graph Explorer shows
your cluster, users, and access paths.

## 7. See it all working

**Session recordings → MinIO.** The chart automatically registers the
Kubernetes cluster it runs on, so you already have a recordable resource. In
the web UI: **Resources** → the `teleport.demo.test` Kubernetes cluster →
**Connect** → launch a session, run a command or two, exit. The recording
uploads when the session ends:

```bash
# The records/ prefix is created by the first upload — until you've recorded
# and EXITED a session, this fails with "No such file or directory".
kubectl -n minio exec deploy/minio -- ls -R /export/teleport-sessions/records
```

**Audit events → Postgres.** Every login and session is a row now:

```bash
kubectl -n teleport exec teleport-db-1 -c postgres -- \
  psql -U postgres -d teleport_audit -c 'SELECT event_type, creation_time FROM events ORDER BY creation_time DESC LIMIT 5'
```

## Making it actually HA

Everything stateful is already external, so:

1. `highAvailability.replicaCount: 2` (+`helm upgrade`) — multiple auth/proxy pods
2. `instances: 3` in `cnpg-cluster.yaml` — replicated Postgres with automatic failover
3. `mode: distributed` + more replicas in `minio-values.yaml`
4. A real load balancer + real certs in front (see the root README's Reference section)

## Teardown

```bash
helm -n teleport-access-graph uninstall teleport-access-graph
helm -n teleport uninstall teleport-cluster
helm -n minio uninstall minio
kubectl -n teleport delete -f cnpg-cluster.yaml
helm -n cnpg-system uninstall cnpg
# takes a minute or two — pods and volume finalizers drain first
kubectl delete namespace teleport teleport-access-graph minio cnpg-system
# or nuke the whole cluster: cd ../k3s && docker compose down -v
```
