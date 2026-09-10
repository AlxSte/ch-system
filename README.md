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
    polled_at  TEXT NOT NULL      -- момент опроса, UTC ISO-8601
);
```

**`current_status`** — последний известный статус каждого места (по одной
строке на место). Используется программой, чтобы на каждом опросе
сравнить новый статус с предыдущим и понять, изменился ли он.

```sql
CREATE TABLE current_status (
    id         INTEGER PRIMARY KEY,  -- id места
    busy       INTEGER NOT NULL,
    updated_at TEXT NOT NULL         -- когда этот статус установился
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
    changed_at TEXT NOT NULL
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

## Установка

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
