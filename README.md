# otto

A single pod that serves a static site over HTTP and accepts uploads over SFTP.
Push to `main` and GitHub Actions deploys the pod; after that your friend
updates the site with an SFTP client and never touches Kubernetes.

```
                 GitHub Actions                       your server
                 ---------------                      -----------
  push main  ->  build sftp image  -> Docker Hub
                 kubectl apply     ------------------> pod otto-site
                                                        |- web   nginx  :8080 --> Service otto-web:80 --> your ingress
                                                        '- sftp  sshd   :22   --> Service otto-sftp NodePort 30022
                                                             both mount /srv/otto/site on the host

  friend  --sftp--> node:30022  ->  /public  ->  served immediately at your domain
```

The uploaded files live on the host at `/srv/otto/site/public`, mounted
writable into the sftp container and read-only into nginx. Nothing about the
site is baked into the image, so redeploying never overwrites content and
uploading never requires a redeploy.

## Why SFTP and not FTP

Plain FTP needs port 21 *plus* a passive port range exposed, and vsftpd has to
advertise the node's public IP or transfers hang after `PASV`. Behind
Kubernetes NAT that breaks constantly. SFTP is one TCP port, encrypted by
default, and every client your friend might use — FileZilla, WinSCP,
Cyberduck, Finder — supports it by picking "SFTP" instead of "FTP" in the
protocol dropdown. Same drag-and-drop experience, far less to go wrong.

## Layout

| Path | What it is |
| --- | --- |
| `docker/sftp/` | The sshd image: `Dockerfile`, `sshd_config`, `entrypoint.sh` |
| `k8s/*.yaml` | Applied on every deploy, in filename order |
| `setup/rbac-ci.yaml` | One-time bootstrap, applied by hand as an admin |
| `scripts/render.sh` | Fills placeholders in `k8s/*.yaml`, writes to stdout |
| `scripts/make-ci-kubeconfig.sh` | Generates the scoped kubeconfig for CI |
| `.github/workflows/deploy.yml` | validate → build → deploy |

Three placeholders get substituted at deploy time: `${SFTP_IMAGE}`,
`${NODE_NAME}`, `${SITE_HOST_PATH}`.

## One-time setup

### 1. Find your node name and pick a host directory

The site lives on one node's disk (`hostPath`), so the pod is pinned to that
node with a `nodeSelector`.

```bash
kubectl get nodes -o wide
```

Take the `NAME` column value — and note the architecture while you're there,
see below. The directory is created automatically on first deploy; the default
is `/srv/otto`, giving:

```
/srv/otto/site/         root:root 0755   <- the sftp chroot
/srv/otto/site/public/  1000:1000 0755   <- the document root, writable
/srv/otto/sshd/         root:root 0700   <- persistent ssh host keys
```

Two k3s notes:

- k3s does ship a default StorageClass (`local-path`), so a PVC would also work
  here. `hostPath` is kept deliberately: it gives you a plain directory you can
  `tar` or `rsync` from the host without going through a pod, which matters when
  the whole point is easy file access.
- **The server is ARM.** The sftp image is built for
  `linux/amd64,linux/arm64,linux/arm/v7` (see `PLATFORMS` in the workflow), so it
  runs on either 32- or 64-bit ARM. The three upstream images the pod uses but
  does not build were checked against Docker Hub and all publish `arm/v7` and
  `arm64/v8`:

  | Image | Covers |
  | --- | --- |
  | `alpine:3.20` | amd64, arm/v6, arm/v7, arm64/v8, 386, ppc64le, riscv64, s390x |
  | `busybox:1.36` | amd64, arm/v5, arm/v6, arm/v7, arm64/v8, 386, ppc64le, riscv64, s390x |
  | `nginxinc/nginx-unprivileged:1.27-alpine` | amd64, arm/v6, arm/v7, arm64/v8, 386, ppc64le, riscv64, s390x |

  Re-check with this after bumping any of those versions:

  ```bash
  docker manifest inspect <image> | grep -o '"architecture": "[^"]*"' | sort -u
  ```

  Building three platforms under QEMU adds a couple of minutes. To cut that,
  narrow `PLATFORMS` to just your node's architecture — find it with:

  ```bash
  kubectl get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture
  ```

  `arm64` there means `linux/arm64`; `arm` means `linux/arm/v7`.

### 2. Docker Hub

Create a **public** repository named `otto-sftp`, and an access token at
<https://hub.docker.com/settings/security>.

