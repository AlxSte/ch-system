-- Схема БД для аналитики загруженности компьютерного клуба.
-- Все временные поля хранят московское время без смещения (naive local time),
-- чтобы strftime()/date() в SQLite не переводили его обратно в UTC.

CREATE TABLE IF NOT EXISTS snapshots (
    id         INTEGER NOT NULL,  -- id места из API
    busy       INTEGER NOT NULL,  -- 1 = занято, 0 = свободно (в Postgres можно BOOLEAN)
    polled_at  TEXT NOT NULL      -- момент опроса, московское время без смещения (в Postgres - TIMESTAMP, не TIMESTAMPTZ)
);

CREATE INDEX IF NOT EXISTS idx_snapshots_time ON snapshots(polled_at);
CREATE INDEX IF NOT EXISTS idx_snapshots_id_time ON snapshots(id, polled_at);

-- Текущий (последний известный) статус каждого места
CREATE TABLE IF NOT EXISTS current_status (
    id         INTEGER PRIMARY KEY,  -- id места
    busy       INTEGER NOT NULL,
    updated_at TEXT NOT NULL         -- когда этот статус установился, московское время
);

-- Журнал изменений статуса: одна строка = один переход "занято/свободно".
-- Используется для расчёта длительности сеансов.
CREATE TABLE IF NOT EXISTS status_changes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    seat_id    INTEGER NOT NULL,
    busy       INTEGER NOT NULL,  -- новое состояние после изменения
    changed_at TEXT NOT NULL         -- московское время
);

CREATE INDEX IF NOT EXISTS idx_status_changes_seat_time ON status_changes(seat_id, changed_at);
