# Enrolling Linux SSH Nodes into Teleport

**Version:** 18.x | **Packages:** RPM (RHEL) and DEB (Ubuntu/Debian)

---

## Before you start

- Teleport cluster already running and reachable (from the node being enrolled)
- `cluster-admin` or equivalent access to run `tctl`
- Root / sudo access on each target node

---

## 1 — Generate a join token

Run this on a machine with `tctl` access to your cluster:

```bash
tctl tokens add --type=node --ttl=1h --format=text
```

Copy the token string — you'll need it in Step 3. Tokens are single-use and expire.

---

## 2 — Install the Teleport package

Run the appropriate block on each target node.

> **Match the cluster version.** An agent must never be newer than the auth
> service it joins. The cluster in this repo is pinned to **18.10.0**, so pin
> the package to the same version (shown below) — a bare `install teleport-ent`
> pulls the latest 18.x, which may be ahead of your cluster.

Both blocks read the distro identifiers from `/etc/os-release` first:

```bash
source /etc/os-release
```

### Ubuntu / Debian (APT)

```bash
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://apt.releases.teleport.dev/gpg \
  -o /etc/apt/keyrings/teleport-archive-keyring.asc

echo "deb [signed-by=/etc/apt/keyrings/teleport-archive-keyring.asc] \
  https://apt.releases.teleport.dev/${ID} ${VERSION_CODENAME} stable/v18" \
  | sudo tee /etc/apt/sources.list.d/teleport.list >/dev/null

sudo apt-get update
sudo apt-get install -y teleport-ent=18.10.0   # use 'teleport' for OSS
```

### RHEL 8+ / Rocky / AlmaLinux (DNF)

```bash
sudo dnf install -y dnf-plugins-core
VERSION_ID_MAJOR="$(echo "$VERSION_ID" | grep -Eo '^[0-9]+')"   # "8.10" -> "8"
sudo dnf config-manager --add-repo \
  "$(rpm --eval "https://yum.releases.teleport.dev/${ID}/${VERSION_ID_MAJOR}/Teleport/%{_arch}/stable/v18/teleport.repo")"
sudo dnf install -y teleport-ent-18.10.0   # use 'teleport' for OSS
```

### RHEL 7 / Amazon Linux 2 (YUM)

```bash
sudo yum install -y yum-utils
VERSION_ID_MAJOR="$(echo "$VERSION_ID" | grep -Eo '^[0-9]+')"
sudo yum-config-manager --add-repo \
  "$(rpm --eval "https://yum.releases.teleport.dev/${ID}/${VERSION_ID_MAJOR}/Teleport/%{_arch}/stable/v18/teleport.repo")"
sudo yum install -y teleport-ent-18.10.0   # use 'teleport' for OSS
```

---

## 3 — Configure the node

Create `/etc/teleport.yaml`. Replace `teleport.example.com` with your cluster's proxy address and paste the token from Step 1.

Labels under `ssh_service.labels` are indexed by Teleport and used by roles to control
which nodes a user can reach — set them to match your environment before the node first
joins (changing labels after join requires a restart):

```yaml
version: v3
teleport:
  data_dir: /var/lib/teleport
  proxy_server: teleport.example.com:443
  join_params:
    token_name: "<token from step 1>"
    method: token

ssh_service:
  enabled: true
  labels:
    env: staging          # production | staging | dev
    os: rhel              # rhel | ubuntu
    role: app             # app | db | bastion | build
    owner: platform-team  # team responsible for this node

auth_service:
  enabled: false

proxy_service:
  enabled: false
```

### Self-signed or private/corporate PKI certificate — trust the CA on each node

If the cluster cert is not publicly trusted (self-signed CA or private/corporate PKI),
each node must trust the issuing CA before Teleport can connect to the proxy. For a
self-signed setup this is the `ca.crt` generated during the cluster install; for
corporate PKI it is your organization's root CA (often already present on managed
images — verify with `curl https://<cluster-name>/webapi/ping` before assuming).
Copy the CA cert to each node and add it to the system trust store:

