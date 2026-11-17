import itertools
import os
import time

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

app = FastAPI(title="POC DevOps API", version="1.0.0")

# Contador de negocio (por endpoint)
REQUEST_COUNT = Counter(
    "app_requests_total",
    "Total de requisicoes HTTP na aplicacao",
    ["endpoint", "method"],
)

# Metricas HTTP genericas (usadas pelo dashboard e pelos alertas)
HTTP_REQUESTS = Counter(
    "http_requests_total",
    "Total de requisicoes HTTP",
    ["method", "path", "status"],
)
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Latencia das requisicoes HTTP em segundos",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5),
)


@app.middleware("http")
async def collect_metrics(request: Request, call_next):
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        # Usa o template da rota (ex.: "/") e nao a URL crua, para nao explodir a cardinalidade
        route = request.scope.get("route")
        path = route.path if route else "unmatched"
        HTTP_REQUESTS.labels(request.method, path, str(status)).inc()
        HTTP_LATENCY.labels(request.method, path).observe(time.perf_counter() - start)


_REQUEST_SEQ = itertools.count(1)


def _error_rate() -> float:
    """Fracao (0 a 1) de requisicoes a "/" que falham. Usada so para DEMONSTRAR o rollback automatico."""
    try:
        return min(max(float(os.getenv("APP_ERROR_RATE", "0")), 0.0), 1.0)
    except ValueError:
        return 0.0


def _should_fail() -> bool:
    """Decisao deterministica (sem aleatoriedade): com taxa 0.5 falha 1 a cada 2 requisicoes, etc."""
    rate = _error_rate()
    n = next(_REQUEST_SEQ)
    return int(n * rate) > int((n - 1) * rate)


@app.get("/", responses={500: {"description": "Erro simulado (APP_ERROR_RATE), usado na demo de rollback automatico"}})
def read_root():
    if _should_fail():
        raise HTTPException(status_code=500, detail="erro simulado (APP_ERROR_RATE)")
    REQUEST_COUNT.labels(endpoint="/", method="GET").inc()
    return {
        "service": "poc-devops-api",
        "environment": os.getenv("APP_ENV", "local"),
        "message": os.getenv("APP_MESSAGE", "Kubernetes Local POC rodando!"),
        "secret_loaded": bool(os.getenv("API_TOKEN")),
    }


@app.get("/healthz")
def health_check():
    return {"status": "healthy"}


@app.get("/metrics")
def metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)
