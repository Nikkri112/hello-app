# Тесты приложения: проверяем основные эндпоинты через test_client
# (сервер не запускается - Flask эмулирует запросы в памяти).
from main import app


def test_hello_returns_greeting():
    client = app.test_client()
    resp = client.get("/hello")
    assert resp.status_code == 200
    assert b"Hello World!" in resp.data


def test_hello_shows_pod_name():
    client = app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"(pod:" in resp.data


def test_health_returns_ok():
    client = app.test_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.data.strip() == b"OK"


def test_metrics_exposes_prometheus():
    client = app.test_client()
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert b"app_http_requests_total" in resp.data
