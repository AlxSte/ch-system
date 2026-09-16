# club_monitor

Опрашивает сервер бронирования мест в компьютерном клубе
(`GET /api/v1/clients`) и складывает в SQLite минимум, нужный для
аналитики загруженности: **id места, занято ли оно, время опроса**.

## Схема БД

**`snapshots`** — сырой лог: одна строка на каждое место при каждом опросе.
Нужна для аналитики загруженности по времени (часы, дни недели, по местам).

```sql
CREATE TABLE snapshots (
    id         INTEGER NOT NULL,  -- id места из API
    busy       INTEGER NOT NULL,  -- 1 = занято, 0 = свободно
    polled_at  TEXT NOT NULL      -- момент опроса, московское время
);
```

**`current_status`** — последний известный статус каждого места (по одной
строке на место). Используется программой, чтобы на каждом опросе
сравнить новый статус с предыдущим и понять, изменился ли он.

```sql
CREATE TABLE current_status (
    id         INTEGER PRIMARY KEY,  -- id места
    busy       INTEGER NOT NULL,
    updated_at TEXT NOT NULL         -- когда этот статус установился, московское время
);
```

**`status_changes`** — журнал переходов "занято ↔ свободно": новая строка
добавляется только тогда, когда статус места реально изменился. По этой
таблице удобно считать длительность сеансов (см. `analytics_queries.sql`,
запросы 6-8).

```sql
CREATE TABLE status_changes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    seat_id    INTEGER NOT NULL,
    busy       INTEGER NOT NULL,  -- новое состояние после изменения
    changed_at TEXT NOT NULL         -- московское время
);
```

Как это работает: при каждом опросе `main.py` держит в памяти словарь
`{id места: текущий busy}` (загружается из `current_status` при старте).
Если пришедший статус отличается от того, что в словаре, - место
считается впервые увиденным или сменившим состояние, и тогда:
1. `current_status` обновляется новым значением;
2. в `status_changes` добавляется строка с моментом перехода.

Если статус не изменился - `status_changes` не растёт, растёт только
`snapshots` (сырой лог опросов).

## Часовой пояс

Все временные метки (`polled_at`, `updated_at`, `changed_at`) пишутся в
московском времени (`Europe/Moscow`, сейчас фиксированный UTC+3).
Хранятся они **без смещения** (`2026-09-10T14:22:25`, а не `...+03:00`)
намеренно: если оставить смещение, SQLite при вызовах `strftime()`/
`date()` в аналитике сам переведёт время обратно в UTC, и все запросы по
часам/дням окажутся сдвинуты на 3 часа.

Если в своём SQL нужно сравнить со временем на сервере СУБД (например,
`strftime('%s', 'now')`) - помните, что `'now'` в SQLite всегда в UTC,
поэтому такие сравнения нужно явно сдвигать на 3 часа
(`strftime('%s', 'now', '+3 hours')`) - пример есть в запросе №8 в
`analytics_queries.sql`.

## Запуск через Docker

Проект уже готов к запуску контейнером — есть `Dockerfile` и
`docker-compose.yml`. Это удобнее, чем cron: контейнер сам работает в
демон-режиме (`--interval`) и перезапускается при сбоях/перезагрузке
сервера.

1. Скопируйте `.env.example` в `.env` и заполните:

   ```bash
   cp .env.example .env
   ```

   ```
   CLUB_HOST_URL=https://ваш-хост
   CLUB_API_KEY=ваш_x-api-key
   CLUB_INTERVAL=60
   ```

2. Соберите и запустите:

   ```bash
   docker compose up -d --build
   ```

3. База данных SQLite сохраняется на хосте в `./data/club_stats.db` —
   это volume, он переживает пересборку и перезапуск контейнера.
   `CLUB_DB_PATH` внутри контейнера уже настроен в `Dockerfile`
   (`/app/data/club_stats.db`) и обычно менять его не нужно.

4. Полезные команды:

   ```bash
   docker compose logs -f          # логи опросов в реальном времени
   docker compose restart          # перезапуск (например, после смены .env)
   docker compose down             # остановить и удалить контейнер (данные в ./data останутся)
   ```

5. Аналитику при этом можно снимать прямо с файла на хосте, без входа в
   контейнер:

   ```bash
   sqlite3 data/club_stats.db < analytics_queries.sql
   ```

   Либо через контейнер: `docker compose exec club_monitor sqlite3 /app/data/club_stats.db`
   (если нужно, `sqlite3` можно добавить в образ через `apt-get install -y sqlite3` в `Dockerfile`
   — в базовом образе его нет, но для запросов с хоста он и не требуется).

## Установка без Docker (venv + cron)

Если Docker не нужен и вы хотите запускать скрипт напрямую на хосте:

```bash
cd club_monitor
python -m venv venv
source venv/bin/activate      # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

## Настройка

Файл `.env` рядом с `main.py`:

```
CLUB_HOST_URL=https://ваш-хост
CLUB_API_KEY=ваш_x-api-key
CLUB_DB_PATH=club_stats.db
```

## Запуск

Один опрос (для cron):

```bash
python main.py
```

Демон-режим с интервалом:

```bash
python main.py --interval 60
```

### cron (раз в минуту)

```
* * * * * cd /path/to/club_monitor && /path/to/venv/bin/python main.py >> monitor.log 2>&1
```

## Аналитика

Готовые запросы — в `analytics_queries.sql`: текущая загрузка, средняя
загрузка по часам/дням недели, рейтинг мест, динамика по дням, а также
длительность отдельных сеансов, средняя/мин/макс длительность по месту
и сколько уже длится сеанс на занятых прямо сейчас местах.

```bash
sqlite3 club_stats.db < analytics_queries.sql
```
