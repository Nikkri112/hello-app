# Простое REST API на Flask:
# 1) отдаёт проверяемый ответ Hello World!
# 2) пишет access-логи (stdout + файл)
# 3) отдаёт метрики для Prometheus (/metrics)
import os
import time

from flask import Flask, Response, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

app = Flask(__name__)

# Метрики для Prometheus
REQUESTS = Counter(
    "app_http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)
LATENCY = Histogram(
    "app_http_request_duration_seconds",
    "Request duration in seconds",
    ["method", "endpoint"],
)

# Файл access-логов внутри контейнера (дубль stdout, удобно для сборщиков)
LOG_FILE = "/var/log/app/access.log"


@app.after_request
def log_request(response):
    # Логируем каждый запрос в формате, похожем на nginx:
    # IP - [дата] "GET /hello HTTP/1.1" 200 13
    # Проверки Kubernetes (/health) и /metrics не логируем, чтобы не мусорить
    if request.path not in ("/health", "/metrics"):
        started = time.time()
        line = (
            f'{request.remote_addr} - [{time.strftime("%d/%b/%Y:%H:%M:%S %z")}] '
            f'"{request.method} {request.path} '
            f'{request.environ.get("SERVER_PROTOCOL", "HTTP/1.1")}" '
            f"{response.status_code} {response.calculate_content_length()}"
        )
        # stdout -> попадает в kubectl logs и в /var/log/containers на ноде
        print(line, flush=True)
        # файл внутри контейнера -> можно забрать сборщиком логов.
        # Если каталог недоступен (нет прав/маунта) - не роняем запрос:
        # лог в stdout всё равно пишется, метрики всё равно считаются
        try:
            os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass
        REQUESTS.labels(request.method, request.path, response.status_code).inc()
        LATENCY.labels(request.method, request.path).observe(time.time() - started)
    return response


@app.route("/")
@app.route("/hello")
def hello():
    # Главный проверяемый ответ: Hello World!
    # HOSTNAME в поде Kubernetes = имя пода
    pod = os.environ.get("HOSTNAME", "unknown")
    return f"Привет мир! (pod: {pod})\n"


@app.route("/health")
def health():
    # Проверка живости для Kubernetes (liveness/readiness probe)
    return "OK\n"


@app.route("/metrics")
def metrics():
    # Эндпоинт для Prometheus
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