The token is only used by the GitHub Action to *push*. The cluster pulls
anonymously, so there is no registry credential anywhere in Kubernetes and no
`imagePullSecret` to manage. Public is safe here: the image is sshd plus a
config file — no site content, no keys, no credentials. Those all arrive at
runtime from the `otto-sftp-auth` secret.

### 3. Kubeconfig — optional if you already have one

Your `rest-server` pipeline already uses a `KUBECONFIG` secret. If that's an
organisation secret, this project picks it up as-is and you can skip to step 4.

If you'd rather not reuse an admin kubeconfig, this creates a service account
that can only touch the `otto` namespace:

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f setup/rbac-ci.yaml
API_SERVER=https://your.server:6443 sh ./scripts/make-ci-kubeconfig.sh
```

(Invoked via `sh` because a checkout from Windows won't carry the execute bit;
`chmod +x scripts/*.sh` once on Linux if you'd rather run them directly.)

The last command prints one base64 line — that's the `KUBECONFIG` secret. The
workflow accepts base64 or raw YAML, so either form of the secret works.

Either way the API server has to be reachable from GitHub's runners. If it
isn't, use a self-hosted runner on the server and change `runs-on: ubuntu-latest`
to `runs-on: self-hosted` in the `deploy` job — nothing else changes.

### 4. Repository variables and secrets

Settings → Secrets and variables → Actions.

**Variables** (not secret, visible in logs):

| Name | Example | Notes |
| --- | --- | --- |
| `DOCKERHUB_USERNAME` | `yourname` | Also the image namespace |
| `NODE_NAME` | `k8s-node-1` | From step 1 |
| `SITE_HOST_PATH` | `/srv/otto` | Optional, defaults to `/srv/otto` |

**Secrets:**

| Name | Notes |
| --- | --- |
| `DOCKER_PASSWORD` | Docker Hub access token from step 2 |
| `KUBECONFIG` | Kubeconfig, base64 **or** raw YAML — both are accepted |
| `SFTP_PASSWORD` | Your friend's password. Long and random. |
| `SFTP_AUTHORIZED_KEYS` | Optional, one public key per line |

These reuse the secret names from your existing `rest-server` pipeline, so if
`DOCKER_PASSWORD` and `KUBECONFIG` are organisation-level secrets they are
already in place and step 3 is unnecessary.

Set at least one of `SFTP_PASSWORD` / `SFTP_AUTHORIZED_KEYS`, otherwise the pod
runs but nobody can log in.

If you set neither, the workflow leaves any existing secret alone rather than
wiping it — so you can keep credentials off GitHub entirely and create them
directly instead:

```bash
kubectl -n otto create secret generic otto-sftp-auth \
  --from-literal=password='a-long-random-password' \
  --from-file=authorized_keys=/path/to/friend_key.pub \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n otto rollout restart deploy/otto-site
```

Either key may be omitted.

The workflow uses an environment called `production`; either create it under
Settings → Environments or delete the `environment: production` line from the
`deploy` job.

### 5. Wire up your ingress

The deploy creates `Service otto-web` in namespace `otto`, port `80`
(in-cluster: `otto-web.otto.svc.cluster.local:80`). Point your existing ingress
at it.

One thing to watch: an Ingress object can only route to Services in its **own
namespace**. If your existing Ingress objects live somewhere else (`default`,
say), pointing one at `otto-web` silently 503s. Either put the Ingress inside
`otto` — the controller itself can stay wherever it is, only the Ingress object
has to be co-located — or bridge with an `ExternalName` service in the
ingress' namespace:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: otto-web
  namespace: default        # wherever your Ingress objects live
spec:
  type: ExternalName
  externalName: otto-web.otto.svc.cluster.local
  ports:
    - port: 80
```

If you'd rather skip namespaces entirely and put this next to your existing
workloads, change `namespace: otto` to `namespace: default` in every `k8s/*.yaml`
and drop the `Ensure namespace` step from the workflow.

### 6. Open the SFTP port

`Service otto-sftp` is a NodePort on `30022`. Allow it through the server's
firewall:

```bash
sudo ufw allow 30022/tcp comment 'otto sftp'
```

To serve SFTP on the conventional port 22 instead, don't — that's your server's
own sshd. Either keep 30022, or if you run ingress-nginx you can proxy a TCP
port through it via the controller's `tcp-services` ConfigMap.

### 7. Push

```bash
git init
git add .
git commit -m "Add otto site pod"
git remote add origin git@github.com:you/otto.git
git push -u origin main
```

## How your friend uploads

| Setting | Value |
| --- | --- |
| Protocol | **SFTP** — SSH File Transfer Protocol |
| Host | your server's IP or hostname |
| Port | `30022` |
| User | `web` |
| Password | whatever you put in `SFTP_PASSWORD` |
| Remote directory | `/public` |

They land in a chroot: `/public` is the only writable place and the whole
filesystem outside it is invisible. Drop `index.html` and assets in there and
the site updates instantly — no restart, no pipeline run.

The first connection shows a host key fingerprint prompt. That fingerprint is
stored on the host in `/srv/otto/sshd` and survives pod restarts, so it should
only ever be accepted once. The pod logs it at startup:

```bash
kubectl -n otto logs deploy/otto-site -c sftp | grep fingerprint
```

## Deploying by hand

The workflow is a thin wrapper around this, useful for testing before pushing:

```bash
export SFTP_IMAGE=docker.io/yourname/otto-sftp:latest
export NODE_NAME=k8s-node-1
export SITE_HOST_PATH=/srv/otto

sh ./scripts/render.sh | kubectl apply -f -
kubectl -n otto rollout status deploy/otto-site
```

`sh ./scripts/render.sh` alone prints the manifests without applying — worth a
look before the first deploy. On Windows, run these in Git Bash.

## Operations

```bash
# logs
kubectl -n otto logs deploy/otto-site -c sftp -f
kubectl -n otto logs deploy/otto-site -c web -f

# what's actually in the document root
kubectl -n otto exec deploy/otto-site -c sftp -- ls -la /home/web/public

# rotate the password: update the SFTP_PASSWORD secret, then
kubectl -n otto rollout restart deploy/otto-site

# back up the site (content only lives on the node, so back it up)
sudo tar czf otto-backup-$(date +%F).tar.gz -C /srv/otto/site public
```

Credentials are read once at container start, so changing them needs a restart.
Site content does not — that is served straight off disk.

## Troubleshooting

**403 Forbidden on a file that exists.** A permissions mismatch: nginx runs as
uid 101 and needs world-read. `sshd_config` forces `-u 0022` on the sftp
subsystem so uploads land as 0644, but files copied in by other means may not
be. Fix with:

```bash
kubectl -n otto exec deploy/otto-site -c sftp -- \
  sh -c 'chmod -R a+rX /home/web/public'
```

**SFTP login fails with "Connection closed".** Almost always the chroot
permission rule: `/home/web` must be owned by root and not group- or
world-writable. The init container enforces this on every start, so check its
output and the sftp container's:

```bash
kubectl -n otto logs deploy/otto-site -c prepare-volume
kubectl -n otto logs deploy/otto-site -c sftp
```

**Permission denied for user `web`.** No credentials. The sftp log says
`WARNING: no password and no authorized_keys` when the secret is missing or
empty.

**Pod stuck in `Pending`.** The `nodeSelector` doesn't match any node — check
`NODE_NAME` against `kubectl get nodes`.

**`exec format error` in a container's log.** The image lacks a variant for that
node's CPU — only possible if `PLATFORMS` was narrowed, or an upstream image
version was bumped to one with thinner ARM coverage. See step 1.

**Pod stuck in `ContainerCreating`.** Check
`kubectl -n otto describe pod -l app=otto-site` — usually a pull failure or a
volume it can't create on the pinned node.

**sshd exits immediately.** The dropped Linux capabilities may not suit your
runtime (gVisor, some hardened kubelets). Try removing the
`capabilities: {drop: [ALL], add: [...]}` block from the `sftp` container in
`k8s/20-deployment.yaml` and redeploy.

**Ingress returns 503.** Either the pod isn't ready, or your Ingress is in a
different namespace than `otto-web`. See step 5.

## Security notes

- SFTP traffic is encrypted; the password never crosses the network in clear.
  Public keys are still better than a password — put one in
  `SFTP_AUTHORIZED_KEYS` and the account stays password-locked.
- `authorized_keys` is stored at `/etc/ssh/authorized_keys/web`, deliberately
  outside the chroot. Inside it, the user could rewrite their own key file and
  grant access to others.
- The sftp session is `internal-sftp` with a forced command and all forwarding
  disabled: no shell, no port forwarding, no reaching the rest of your network.
- nginx denies dotfiles, so a stray `.env` or `.git` in the upload directory
  isn't served.
- The sftp container runs as root because sshd needs it to `chroot(2)` and to
  drop privileges, but with all capabilities dropped except the six it actually
  uses.
- The CI service account is limited to the `otto` namespace, plus `get/create/patch`
  on namespaces. A kubeconfig built that way cannot touch the rest of the
  cluster if it leaks — unlike the admin one your other pipeline uses.