**RHEL / Rocky / AlmaLinux:**
```bash
sudo cp ca.crt /etc/pki/ca-trust/source/anchors/teleport-ca.crt
sudo update-ca-trust
```

**Ubuntu / Debian:**
```bash
sudo cp ca.crt /usr/local/share/ca-certificates/teleport-ca.crt
sudo update-ca-certificates
```

Do this before starting the Teleport service. If you skip it, the agent will log
`certificate signed by unknown authority` and fail to connect.

### Dynamic labels (optional)

Dynamic labels run a command periodically and use the output as the label value.
Useful for values that can change (e.g. kernel version, cloud instance metadata):

```yaml
ssh_service:
  enabled: true
  labels:
    env: production
  commands:
    - name: kernel
      command: [uname, -r]
      period: 1h
    - name: instance-id       # AWS/GCP/Azure only — remove if not on cloud
      command: [sh, -c, "curl -sf http://169.254.169.254/latest/meta-data/instance-id"]
      period: 1h
```

### Targeting nodes with roles

A role grants access to nodes whose labels match `node_labels`. Create
`roles/example-node-access.yaml`:

```yaml
kind: role
version: v8
metadata:
  name: staging-app-access
spec:
  allow:
    node_labels:
      env: staging
      role: app
    logins: [ec2-user, ubuntu, root]
    host_groups: []
  deny: {}
```

Apply with:

```bash
tctl create -f roles/example-node-access.yaml
```

Multiple label keys in `node_labels` are ANDed — a node must have **all** of them to
match. Use `"*"` as a value to match any value for that key (e.g. `env: "*"` matches
all environments).

---

## 4 — Enable and start the service

```bash
sudo teleport install systemd -o /etc/systemd/system/teleport.service
sudo systemctl daemon-reload
sudo systemctl enable --now teleport
sudo systemctl status teleport
```

Logs:

```bash
journalctl -fu teleport
```

### Testing with --insecure (skip CA trust)

If you haven't distributed `ca.crt` yet and want to get a node connected quickly,
pass `--insecure` to the teleport process. Because it runs as a systemd service,
the flag goes in the `ExecStart` line — not a shell command:

```bash
sudo sed -i 's|^ExecStart=.*|& --insecure|' /etc/systemd/system/teleport.service
sudo systemctl daemon-reload
sudo systemctl restart teleport
```

The resulting `ExecStart` line will look like:

```
ExecStart=/usr/local/bin/teleport start --config=/etc/teleport.yaml --pid-file=/run/teleport.pid --insecure
```

> `--insecure` disables all TLS verification — **use only for testing**. Import `ca.crt`
> into the OS trust store (above) before going live.

---

## 5 — Verify enrollment

From any machine with `tctl`:

```bash
tctl nodes ls
```

The node should appear within ~30 seconds of starting the service. Once listed, users with the right role can SSH in via:

```bash
tsh ssh <user>@<nodename>
```

---

## RHEL-specific notes

**SELinux (RHEL 8/9 with enforcing mode)**

Teleport ships an SELinux policy module. Without it, Teleport will fail to spawn shells when SELinux is enforcing:

```bash
sudo dnf install -y selinux-policy-devel

# Download the Teleport tarball for your version and extract the SELinux installer
curl -O https://cdn.teleport.dev/teleport-ent-v18.10.0-linux-amd64-bin.tar.gz
tar -xzf teleport-ent-v18.10.0-linux-amd64-bin.tar.gz
sudo ./teleport-ent/install-selinux.sh
```

Re-run `install-selinux.sh` after every Teleport upgrade.

**firewalld**

Teleport nodes connect outbound to the proxy — no inbound ports need to be opened unless you are running the proxy or auth service on this host. If firewalld is blocking outbound 443, either allow it or disable firewalld for testing:

