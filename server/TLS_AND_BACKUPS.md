# TLS, network exposure, and backups

## Internet exposure

Do not expose Uvicorn or TimescaleDB directly to the internet. Keep the Compose
port on loopback, terminate TLS in a maintained reverse proxy, and forward only
to `127.0.0.1:8080`. The API token protects the application route; TLS protects
the token and biometric data in transit.

Minimal Caddy configuration after DNS points to the server:

```caddyfile
noop.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:8080
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
    }
    request_body {
        max_size 10MB
    }
}
```

Use `https://noop.example.com` in the app. Restrict SSH, patch the host and proxy,
do not log `Authorization` headers, and rate-limit repeated authentication
failures at the proxy. If the service is only for one household, a private VPN
such as WireGuard/Tailscale is a smaller attack surface than a public hostname.

`--forwarded-allow-ips` in the Docker command trusts loopback only. If the proxy
runs outside the host network namespace, set that option to the exact proxy
address rather than `*`.

## Backups

The named Docker volume is the live database, not a backup. Create encrypted,
tested backups outside the host:

```sh
docker compose exec -T db \
  pg_dump --format=custom --no-owner --username=noop noop \
  > "noop-$(date +%F).dump"
```

Restore into a stopped/empty destination after preserving its current state:

```sh
docker compose exec -T db \
  pg_restore --clean --if-exists --no-owner --username=noop --dbname=noop \
  < noop-2026-07-24.dump
```

Test restoration periodically. Encrypt backup media because it contains
fine-grained biometric and journal data. Keep the database password, API token,
and backup encryption key separate.

## Updating

1. Export or back up the database.
2. Review application and TimescaleDB release notes.
3. Pull the intended source revision.
4. Run `docker compose build --pull`.
5. Run `docker compose up -d`.
6. Confirm `docker compose ps`, `/healthz`, authenticated `/v1/status`, and a
   fresh client sync.

Never use `docker compose down -v` during a routine update; `-v` deletes the
database volume.
