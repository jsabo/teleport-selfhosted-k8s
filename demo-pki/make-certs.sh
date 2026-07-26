#!/usr/bin/env bash
# make-certs.sh — generate the demo PKI: one CA and two server certificates.
#
#   out/ca.crt                 demo Certificate Authority (import this into your OS trust store)
#   out/teleport-chain.crt     Teleport proxy cert (leaf + CA) — SANs: DOMAIN and *.DOMAIN
#   out/teleport.key
#   out/access-graph-chain.crt Access Graph service cert — SAN: its in-cluster Service DNS name
#   out/access-graph.key
#
# THE RULE THIS DEMO TEACHES: the Teleport clusterName, the DNS name clients
# resolve, and the certificate SANs must all be the SAME string. The wildcard
# SAN (*.DOMAIN) is required for Teleport Application Access, which serves
# every app at <app>.<DOMAIN>.
#
# Usage:
#   bash make-certs.sh                       # uses teleport.demo.test
#   DOMAIN=teleport.corp.test bash make-certs.sh
#
set -euo pipefail
cd "$(dirname "$0")"

DOMAIN="${DOMAIN:-teleport.demo.test}"
# Access Graph runs in its own namespace; Teleport talks to it via this
# in-cluster Service name, so that name must be in the cert SAN.
TAG_SVC="teleport-access-graph.teleport-access-graph.svc.cluster.local"

mkdir -p out && cd out

# ── 1. Demo CA (10 years) ─────────────────────────────────────────────────────
if [[ ! -f ca.key ]]; then
  openssl genrsa -out ca.key 4096
  openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
    -subj "/CN=Teleport Demo CA/O=Demo"
  echo "CA created: out/ca.crt"
else
  echo "CA exists — reusing (delete out/ to start over)"
fi

# ── 2. Teleport proxy cert: DOMAIN + wildcard ─────────────────────────────────
openssl genrsa -out teleport.key 2048
openssl req -new -key teleport.key -out teleport.csr -subj "/CN=${DOMAIN}/O=Demo"
cat > teleport.ext <<EOF
[SAN]
subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}
EOF
openssl x509 -req -days 825 -in teleport.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out teleport.crt -extfile teleport.ext -extensions SAN
cat teleport.crt ca.crt > teleport-chain.crt
echo "Teleport proxy cert: out/teleport-chain.crt (SANs: ${DOMAIN}, *.${DOMAIN})"

# ── 3. Access Graph cert: the in-cluster Service DNS name ─────────────────────
openssl genrsa -out access-graph.key 2048
openssl req -new -key access-graph.key -out access-graph.csr -subj "/CN=${TAG_SVC}/O=Demo"
cat > access-graph.ext <<EOF
[SAN]
subjectAltName=DNS:${TAG_SVC},DNS:teleport-access-graph.teleport-access-graph.svc
EOF
openssl x509 -req -days 825 -in access-graph.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out access-graph.crt -extfile access-graph.ext -extensions SAN
cat access-graph.crt ca.crt > access-graph-chain.crt
echo "Access Graph cert:   out/access-graph-chain.crt (SAN: ${TAG_SVC})"

# Clean up intermediates — only the chains, keys, and the CA are ever used
rm -f teleport.csr access-graph.csr teleport.ext access-graph.ext ca.srl \
      teleport.crt access-graph.crt
echo ""
echo "Done. Files in demo-pki/out/:"
echo "  ca.crt / ca.key                            the demo CA (trust ca.crt on your machine)"
echo "  teleport-chain.crt / teleport.key          the Teleport proxy certificate"
echo "  access-graph-chain.crt / access-graph.key  the Access Graph certificate (02 only)"
echo ""
echo "Next: the root README's remaining setup steps, then 01-quickstart/ or 02-identity-security/."
