FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /service

COPY requirements.txt .
RUN pip install --no-cache-dir --requirement requirements.txt

RUN groupadd --system --gid 10001 noop \
    && useradd --system --uid 10001 --gid noop --home-dir /nonexistent noop

COPY app ./app
COPY migrations ./migrations

USER 10001:10001
EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--forwarded-allow-ips=127.0.0.1"]
