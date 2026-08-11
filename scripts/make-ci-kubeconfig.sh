#!/usr/bin/env sh
# Builds a namespace-scoped kubeconfig for the GitHub Action and prints it
# base64-encoded, ready to paste into the KUBECONFIG repository secret.
# (The workflow accepts base64 or raw YAML; base64 is just safer to paste.)
#
# Entirely optional - if you already have a working KUBECONFIG secret for this
# cluster, reuse it and skip this script.
#
# Prerequisites (run once, as an admin):
#   kubectl apply -f k8s/00-namespace.yaml
#   kubectl apply -f setup/rbac-ci.yaml
#
# Usage:
#   ./scripts/make-ci-kubeconfig.sh                       # uses current context's server URL
#   API_SERVER=https://k8s.example.com:6443 ./scripts/make-ci-kubeconfig.sh
set -eu

NS=otto
SECRET=otto-ci-token

fail() { printf 'make-ci-kubeconfig.sh: %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || fail 'kubectl not found'

server="${API_SERVER:-$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')}"
[ -n "$server" ] || fail 'could not determine the API server URL; set API_SERVER'

case "$server" in
    *127.0.0.1*|*localhost*)
        fail "API server is $server - GitHub runners cannot reach that.
Set API_SERVER to the address reachable from the internet, e.g.
  API_SERVER=https://your.server:6443 $0"
        ;;
esac

kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1 \
    || fail "secret $NS/$SECRET not found - apply setup/rbac-ci.yaml first"

ca="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}')"
token="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)"
[ -n "$token" ] || fail 'the service account token is empty; give the secret a moment and retry'

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
printf '\n--- paste the line above into the KUBECONFIG repository secret ---\n' >&2
