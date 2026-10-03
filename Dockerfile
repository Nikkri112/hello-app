# Образ Python REST API на базе официального python (публичный базовый образ)
FROM python:3.12-slim

# Рабочая папка внутри контейнера
WORKDIR /app

# Сначала ставим зависимости (кэшируется, если requirements не менялся)
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Код приложения
COPY app/ .

# Каталог для access-логов
RUN mkdir -p /var/log/app

# Приложение слушает 80 порт
EXPOSE 80

# Запуск через gunicorn (1 воркер - для простоты и корректных метрик)
CMD ["gunicorn", "--bind", "0.0.0.0:80", "--workers", "1", "main:app"]
