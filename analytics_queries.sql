-- Примеры запросов для аналитики загруженности клуба (SQLite, club_stats.db).

-- 1. Текущая загрузка клуба (последний опрос)
SELECT
    COUNT(*) AS total,
    SUM(busy) AS busy_now,
    ROUND(100.0 * SUM(busy) / COUNT(*), 1) AS busy_pct
FROM snapshots
WHERE polled_at = (SELECT MAX(polled_at) FROM snapshots);

-- 2. Средняя загрузка клуба по часам суток
SELECT
    strftime('%H', polled_at) AS hour,
    ROUND(100.0 * SUM(busy) / COUNT(*), 1) AS busy_pct
FROM snapshots
GROUP BY hour
ORDER BY hour;

-- 3. Средняя загрузка по дням недели
SELECT
    strftime('%w', polled_at) AS weekday,  -- 0=воскресенье ... 6=суббота
    ROUND(100.0 * SUM(busy) / COUNT(*), 1) AS busy_pct
FROM snapshots
GROUP BY weekday
ORDER BY weekday;

-- 4. Рейтинг мест по занятости (какие места используют чаще всего)
SELECT
    id,
    ROUND(100.0 * SUM(busy) / COUNT(*), 1) AS busy_pct,
    COUNT(*) AS snapshots_count
FROM snapshots
GROUP BY id
ORDER BY busy_pct DESC;

-- 5. Динамика загрузки по дням (для графика)
SELECT
    date(polled_at) AS day,
    ROUND(100.0 * SUM(busy) / COUNT(*), 1) AS busy_pct
FROM snapshots
GROUP BY day
ORDER BY day;

-- 6. Длительность каждого завершённого сеанса (busy 1 -> 0) по месту.
-- Начало сеанса - момент, когда место стало занято (busy=1),
-- конец - следующий зафиксированный переход по этому же месту.
WITH ordered AS (
    SELECT
        seat_id,
        busy,
        changed_at,
        LEAD(changed_at) OVER (PARTITION BY seat_id ORDER BY changed_at) AS next_changed_at
    FROM status_changes
)
SELECT
    seat_id,
    changed_at AS session_start,
    next_changed_at AS session_end,
    ROUND((strftime('%s', next_changed_at) - strftime('%s', changed_at)) / 60.0, 1) AS duration_minutes
FROM ordered
WHERE busy = 1 AND next_changed_at IS NOT NULL
ORDER BY seat_id, changed_at;

-- 7. Средняя и медианная (приблизительно) длительность сеанса по месту
WITH ordered AS (
    SELECT
        seat_id,
        busy,
        changed_at,
        LEAD(changed_at) OVER (PARTITION BY seat_id ORDER BY changed_at) AS next_changed_at
    FROM status_changes
),
sessions AS (
    SELECT
        seat_id,
        (strftime('%s', next_changed_at) - strftime('%s', changed_at)) / 60.0 AS duration_minutes
    FROM ordered
    WHERE busy = 1 AND next_changed_at IS NOT NULL
)
SELECT
    seat_id,
    COUNT(*) AS sessions_count,
    ROUND(AVG(duration_minutes), 1) AS avg_duration_minutes,
    ROUND(MIN(duration_minutes), 1) AS min_duration_minutes,
    ROUND(MAX(duration_minutes), 1) AS max_duration_minutes
FROM sessions
GROUP BY seat_id
ORDER BY seat_id;

-- 8. Место сейчас занято - сколько уже длится текущий сеанс
SELECT
    id AS seat_id,
    updated_at AS session_start,
    ROUND((strftime('%s', 'now') - strftime('%s', updated_at)) / 60.0, 1) AS running_minutes
FROM current_status
WHERE busy = 1
ORDER BY running_minutes DESC;
