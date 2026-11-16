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


def test_metrics():
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "app_requests_total" in response.text