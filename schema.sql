-- Схема БД для аналитики загруженности компьютерного клуба.
-- Одна таблица: id места, занято ли оно, момент опроса.

CREATE TABLE IF NOT EXISTS snapshots (
    id         INTEGER NOT NULL,  -- id места из API
    busy       INTEGER NOT NULL,  -- 1 = занято, 0 = свободно (в Postgres можно BOOLEAN)
    polled_at  TEXT NOT NULL      -- момент опроса, UTC ISO-8601 (в Postgres лучше TIMESTAMPTZ)
);

CREATE INDEX IF NOT EXISTS idx_snapshots_time ON snapshots(polled_at);
CREATE INDEX IF NOT EXISTS idx_snapshots_id_time ON snapshots(id, polled_at);

-- Текущий (последний известный) статус каждого места
CREATE TABLE IF NOT EXISTS current_status (
    id         INTEGER PRIMARY KEY,  -- id места
    busy       INTEGER NOT NULL,
    updated_at TEXT NOT NULL         -- когда этот статус установился
);

-- Журнал изменений статуса: одна строка = один переход "занято/свободно".
-- Используется для расчёта длительности сеансов.
CREATE TABLE IF NOT EXISTS status_changes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    seat_id    INTEGER NOT NULL,
    busy       INTEGER NOT NULL,  -- новое состояние после изменения
    changed_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_status_changes_seat_time ON status_changes(seat_id, changed_at);
