# Estágio 1: Builder
FROM python:3.12.12-alpine3.22 AS builder

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip>=26.2.0 \
    && pip install --no-cache-dir -r requirements.txt \
    && rm -rf /opt/venv/lib/python*/site-packages/pip*

# Estágio 2: Runtime
FROM python:3.12.12-alpine3.22 AS runtime

LABEL org.opencontainers.image.title="poc-devops-api" \
      org.opencontainers.image.description="API FastAPI para POC Kubernetes Local"

ARG APP_VERSION=unknown

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

WORKDIR /app

RUN apk upgrade --no-cache \
    && rm -rf /usr/local/lib/python*/site-packages/pip* \
    && addgroup -S -g 1001 appgroup \
    && adduser -S -u 1001 -G appgroup appuser

COPY --from=builder /opt/venv /opt/venv
COPY --chown=appuser:appgroup src/ ./src/

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')" || exit 1

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
