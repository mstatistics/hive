import sqlite3
import time
from pathlib import Path


DB_FILE = "db.sqlite"

conn: sqlite3.Connection | None = None
def connect(db_path: str):
    global conn
    conn = sqlite3.connect(db_path)

def save_measurement(measurement: dict[str, float]):
    assert conn is not None, "Database connection is not established. Call connect() first."
    cur = conn.cursor()

    timestamp = int(time.time())
    rows = [(sensor_id, timestamp, value) for sensor_id, value in measurement.items()]
    cur.executemany(
        "INSERT INTO readings (sensor_id, timestamp, value) VALUES (?, ?, ?)",
        rows,
    )

    conn.commit()

    cur.close()


def migrate():
    assert conn is not None, "Database connection is not established. Call connect() first."

    migrations_dir = Path(__file__).resolve().parent.parent.parent / "migrations" / "device"
    if not migrations_dir.exists():
        return

    current_version = conn.execute("PRAGMA user_version").fetchone()[0]

    for migration_file in sorted(migrations_dir.glob("*.sql"), key=lambda p: p.name):
        version_str = migration_file.stem.split("_", 1)[0]
        if not version_str.isdigit():
            continue

        version = int(version_str)
        if version <= current_version:
            continue

        conn.executescript(migration_file.read_text())
        conn.execute(f"PRAGMA user_version = {version}")
        conn.commit()
        current_version = version

