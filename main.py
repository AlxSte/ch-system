"""
club_monitor / main.py

Опрашивает несколько серверов клубов (каждый - GET /api/v1/clients)
ПАРАЛЛЕЛЬНО и сохраняет данные в одну SQLite-базу, помечая каждую
запись club_id - чтобы можно было анализировать как отдельный клуб,
так и сравнивать клубы между собой.

Список клубов задаётся файлом clubs.json (см. clubs.json.example).
Для обратной совместимости с версией "один клуб": если clubs.json нет,
используется один клуб из переменных окружения CLUB_ID/CLUB_HOST_URL/CLUB_API_KEY.

Запуск:
    python main.py                  # один опрос всех клубов и выход
    python main.py --interval 60    # опрашивать каждые 60 секунд (демон-режим)

Переменные окружения:
    CLUBS_CONFIG_FILE  - путь к JSON-файлу с клубами (по умолчанию clubs.json)
    CLUB_DB_PATH       - путь к файлу SQLite (по умолчанию club_stats.db)
    CLUB_ID/CLUB_HOST_URL/CLUB_API_KEY - fallback на один клуб, если файла нет
"""

import argparse
import json
import logging
import os
import sqlite3
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
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

CONFIG_FILE = os.environ.get("CLUBS_CONFIG_FILE", "clubs.json")
DB_PATH = os.environ.get("CLUB_DB_PATH", "club_stats.db")
REQUEST_TIMEOUT = 10


@dataclass
class Club:
    id: str
    host_url: str
    api_key: str
    name: str = ""

    @property
    def headers(self) -> dict:
        return {"Accept": "application/json", "x-api-key": self.api_key}


def load_clubs() -> list:
    """Загружает список клубов из clubs.json. Если файла нет - собирает
    один клуб из старых одиночных переменных окружения (обратная
    совместимость с версией на один хост)."""
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            raw = json.load(f)
        clubs = [
            Club(
                id=str(item["id"]),
                host_url=item["host_url"].rstrip("/"),
                api_key=item.get("api_key", ""),
                name=item.get("name", str(item["id"])),
            )
            for item in raw
        ]
        if not clubs:
            raise RuntimeError(f"{CONFIG_FILE} пуст - нет ни одного клуба")
        ids = [c.id for c in clubs]
        if len(ids) != len(set(ids)):
            raise RuntimeError(f"{CONFIG_FILE}: id клубов должны быть уникальны")
        return clubs

    host_url = os.environ.get("CLUB_HOST_URL", "").rstrip("/")
    api_key = os.environ.get("CLUB_API_KEY", "")
    if not host_url:
        raise RuntimeError(
            f"Не найден {CONFIG_FILE}, и не заданы CLUB_HOST_URL/CLUB_API_KEY"
        )
    club_id = os.environ.get("CLUB_ID", "default")
    logger.warning(
        "%s не найден, использую один клуб из переменных окружения (id=%s)",
        CONFIG_FILE, club_id,
    )
    return [Club(id=club_id, host_url=host_url, api_key=api_key, name=club_id)]


SCHEMA = """
-- Справочник клубов (только id -> название, для читаемости в аналитике)
CREATE TABLE IF NOT EXISTS clubs (
    id   TEXT PRIMARY KEY,
    name TEXT NOT NULL
);

-- Текущий (последний известный) статус каждого места в каждом клубе
CREATE TABLE IF NOT EXISTS current_status (
    club_id    TEXT NOT NULL,
    id         INTEGER NOT NULL,
    busy       INTEGER NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (club_id, id)
);

-- Журнал изменений статуса (для расчёта длительности сеансов)
CREATE TABLE IF NOT EXISTS status_changes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    club_id    TEXT NOT NULL,
    seat_id    INTEGER NOT NULL,
    busy       INTEGER NOT NULL,
    changed_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_status_changes_club_seat_time ON status_changes(club_id, seat_id, changed_at);
"""


def get_connection() -> sqlite3.Connection:
    return sqlite3.connect(DB_PATH)


def init_db(conn: sqlite3.Connection, clubs: list) -> None:
    conn.executescript(SCHEMA)
    for club in clubs:
        conn.execute(
            "INSERT INTO clubs (id, name) VALUES (?, ?) "
            "ON CONFLICT(id) DO UPDATE SET name = excluded.name",
            (club.id, club.name),
        )
    conn.commit()


def fetch_clients(club: Club) -> list:
    """Делает запрос к серверу конкретного клуба и возвращает data[]."""
    url = f"{club.host_url}/api/v1/clients"
    resp = requests.get(url, headers=club.headers, timeout=REQUEST_TIMEOUT)
    resp.raise_for_status()
    payload = resp.json()
    return payload.get("data", [])


