-- Схема БД для аналитики загруженности сети компьютерных клубов.
-- Одна база на все клубы, каждая запись помечена club_id (см. README,
-- раздел "Несколько клубов" - почему выбрана эта схема, а не БД на клуб).
--
-- Все временные поля хранят московское время без смещения (naive local time),
-- чтобы strftime()/date() в SQLite не переводили его обратно в UTC.

-- Справочник клубов (только для читаемых названий в аналитике)
CREATE TABLE IF NOT EXISTS clubs (
    id   TEXT PRIMARY KEY,
    name TEXT NOT NULL
);

-- Текущий (последний известный) статус каждого места в каждом клубе
CREATE TABLE IF NOT EXISTS current_status (
    club_id    TEXT NOT NULL REFERENCES clubs(id),
    id         INTEGER NOT NULL,
    busy       INTEGER NOT NULL,
    updated_at TEXT NOT NULL,        -- когда этот статус установился, московское время
    PRIMARY KEY (club_id, id)
);

-- Журнал изменений статуса: одна строка = один переход "занято/свободно"
-- в конкретном клубе. Используется для расчёта длительности сеансов.
CREATE TABLE IF NOT EXISTS status_changes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    club_id    TEXT NOT NULL REFERENCES clubs(id),
    seat_id    INTEGER NOT NULL,
    busy       INTEGER NOT NULL,  -- новое состояние после изменения
    changed_at TEXT NOT NULL      -- московское время
);

CREATE INDEX IF NOT EXISTS idx_status_changes_club_seat_time ON status_changes(club_id, seat_id, changed_at);

-- Примечания при переносе на PostgreSQL:
--   * id в status_changes -> GENERATED ALWAYS AS IDENTITY
--   * polled_at, updated_at, changed_at -> TIMESTAMP
--   * busy -> BOOLEAN
--   * ON CONFLICT(id) DO UPDATE в main.py работает и в Postgres без изменений
