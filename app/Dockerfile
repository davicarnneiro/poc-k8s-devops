# Estágio 1: Builder (instala dependências em virtualenv isolado)
FROM python:3.12.8-alpine3.21 AS builder

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip==24.3.1 \
    && pip install --no-cache-dir -r requirements.txt

# Estágio 2: Runtime (imagem final mínima e non-root)
FROM python:3.12.8-alpine3.21 AS runtime

LABEL org.opencontainers.image.title="poc-devops-api" \
      org.opencontainers.image.description="API FastAPI para POC Kubernetes Local"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# Cria usuário e grupo non-root
RUN addgroup -S -g 1001 appgroup \
    && adduser -S -u 1001 -G appgroup appuser

COPY --from=builder /opt/venv /opt/venv
COPY --chown=appuser:appgroup src/ ./src/

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')" || exit 1

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]