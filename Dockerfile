# Образ Python REST API на базе официального python (публичный базовый образ)
FROM python:3.12-slim

# Рабочая папка внутри контейнера
WORKDIR /app

# Сначала ставим зависимости (кэшируется, если requirements не менялся)
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Код приложения
COPY app/ .

# Непривилегированный юзер: контейнер не работает от root.
# Каталог логов создаём заранее и отдаём ему владельца
# (в рантайме он монтируется как emptyDir с fsGroup: 1000).
RUN useradd --uid 1000 --create-home appuser \
    && mkdir -p /var/log/app \
    && chown -R appuser:appuser /var/log/app

USER 1000

# Порт >1024: непривилегированный юзер не может биндить 80 без CAP_NET_BIND_SERVICE
EXPOSE 8080

# Запуск через gunicorn (1 воркер - для простоты и корректных метрик)
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "main:app"]
