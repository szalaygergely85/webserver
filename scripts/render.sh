#!/usr/bin/env sh
# Renders k8s/*.yaml to stdout with the four deployment-specific placeholders
# filled in. Pipe it straight into kubectl:
#
#   ./scripts/render.sh | kubectl apply -f -
#
# Substitution is done with sed against an explicit list rather than envsubst,
# so the nginx ConfigMap's own $uri / $host variables are left alone.
set -eu

fail() { printf 'render.sh: %s\n' "$*" >&2; exit 1; }

[ -n "${SFTP_IMAGE:-}" ] || fail 'SFTP_IMAGE is not set (e.g. docker.io/you/otto-sftp:abc123)'
[ -n "${NODE_NAME:-}" ] || fail 'NODE_NAME is not set (kubectl get nodes -o name)'
SITE_HOST_PATH="${SITE_HOST_PATH:-/srv/otto}"
# resourceVersion of the credentials secret; changing it rolls a new pod so the
# entrypoint re-reads them. "none" is fine for a first deploy.
CREDS_VERSION="${CREDS_VERSION:-none}"

case "$SITE_HOST_PATH" in
    /*) ;;
    *) fail "SITE_HOST_PATH must be an absolute path, got '$SITE_HOST_PATH'" ;;
esac

# `|` is the sed delimiter below, so no value may contain one.
for value in "$SFTP_IMAGE" "$NODE_NAME" "$SITE_HOST_PATH" "$CREDS_VERSION"; do
    case "$value" in
        *"|"*) fail "values must not contain '|': $value" ;;
    esac
done

# Emptied so a CDPATH set in the caller's environment cannot make `cd` land
# somewhere other than the repo root. Assigned separately rather than as a
# `CDPATH= cd ...` prefix, which shellcheck cannot distinguish from a typo.
CDPATH=''
dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"

for file in "$dir"/k8s/*.yaml; do
    [ -f "$file" ] || continue
    printf -- '---\n'
    sed \
        -e "s|\${SFTP_IMAGE}|$SFTP_IMAGE|g" \
        -e "s|\${NODE_NAME}|$NODE_NAME|g" \
        -e "s|\${SITE_HOST_PATH}|$SITE_HOST_PATH|g" \
        -e "s|\${CREDS_VERSION}|$CREDS_VERSION|g" \
        "$file"
done

# Anything left unsubstituted is a placeholder we forgot about - fail loudly
# rather than shipping a literal "${FOO}" into the cluster. The single quotes
# below are deliberate: these patterns match the literal text "${NAME}".
# shellcheck disable=SC2016
if grep -l '\${[A-Z_]\{1,\}}' "$dir"/k8s/*.yaml >/dev/null 2>&1; then
    remaining="$(
        for file in "$dir"/k8s/*.yaml; do
            sed \
                -e "s|\${SFTP_IMAGE}||g" -e "s|\${NODE_NAME}||g" \
                -e "s|\${SITE_HOST_PATH}||g" -e "s|\${CREDS_VERSION}||g" \
                "$file"
        done | grep -o '\${[A-Z_]\{1,\}}' | sort -u | tr '\n' ' '
    )"
    [ -z "$remaining" ] || fail "unresolved placeholders: $remaining"
fi
