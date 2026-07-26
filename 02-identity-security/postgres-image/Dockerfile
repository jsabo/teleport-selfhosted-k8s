# CloudNativePG operand image + wal2json.
#
# Teleport's PostgreSQL backend streams cluster-state changes via logical
# decoding using the wal2json output plugin — and NO stock Postgres image
# ships it (not CNPG's, not the official postgres image, not pgvector's).
# Managed clouds (RDS, Azure Database) preinstall it; self-hosted means
# adding one package to the image, which is all this Dockerfile does.
#
# The base is CNPG's "standard" flavor, which already includes pgvector —
# used by the Access Graph database. One image serves everything.
#
# Build (see ../README.md for loading it into your cluster):
#   docker build -t cnpg-wal2json:17 .
FROM ghcr.io/cloudnative-pg/postgresql:17-standard-trixie
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends postgresql-17-wal2json && \
    rm -rf /var/lib/apt/lists/*
USER 26
