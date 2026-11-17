import os
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST

app = FastAPI(title="POC DevOps API", version="1.0.0")

REQUEST_COUNT = Counter(
    "app_requests_total",
    "Total de requisicoes HTTP na aplicacao",
    ["endpoint", "method"],
)


@app.get("/")
def read_root():
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