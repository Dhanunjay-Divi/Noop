FROM python:3.12-slim-bookworm@sha256:782412e85d0f0984994c290652577d4018aff08145c85b262bb63dc0c7522254

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NOOP_FORWARDED_ALLOW_IPS=127.0.0.1

WORKDIR /service

COPY requirements.txt requirements.lock ./
RUN pip install --no-cache-dir --require-hashes --requirement requirements.lock

RUN groupadd --system --gid 10001 noop \
    && useradd --system --uid 10001 --gid noop --home-dir /nonexistent noop

COPY app ./app
COPY migrations ./migrations
COPY migrations-postgresql ./migrations-postgresql
COPY NOTICE /usr/share/doc/noop/NOTICE
COPY LICENSE /usr/share/doc/noop/LICENSE

USER 10001:10001
EXPOSE 8080

CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port 8080 --proxy-headers --forwarded-allow-ips \"$NOOP_FORWARDED_ALLOW_IPS\" --no-access-log"]
