-- Примеры запросов для аналитики загруженности сети клубов (SQLite, club_stats.db).
-- Все запросы разбиты по club_id; там, где полезно, добавлен JOIN на clubs
-- для читаемого названия.

-- 1. Текущая загрузка по каждому клубу (последний опрос в каждом клубе)
SELECT
    c.name AS club,
    s.club_id,
    COUNT(*) AS total,
    SUM(s.busy) AS busy_now,
    ROUND(100.0 * SUM(s.busy) / COUNT(*), 1) AS busy_pct
FROM snapshots s
JOIN clubs c ON c.id = s.club_id
JOIN (
    SELECT club_id, MAX(polled_at) AS last_polled_at
    FROM snapshots
    GROUP BY club_id
) last ON last.club_id = s.club_id AND last.last_polled_at = s.polled_at
GROUP BY s.club_id;

-- 2. Средняя загрузка по часам суток, отдельно по каждому клубу
SELECT
    club_id,
    strftime('%H', polled_at) AS hour,
    ROUND(100.0 * SUM(busy) / COUNT(*), 1) AS busy_pct
FROM snapshots
GROUP BY club_id, hour
ORDER BY club_id, hour;

-- 3. Средняя загрузка по дням недели, отдельно по каждому клубу
SELECT
    club_id,
    strftime('%w', polled_at) AS weekday,  -- 0=воскресенье ... 6=суббота
    ROUND(100.0 * SUM(busy) / COUNT(*), 1) AS busy_pct
FROM snapshots
GROUP BY club_id, weekday
ORDER BY club_id, weekday;

-- 4. Рейтинг мест по занятости внутри каждого клуба
SELECT
    club_id,
    id AS seat_id,
    ROUND(100.0 * SUM(busy) / COUNT(*), 1) AS busy_pct,
    COUNT(*) AS snapshots_count
FROM snapshots
GROUP BY club_id, id
ORDER BY club_id, busy_pct DESC;

-- 5. Динамика загрузки по дням, отдельно по каждому клубу (для графика)
SELECT
    club_id,
    date(polled_at) AS day,
    ROUND(100.0 * SUM(busy) / COUNT(*), 1) AS busy_pct
FROM snapshots
GROUP BY club_id, day
ORDER BY club_id, day;

-- 5b. То же самое, но сравнение клубов между собой по дням (загрузка сети в целом)
SELECT
    date(polled_at) AS day,
    ROUND(100.0 * SUM(busy) / COUNT(*), 1) AS busy_pct_all_clubs
FROM snapshots
GROUP BY day
ORDER BY day;

-- 6. Длительность каждого завершённого сеанса (busy 1 -> 0) по месту,
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

-- 7. Средняя/мин/макс длительность сеанса по месту, в разрезе клуба
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

-- 7b. Средняя длительность сеанса по клубу целиком (сравнение клубов)
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

-- 8. Места, занятые прямо сейчас - сколько уже длится сеанс.
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
