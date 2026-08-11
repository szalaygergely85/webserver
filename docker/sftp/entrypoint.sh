#!/bin/sh
# Prepares host keys, the sftp account and its credentials, then hands off to
# sshd. Everything here is idempotent: the pod can be recreated at will.
set -eu

USER_NAME="${SFTP_USER:-web}"
USER_UID="${SFTP_UID:-1000}"
USER_GID="${SFTP_GID:-1000}"
KEY_DIR=/etc/ssh/keys
CRED_DIR=/etc/sftp
UPLOAD_DIR=public

log() { printf '[sftp] %s\n' "$*"; }

# --- host keys -------------------------------------------------------------
mkdir -p "$KEY_DIR"
chown root:root "$KEY_DIR"
chmod 0700 "$KEY_DIR"
for type in ed25519 rsa; do
    key="$KEY_DIR/ssh_host_${type}_key"
    if [ ! -f "$key" ]; then
        log "generating $type host key"
        ssh-keygen -q -t "$type" -f "$key" -N '' -C ''
    fi
    chmod 0600 "$key"
    if [ -f "$key.pub" ]; then
        chmod 0644 "$key.pub"
    fi
done
log "host key fingerprint: $(ssh-keygen -lf "$KEY_DIR/ssh_host_ed25519_key.pub" 2>/dev/null || echo unknown)"

# --- account ---------------------------------------------------------------
if ! getent group "$USER_NAME" >/dev/null 2>&1; then
    addgroup -g "$USER_GID" "$USER_NAME"
fi
if ! getent passwd "$USER_NAME" >/dev/null 2>&1; then
    # -H: no home is created here, it is the mounted volume.
    # -D: no password, so the account starts locked for password auth.
    adduser -D -H -u "$USER_UID" -G "$USER_NAME" \
        -h "/home/$USER_NAME" -s /sbin/nologin "$USER_NAME"
    log "created account $USER_NAME (uid $USER_UID)"
fi

# --- credentials -----------------------------------------------------------
have_auth=0

if [ -s "$CRED_DIR/password" ]; then
    # tr strips the trailing newline editors and `echo` leave behind
    password="$(head -n 1 "$CRED_DIR/password" | tr -d '\r\n')"
    printf '%s:%s\n' "$USER_NAME" "$password" | chpasswd
    unset password
    log "password authentication enabled"
    have_auth=1
fi

mkdir -p /etc/ssh/authorized_keys
chmod 0755 /etc/ssh/authorized_keys
if [ -s "$CRED_DIR/authorized_keys" ]; then
    install -m 0644 -o root -g root \
        "$CRED_DIR/authorized_keys" "/etc/ssh/authorized_keys/$USER_NAME"
    log "public key authentication enabled ($(grep -c . "$CRED_DIR/authorized_keys" || true) key(s))"
    have_auth=1
else
    rm -f "/etc/ssh/authorized_keys/$USER_NAME"
fi

if [ "$have_auth" -eq 0 ]; then
    log "WARNING: no password and no authorized_keys in $CRED_DIR - nobody can log in."
    log "WARNING: create the otto-sftp-auth secret, then restart the pod."
fi

# --- chroot layout ---------------------------------------------------------
# sshd refuses to chroot into a directory that is not root-owned and
# not group/world writable, so the writable area is one level down.
chown root:root "/home/$USER_NAME"
chmod 0755 "/home/$USER_NAME"
mkdir -p "/home/$USER_NAME/$UPLOAD_DIR"
chown "$USER_UID:$USER_GID" "/home/$USER_NAME/$UPLOAD_DIR"
chmod 0755 "/home/$USER_NAME/$UPLOAD_DIR"

log "ready - uploads go to /$UPLOAD_DIR once connected"
exec /usr/sbin/sshd -D -e
