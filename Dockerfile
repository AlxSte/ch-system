# club_monitor: опрос сервера клуба и запись в SQLite

FROM python:3.12-slim

WORKDIR /app

# Сначала зависимости - чтобы pip install кешировался отдельно от кода
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# Сюда будет смонтирован volume с базой данных (см. docker-compose.yml)
RUN mkdir -p /app/data

ENV CLUB_DB_PATH=/app/data/club_stats.db \
    CLUB_INTERVAL=60 \
    PYTHONUNBUFFERED=1

# PYTHONUNBUFFERED=1 - чтобы логи сразу попадали в `docker logs`,
# а не буферизовались внутри контейнера.

CMD ["sh", "-c", "python main.py --interval ${CLUB_INTERVAL}"]