def fetch_club_safe(club: Club):
    """Обёртка для параллельного запроса: не поднимает исключение наружу,
    а возвращает его - чтобы упавший/недоступный клуб не мешал остальным."""
    try:
        return club, fetch_clients(club), None
    except requests.RequestException as e:
        return club, None, e


def load_current_status(conn: sqlite3.Connection) -> dict:
    """{(club_id, seat_id): busy} - в памяти на весь процесс, чтобы не
    ходить в БД на каждое место при каждом опросе."""
    rows = conn.execute("SELECT club_id, id, busy FROM current_status").fetchall()
    return {(club_id, seat_id): busy for club_id, seat_id, busy in rows}


def track_status_change(
    conn: sqlite3.Connection,
    current_map: dict,
    club_id: str,
    seat_id: int,
    busy: int,
    polled_at: str,
) -> None:
    key = (club_id, seat_id)
    prev_busy = current_map.get(key)

    if prev_busy is None:
        conn.execute(
            "INSERT INTO current_status (club_id, id, busy, updated_at) VALUES (?, ?, ?, ?)",
            (club_id, seat_id, busy, polled_at),
        )
        conn.execute(
            "INSERT INTO status_changes (club_id, seat_id, busy, changed_at) VALUES (?, ?, ?, ?)",
            (club_id, seat_id, busy, polled_at),
        )
        current_map[key] = busy
    elif prev_busy != busy:
        conn.execute(
            "UPDATE current_status SET busy = ?, updated_at = ? WHERE club_id = ? AND id = ?",
            (busy, polled_at, club_id, seat_id),
        )
        conn.execute(
            "INSERT INTO status_changes (club_id, seat_id, busy, changed_at) VALUES (?, ?, ?, ?)",
            (club_id, seat_id, busy, polled_at),
        )
        current_map[key] = busy
    # иначе статус не изменился - ничего не делаем


def poll_once(conn: sqlite3.Connection, clubs: list, current_map: dict) -> None:
    # tzinfo сознательно убираем - см. main.py/README, раздел "Часовой пояс"
    polled_at = datetime.now(MOSCOW_TZ).replace(tzinfo=None).isoformat(timespec="seconds")

    # Опрашиваем все клубы параллельно (запросы I/O-bound) - иначе один
    # медленный/недоступный хост задерживал бы опрос остальных.
    with ThreadPoolExecutor(max_workers=max(len(clubs), 1)) as pool:
        futures = [pool.submit(fetch_club_safe, club) for club in clubs]
        results = [f.result() for f in as_completed(futures)]

    # Запись в SQLite делаем последовательно в основном потоке: у SQLite
    # один писатель, параллельные INSERT из разных потоков только мешали бы.
    total_items = total_busy = total_changes = 0

    for club, items, error in results:
        if error is not None:
            logger.error("Клуб %s: ошибка запроса: %s", club.id, error)
            continue

        changes = 0
        for item in items:
            seat_id = item["id"]
            busy = 1 if item.get("busy") else 0

            prev_busy = current_map.get((club.id, seat_id))
            track_status_change(conn, current_map, club.id, seat_id, busy, polled_at)
            if prev_busy is not None and prev_busy != busy:
                changes += 1

        busy_now = sum(1 for i in items if i.get("busy"))
        total_items += len(items)
        total_busy += busy_now
        total_changes += changes
        logger.info(
            "Клуб %s: всего=%d, занято=%d, изменений статуса=%d",
            club.id, len(items), busy_now, changes,
        )

    conn.commit()
    logger.info(
        "Опрос завершён: клубов=%d, мест всего=%d, занято=%d, изменений=%d",
        len(clubs), total_items, total_busy, total_changes,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Опрос загруженности сети компьютерных клубов")
    parser.add_argument(
        "--interval", type=int, default=0,
        help="Интервал между опросами в секундах. 0 = один опрос и выход (по умолчанию)",
    )
    args = parser.parse_args()

    clubs = load_clubs()
    logger.info("Загружено клубов: %d (%s)", len(clubs), ", ".join(c.id for c in clubs))
    for club in clubs:
        if not club.api_key:
            logger.warning("Клуб %s: api_key не задан - запросы, вероятно, будут отклонены", club.id)

    conn = get_connection()
    init_db(conn, clubs)
    current_map = load_current_status(conn)

    try:
        if args.interval <= 0:
            poll_once(conn, clubs, current_map)
        else:
            while True:
                try:
                    poll_once(conn, clubs, current_map)
                except Exception as e:
                    # Ловим широко: в отличие от версии на один хост, здесь
                    # сбой в опросе одного клуба уже обработан внутри
                    # poll_once, а сюда попадают более серьёзные проблемы
                    # (например, ошибка записи в БД) - процесс не должен
                    # падать целиком из-за них в демон-режиме.
                    logger.error("Ошибка в цикле опроса: %s", e)
                time.sleep(args.interval)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
