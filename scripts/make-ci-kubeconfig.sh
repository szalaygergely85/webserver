#!/usr/bin/env sh
# Builds a namespace-scoped kubeconfig for the GitHub Action and prints it
# base64-encoded, ready to paste into the KUBECONFIG repository secret.
# (The workflow accepts base64 or raw YAML; base64 is just safer to paste.)
#
# Run this ON the server, as root. On k3s it finds /etc/rancher/k3s/k3s.yaml and
# the bundled `k3s kubectl` by itself:
#
#   sudo sh ./scripts/make-ci-kubeconfig.sh
#   sudo API_SERVER=https://k8s.example.com:6443 sh ./scripts/make-ci-kubeconfig.sh
#
# Prerequisites (once):
#   kubectl apply -f k8s/00-namespace.yaml
#   kubectl apply -f setup/rbac-ci.yaml
set -eu

NS=otto
SECRET=otto-ci-token
K3S_KUBECONFIG=/etc/rancher/k3s/k3s.yaml

fail() { printf 'make-ci-kubeconfig.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*" >&2; }

# --- locate kubectl --------------------------------------------------------
# k3s ships kubectl as a subcommand; a standalone binary is often absent.
if command -v kubectl >/dev/null 2>&1; then
    KUBECTL='kubectl'
elif command -v k3s >/dev/null 2>&1; then
    KUBECTL='k3s kubectl'
    note 'using "k3s kubectl" (no standalone kubectl found)'
else
    fail 'neither kubectl nor k3s found - run this on the server'
fi

# k3s.yaml is mode 0600 root-owned, so this needs sudo.
if [ -z "${KUBECONFIG:-}" ] && [ -r "$K3S_KUBECONFIG" ]; then
    KUBECONFIG="$K3S_KUBECONFIG"
    export KUBECONFIG
    note "using KUBECONFIG=$K3S_KUBECONFIG"
fi

kube() { $KUBECTL "$@"; }

kube version --request-timeout=10s >/dev/null 2>&1 \
    || fail "cannot reach the cluster. If $K3S_KUBECONFIG exists, re-run with sudo."

# --- decide which address GitHub will connect to ---------------------------
if [ -n "${API_SERVER:-}" ]; then
    server="$API_SERVER"
else
    server="$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
    case "$server" in
        ''|*127.0.0.1*|*localhost*)
            # k3s always writes 127.0.0.1; substitute this host's primary address.
            ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
            [ -n "$ip" ] || fail 'could not detect this host address; set API_SERVER'
            server="https://$ip:6443"
            note "kubeconfig points at localhost; using $server instead"
            note 'if that is a private address, re-run with API_SERVER set to the public one'
            ;;
    esac
fi

case "$server" in
    https://*) ;;
    *) fail "API_SERVER must start with https:// - got '$server'" ;;
esac

# --- check the API certificate covers that address -------------------------
# The single most common k3s failure: the cert only carries 127.0.0.1 and the
# node IP, so connecting by any other name fails TLS verification.
host="$(printf '%s' "$server" | sed -e 's|^https://||' -e 's|:.*$||' -e 's|/.*$||')"
port="$(printf '%s' "$server" | sed -n 's|^https://[^:/]*:\([0-9]*\).*$|\1|p')"
[ -n "$port" ] || port=6443

if command -v openssl >/dev/null 2>&1; then
    sans="$(openssl s_client -connect "127.0.0.1:$port" -servername "$host" </dev/null 2>/dev/null \
            | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)"
    if [ -n "$sans" ]; then
        if printf '%s' "$sans" | grep -qF "$host"; then
            note "API certificate covers $host"
        else
            note "WARNING: the API certificate does NOT list $host."
            note "Present SANs: $(printf '%s' "$sans" | tr -s ' \n' ' ')"
            note 'The Action will fail TLS verification. Fix on the server with:'
            note "  printf 'tls-san:\\n  - %s\\n' '$host' >> /etc/rancher/k3s/config.yaml"
            note '  systemctl restart k3s'
            note 'then re-run this script.'
        fi
    fi
fi

# --- pull the service account token ---------------------------------------
kube -n "$NS" get secret "$SECRET" >/dev/null 2>&1 \
    || fail "secret $NS/$SECRET not found - apply setup/rbac-ci.yaml first"

ca="$(kube -n "$NS" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}')"
token="$(kube -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)"
[ -n "$token" ] || fail 'the service account token is empty; wait a moment and retry'
[ -n "$ca" ] || fail 'could not read the cluster CA from the token secret'

kubeconfig="$(
    cat <<EOF
apiVersion: v1
kind: Config
current-context: otto-ci
clusters:
  - name: otto
    cluster:
      server: $server
      certificate-authority-data: $ca
contexts:
  - name: otto-ci
    context:
      cluster: otto
      namespace: $NS
      user: otto-ci
users:
  - name: otto-ci
    user:
      token: $token
EOF
)"

printf '%s\n' "$kubeconfig" | base64 | tr -d '\n'
printf '\n'
note ''
note "server: $server"
note '--- paste the line above into the KUBECONFIG repository secret ---'
