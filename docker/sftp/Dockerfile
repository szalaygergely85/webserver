FROM alpine:3.20

RUN apk add --no-cache openssh-server tini \
    && mkdir -p /var/empty /etc/ssh/keys /etc/ssh/authorized_keys \
    && chmod 0755 /var/empty /etc/ssh/authorized_keys \
    && chmod 0700 /etc/ssh/keys \
    && rm -f /etc/ssh/ssh_host_*

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh && chmod 0644 /etc/ssh/sshd_config

EXPOSE 22

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
