"""
club_monitor / main.py

Опрашивает сервер компьютерного клуба (GET /api/v1/clients),
и сохраняет по каждому месту только то, что нужно для аналитики
загруженности: id места, занято ли оно и время опроса.

Запуск:
    python main.py                  # один опрос и выход
    python main.py --interval 60    # опрашивать каждые 60 секунд (демон-режим)

Настройка через переменные окружения (или файл .env, см. README.md):
    CLUB_HOST_URL   - базовый URL сервера, например https://your-host.example.com
    CLUB_API_KEY    - значение заголовка x-api-key
    CLUB_DB_PATH    - путь к файлу SQLite (по умолчанию club_stats.db)
"""

import argparse
import logging
import os
import sqlite3
import time
from datetime import datetime
from zoneinfo import ZoneInfo

import requests

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("club-monitor")

MOSCOW_TZ = ZoneInfo("Europe/Moscow")

HOST_URL = os.environ.get("CLUB_HOST_URL", "").rstrip("/")
API_KEY = os.environ.get("CLUB_API_KEY", "")
DB_PATH = os.environ.get("CLUB_DB_PATH", "club_stats.db")
REQUEST_TIMEOUT = 10

HEADERS = {
    "Accept": "application/json",
    "x-api-key": API_KEY,
}

SCHEMA = """
CREATE TABLE IF NOT EXISTS snapshots (
    id         INTEGER NOT NULL,  -- id места из API
    busy       INTEGER NOT NULL,  -- 1 = занято, 0 = свободно
    polled_at  TEXT NOT NULL      -- момент опроса, московское время, ISO-8601
);

CREATE INDEX IF NOT EXISTS idx_snapshots_time ON snapshots(polled_at);
CREATE INDEX IF NOT EXISTS idx_snapshots_id_time ON snapshots(id, polled_at);

-- Текущий (последний известный) статус каждого места.
-- Нужен, чтобы на каждом опросе понимать, изменился статус или нет.
CREATE TABLE IF NOT EXISTS current_status (
    id         INTEGER PRIMARY KEY,  -- id места
    busy       INTEGER NOT NULL,
    updated_at TEXT NOT NULL         -- когда этот статус установился, московское время
);

-- Журнал изменений статуса: одна строка = один переход "занято/свободно".
-- По ней удобно считать длительность сеансов.
CREATE TABLE IF NOT EXISTS status_changes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    seat_id    INTEGER NOT NULL,
    busy       INTEGER NOT NULL,  -- новое состояние после изменения
    changed_at TEXT NOT NULL      -- московское время
);

CREATE INDEX IF NOT EXISTS idx_status_changes_seat_time ON status_changes(seat_id, changed_at);
"""


def get_connection() -> sqlite3.Connection:
    return sqlite3.connect(DB_PATH)


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    conn.commit()


def fetch_clients() -> list:
    """Делает запрос к серверу и возвращает список объектов из поля data."""
    if not HOST_URL:
        raise RuntimeError("CLUB_HOST_URL не задан")
    url = f"{HOST_URL}/api/v1/clients"
    resp = requests.get(url, headers=HEADERS, timeout=REQUEST_TIMEOUT)
    resp.raise_for_status()
    payload = resp.json()
    return payload.get("data", [])


def insert_snapshot(conn: sqlite3.Connection, item: dict, polled_at: str) -> None:
    conn.execute(
        "INSERT INTO snapshots (id, busy, polled_at) VALUES (?, ?, ?)",
        (item["id"], 1 if item.get("busy") else 0, polled_at),
    )


def load_current_status(conn: sqlite3.Connection) -> dict:
    """Загружает последний известный статус каждого места в память,
    чтобы не ходить в БД на каждое место при каждом опросе."""
    rows = conn.execute("SELECT id, busy FROM current_status").fetchall()
    return {seat_id: busy for seat_id, busy in rows}


def track_status_change(
    conn: sqlite3.Connection,
    current_map: dict,
    seat_id: int,
    busy: int,
    polled_at: str,
) -> None:
    """Сравнивает новый статус места с последним известным.
    Если статус изменился (или место увидено впервые) - обновляет
    current_status и пишет строку в status_changes."""
    prev_busy = current_map.get(seat_id)

    if prev_busy is None:
        conn.execute(
            "INSERT INTO current_status (id, busy, updated_at) VALUES (?, ?, ?)",
            (seat_id, busy, polled_at),
        )
        conn.execute(
            "INSERT INTO status_changes (seat_id, busy, changed_at) VALUES (?, ?, ?)",
            (seat_id, busy, polled_at),
        )
        current_map[seat_id] = busy
    elif prev_busy != busy:
        conn.execute(
            "UPDATE current_status SET busy = ?, updated_at = ? WHERE id = ?",
            (busy, polled_at, seat_id),
        )
        conn.execute(
            "INSERT INTO status_changes (seat_id, busy, changed_at) VALUES (?, ?, ?)",
            (seat_id, busy, polled_at),
        )
        current_map[seat_id] = busy
    # иначе статус не изменился - ничего не делаем


def poll_once(conn: sqlite3.Connection, current_map: dict) -> None:
    # tzinfo сознательно убираем: SQLite сам переводит время со смещением
    # (+03:00) обратно в UTC внутри strftime()/date(), что сломало бы всю
    # аналитику по часам/дням. Храним "наивную" московскую строку.
    polled_at = datetime.now(MOSCOW_TZ).replace(tzinfo=None).isoformat(timespec="seconds")
    items = fetch_clients()

    changes = 0
    for item in items:
        seat_id = item["id"]
        busy = 1 if item.get("busy") else 0

        insert_snapshot(conn, item, polled_at)

        prev_busy = current_map.get(seat_id)
        track_status_change(conn, current_map, seat_id, busy, polled_at)
        if prev_busy is not None and prev_busy != busy:
            changes += 1

    conn.commit()

    busy_count = sum(1 for i in items if i.get("busy"))
    logger.info(
        "Опрос сохранён: всего=%d, занято=%d, изменений статуса=%d",
        len(items), busy_count, changes,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Опрос загруженности компьютерного клуба")
    parser.add_argument(
        "--interval", type=int, default=0,
        help="Интервал между опросами в секундах. 0 = один опрос и выход (по умолчанию)",
    )
    args = parser.parse_args()

    if not API_KEY:
        logger.warning("CLUB_API_KEY не задан - запросы, вероятно, будут отклонены сервером")

    conn = get_connection()
    init_db(conn)
    current_map = load_current_status(conn)

    try:
        if args.interval <= 0:
            poll_once(conn, current_map)
        else:
            while True:
                try:
                    poll_once(conn, current_map)
                except requests.RequestException as e:
                    logger.error("Ошибка запроса: %s", e)
                time.sleep(args.interval)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
