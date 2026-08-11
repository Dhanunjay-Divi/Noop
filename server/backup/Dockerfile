FROM postgres:16-bookworm@sha256:64154d0babcb1741988719e703419af0382b19953706149f9872fbd0f438efa8

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /backups \
    && chown postgres:postgres /backups

COPY backup.sh backup-loop.sh backup-healthcheck.sh restore.sh restore-drill.sh /opt/noop/
COPY NOTICE /usr/share/doc/noop/NOTICE
COPY LICENSE /usr/share/doc/noop/LICENSE

USER postgres

CMD ["sh", "/opt/noop/backup-loop.sh"]
