FROM python:3.12-alpine3.23@sha256:167bc85084c9df34480efc26b4528fb68feaa8a79183b5658952137025b6f061 AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NOOP_FORWARDED_ALLOW_IPS=127.0.0.1

WORKDIR /service

COPY requirements.txt requirements.lock ./
RUN pip install --no-cache-dir --require-hashes --requirement requirements.lock \
    && python -m pip uninstall --yes pip \
    && rm -rf /usr/local/lib/python3.12/ensurepip

RUN addgroup -g 10001 -S noop \
    && adduser -u 10001 -S -D -H -G noop noop

COPY app ./app
COPY migrations ./migrations
COPY migrations-postgresql ./migrations-postgresql
COPY NOTICE /usr/share/doc/noop/NOTICE
COPY LICENSE /usr/share/doc/noop/LICENSE

# Flatten the cleaned filesystem so removed package tooling is absent from runtime layers.
FROM scratch

ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NOOP_FORWARDED_ALLOW_IPS=127.0.0.1

WORKDIR /service
COPY --from=builder / /

USER 10001:10001
EXPOSE 8080

CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port 8080 --proxy-headers --forwarded-allow-ips \"$NOOP_FORWARDED_ALLOW_IPS\" --no-access-log"]
