-- Примеры запросов для аналитики загруженности сети клубов (SQLite, club_stats.db).
-- Все запросы разбиты по club_id; там, где полезно, добавлен JOIN на clubs
-- для читаемого названия.

-- 1. Длительность каждого завершённого сеанса (busy 1 -> 0) по месту,
-- в разрезе клуба. Начало сеанса - момент, когда место стало занято,
-- конец - следующий переход по этому же месту в этом же клубе.
WITH ordered AS (
    SELECT
        club_id,
        seat_id,
        busy,
        changed_at,
        LEAD(changed_at) OVER (PARTITION BY club_id, seat_id ORDER BY changed_at) AS next_changed_at
    FROM status_changes
)
SELECT
    club_id,
    seat_id,
    changed_at AS session_start,
    next_changed_at AS session_end,
    ROUND((strftime('%s', next_changed_at) - strftime('%s', changed_at)) / 60.0, 1) AS duration_minutes
FROM ordered
WHERE busy = 1 AND next_changed_at IS NOT NULL
ORDER BY club_id, seat_id, changed_at;

-- 2. Средняя/мин/макс длительность сеанса по месту, в разрезе клуба
WITH ordered AS (
    SELECT
        club_id,
        seat_id,
        busy,
        changed_at,
        LEAD(changed_at) OVER (PARTITION BY club_id, seat_id ORDER BY changed_at) AS next_changed_at
    FROM status_changes
),
sessions AS (
    SELECT
        club_id,
        seat_id,
        (strftime('%s', next_changed_at) - strftime('%s', changed_at)) / 60.0 AS duration_minutes
    FROM ordered
    WHERE busy = 1 AND next_changed_at IS NOT NULL
)
SELECT
    club_id,
    seat_id,
    COUNT(*) AS sessions_count,
    ROUND(AVG(duration_minutes), 1) AS avg_duration_minutes,
    ROUND(MIN(duration_minutes), 1) AS min_duration_minutes,
    ROUND(MAX(duration_minutes), 1) AS max_duration_minutes
FROM sessions
GROUP BY club_id, seat_id
ORDER BY club_id, seat_id;

-- 2b. Средняя длительность сеанса по клубу целиком (сравнение клубов)
WITH ordered AS (
    SELECT
        club_id,
        seat_id,
        busy,
        changed_at,
        LEAD(changed_at) OVER (PARTITION BY club_id, seat_id ORDER BY changed_at) AS next_changed_at
    FROM status_changes
)
SELECT
    club_id,
    COUNT(*) AS sessions_count,
    ROUND(AVG((strftime('%s', next_changed_at) - strftime('%s', changed_at)) / 60.0), 1) AS avg_duration_minutes
FROM ordered
WHERE busy = 1 AND next_changed_at IS NOT NULL
GROUP BY club_id
ORDER BY club_id;

-- 3. Места, занятые прямо сейчас - сколько уже длится сеанс.
-- Время в таблицах московское (без смещения), а 'now' в SQLite - всегда
-- UTC, поэтому явно прибавляем 3 часа для корректного сравнения.
SELECT
    club_id,
    id AS seat_id,
    updated_at AS session_start,
    ROUND(
        (strftime('%s', 'now', '+3 hours') - strftime('%s', updated_at)) / 60.0,
        1
    ) AS running_minutes
FROM current_status
WHERE busy = 1
ORDER BY club_id, running_minutes DESC;