```bash
sudo systemctl disable --now firewalld
```

---

## Air-gapped / restricted networks

Teleport does not publish official documentation for mirroring their package repositories. Two practical options:

### Option A — Tarball install (no package manager needed)

Download directly from Teleport's CDN onto a jump host, copy to the target, and install manually:

```bash
# On a host with internet access:
curl -O https://cdn.teleport.dev/teleport-ent-v18.10.0-linux-amd64-bin.tar.gz

# Copy to target node, then:
tar -xzf teleport-ent-v18.10.0-linux-amd64-bin.tar.gz
sudo ./teleport-ent/install
```

The `install` script drops binaries into `/usr/local/bin`. Proceed to Step 3 to configure.

### Option B — Internal package mirror

Mirror the Teleport repo to an internal server using standard Linux tooling, then point nodes at your mirror instead of Teleport's CDN.

**DEB mirror (Ubuntu/Debian) — using `aptly`:**

```bash
# On your mirror host:
aptly mirror create teleport https://deb.releases.teleport.dev/ stable main
aptly mirror update teleport
aptly snapshot create teleport-snap from mirror teleport
aptly publish snapshot teleport-snap

# On each node — replace the repo URL with your internal mirror:
echo "deb [trusted=yes] http://mirror.internal/teleport stable main" \
  | sudo tee /etc/apt/sources.list.d/teleport.list
```

**RPM mirror (RHEL) — using `reposync`:**

```bash
# On your mirror host (requires dnf-plugins-core):
sudo dnf install -y dnf-plugins-core createrepo
sudo reposync --repoid=teleport --download-path=/var/www/html/teleport
sudo createrepo /var/www/html/teleport

# On each node — create /etc/yum.repos.d/teleport.repo:
[teleport]
name=Teleport
baseurl=http://mirror.internal/teleport
enabled=1
gpgcheck=0
```

> Teleport supports a `--base-url` flag on `teleport-update enable` for tarball-based
> auto-update mirrors, but this is separate from the APT/RPM package repos and only
> applies to the auto-updater agent.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Node doesn't appear in `tctl nodes ls` | Check `journalctl -fu teleport` — usually a bad token or unreachable proxy |
| `certificate signed by unknown authority` | Import `ca.crt` into the OS trust store (Step 3) or pass `--insecure` in the systemd unit for quick testing |
| `token has expired` | Generate a new token (Step 1) and update `/etc/teleport.yaml` |
| `connection refused` to proxy | Confirm port 443 is reachable: `curl https://teleport.example.com/webapi/ping` |
| SELinux `AVC denied` in audit log | Run `install-selinux.sh` (see RHEL notes above) |
| `teleport-ent` not found in repo | Confirm the repo was added: `apt-cache policy teleport-ent` or `dnf repolist` |

---

## Reference

- [Server Access — Getting Started](https://goteleport.com/docs/enroll-resources/server-access/getting-started/) — end-to-end walkthrough for enrolling Linux hosts
- [Server Access — RBAC](https://goteleport.com/docs/enroll-resources/server-access/rbac/) — `node_labels`, allowed logins, deny rules, and SSH role options
- [Add Labels to Resources](https://goteleport.com/docs/zero-trust-access/rbac-get-started/labels/) — labeling nodes and other resources for RBAC targeting
- [Linux Installation](https://goteleport.com/docs/installation/) — APT and RPM repo setup, package names, and version pinning
- [Join Methods and Tokens](https://goteleport.com/docs/reference/deployment/join-methods/) — token, IAM, EC2, and other join methods with security classifications
- [Teleport Configuration Reference](https://goteleport.com/docs/reference/deployment/config/) — full `teleport.yaml` reference for all services and fields
- [SELinux Module](https://goteleport.com/docs/zero-trust-access/management/security/selinux/) — installing and upgrading the SELinux policy module for RHEL 8/9
