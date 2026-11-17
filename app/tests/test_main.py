from fastapi.testclient import TestClient

from src.main import app

client = TestClient(app)


def test_healthz():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "healthy"}


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    data = response.json()
    assert data["service"] == "poc-devops-api"
    assert "environment" in data


def test_root_uses_env(monkeypatch):
    monkeypatch.setenv("APP_ENV", "teste")
    monkeypatch.setenv("APP_MESSAGE", "ola")
    monkeypatch.setenv("API_TOKEN", "x")
    data = client.get("/").json()
    assert data["environment"] == "teste"
    assert data["message"] == "ola"
    assert data["secret_loaded"] is True


def test_metrics():
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "app_requests_total" in response.text


def test_http_metrics_are_recorded():
    client.get("/healthz")
    body = client.get("/metrics").text
    assert 'http_requests_total{method="GET",path="/healthz",status="200"}' in body
    assert "http_request_duration_seconds_bucket" in body


def test_unknown_route_does_not_create_label_per_url():
    client.get("/nao-existe-123")
    body = client.get("/metrics").text
    assert 'path="unmatched",status="404"' in body
    assert "/nao-existe-123" not in body


def test_error_rate_one_always_fails(monkeypatch):
    monkeypatch.setenv("APP_ERROR_RATE", "1")
    assert client.get("/").status_code == 500
    # health check nao e afetado
    assert client.get("/healthz").status_code == 200


def test_error_rate_invalid_value_is_ignored(monkeypatch):
    monkeypatch.setenv("APP_ERROR_RATE", "abc")
    assert client.get("/").status_code == 200
