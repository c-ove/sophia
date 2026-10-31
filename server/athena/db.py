from collections.abc import Iterator
from datetime import datetime, timedelta, timezone
import ipaddress
import re
import sqlite3
from pathlib import Path
from typing import Any

from .sanitize import clean_text
from .schemas import CommandEventIn

IP_CANDIDATES = re.compile(
    r"(?<![0-9A-Za-z_.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9A-Za-z_.])"
    r"|(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])"
)


class Database:
    def __init__(self, path: Path, retention_days: int = 30) -> None:
        self.path = path
        self.retention_days = retention_days

    @staticmethod
    def _ip_in_cidr(ip: str, cidr: str) -> bool:
        try:
            return ipaddress.ip_address(ip) in ipaddress.ip_network(cidr)
        except ValueError:
            return False

    @staticmethod
    def _target_ips(command: str) -> set[Any]:
        targets = set()
        for candidate in IP_CANDIDATES.findall(command):
            try:
                targets.add(ipaddress.ip_address(candidate))
            except ValueError:
                continue
        return targets

    @classmethod
    def _command_targets_cidr(cls, command: str, cidr: str) -> bool:
        try:
            network = ipaddress.ip_network(cidr)
        except ValueError:
            return False
        return any(target in network for target in cls._target_ips(command))

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=15)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.create_function("ip_in_cidr", 2, self._ip_in_cidr)
        connection.create_function("command_targets_cidr", 2, self._command_targets_cidr)
        return connection

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    hostname TEXT NOT NULL,
                    host_ip TEXT NOT NULL,
                    shell TEXT NOT NULL,
                    command TEXT NOT NULL,
                    output TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    ended_at TEXT NOT NULL,
                    received_at TEXT NOT NULL,
                    exit_code INTEGER,
                    duration_ms INTEGER NOT NULL,
                    truncated INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(session_id, sequence)
                );

                CREATE INDEX IF NOT EXISTS events_row_received
                    ON events(received_at DESC);
                CREATE INDEX IF NOT EXISTS events_host_ip
                    ON events(host_ip);
                CREATE INDEX IF NOT EXISTS events_session
                    ON events(session_id, sequence);

                CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
                    command,
                    output,
                    content='events',
                    content_rowid='rowid'
                );

                CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
                    INSERT INTO events_fts(rowid, command, output)
                    VALUES (new.rowid, new.command, new.output);
                END;

                CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
                    INSERT INTO events_fts(events_fts, rowid, command, output)
                    VALUES ('delete', old.rowid, old.command, old.output);
                END;

                CREATE TABLE IF NOT EXISTS teams (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE
                );

                CREATE TABLE IF NOT EXISTS team_networks (
                    id INTEGER PRIMARY KEY,
                    team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
                    cidr TEXT NOT NULL UNIQUE,
                    UNIQUE(team_id, cidr)
                );
                """
            )

    def insert_events(self, events: list[CommandEventIn], max_event_chars: int) -> tuple[int, int]:
        accepted = 0
        duplicates = 0
        now = datetime.now(timezone.utc).isoformat()
        cutoff = (datetime.now(timezone.utc) - timedelta(days=self.retention_days)).isoformat()
        with self.connect() as connection:
            for event in events:
                command, output = event.payloads()
                command = clean_text(command)
                output = clean_text(output)
                if len(command) > max_event_chars or len(output) > max_event_chars:
                    raise ValueError(f"event {event.id} exceeds the configured payload limit")
                started_at, ended_at = event.timestamps()
                cursor = connection.execute(
                    """
                    INSERT OR IGNORE INTO events (
                        id, session_id, sequence, hostname, host_ip, shell,
                        command, output, started_at, ended_at, received_at,
                        exit_code, duration_ms, truncated
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        str(event.id), str(event.session_id), event.sequence,
                        event.hostname, event.host_ip, event.shell, command, output,
                        started_at, ended_at, now, event.exit_code,
                        event.duration_ms, int(event.truncated),
                    ),
                )
                if cursor.rowcount:
                    accepted += 1
                else:
                    duplicates += 1
            if self.retention_days > 0:
                connection.execute("DELETE FROM events WHERE received_at < ?", (cutoff,))
        return accepted, duplicates

    @staticmethod
    def _fts_query(value: str) -> str | None:
        tokens = re.findall(r"\w+", value, flags=re.UNICODE)
        if not tokens:
            return None
        return " AND ".join(f'"{token.replace(chr(34), chr(34) * 2)}"*' for token in tokens)

    def _filters(
        self,
        query: str | None,
        ips: list[str] | None,
        team: int | None,
    ) -> tuple[list[str], list[Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if query:
            fts_query = self._fts_query(query)
            if fts_query is None:
                clauses.append("0")
            else:
                clauses.append("e.rowid IN (SELECT rowid FROM events_fts WHERE events_fts MATCH ?)")
                params.append(fts_query)
        if ips:
            addresses = [str(ipaddress.ip_address(ip)) for ip in ips]
            placeholders = ",".join("?" for _ in addresses)
            clauses.append(f"e.host_ip IN ({placeholders})")
            params.extend(addresses)
        if team is not None:
            clauses.append(
                """EXISTS (
                    SELECT 1 FROM team_networks tn
                    WHERE tn.team_id = ? AND command_targets_cidr(e.command, tn.cidr)
                )"""
            )
            params.append(team)
        return clauses, params

    @staticmethod
    def _networks(connection: sqlite3.Connection) -> list[tuple[int, str, Any]]:
        rows = connection.execute(
            """
            SELECT tn.team_id, t.name, tn.cidr
            FROM team_networks tn
            JOIN teams t ON t.id = tn.team_id
            ORDER BY t.name, tn.cidr
            """
        ).fetchall()
        return [(row["team_id"], row["name"], ipaddress.ip_network(row["cidr"])) for row in rows]

    @staticmethod
    def _team_names(ip: str, networks: list[tuple[int, str, Any]]) -> list[str]:
        address = ipaddress.ip_address(ip)
        return sorted({name for _, name, network in networks if address in network})

    @classmethod
    def _target_team_names(cls, command: str, networks: list[tuple[int, str, Any]]) -> list[str]:
        targets = cls._target_ips(command)
        return sorted({name for _, name, network in networks if any(target in network for target in targets)})

    def _event_dict(self, row: sqlite3.Row, networks: list[tuple[int, str, Any]]) -> dict[str, Any]:
        result = {
            "id": row["id"],
            "session_id": row["session_id"],
            "sequence": row["sequence"],
            "hostname": row["hostname"],
            "host_ip": row["host_ip"],
            "shell": row["shell"],
            "command": row["command"],
            "output": row["output"],
            "started_at": row["started_at"],
            "ended_at": row["ended_at"],
            "received_at": row["received_at"],
            "exit_code": row["exit_code"],
            "duration_ms": row["duration_ms"],
            "truncated": bool(row["truncated"]),
            "teams": self._target_team_names(row["command"], networks),
        }
        return result

    def list_events(
        self,
        query: str | None,
        ips: list[str] | None,
        team: int | None,
        limit: int,
        cursor: int | None,
    ) -> tuple[list[dict[str, Any]], int | None]:
        clauses, params = self._filters(query, ips, team)
        if cursor is not None:
            clauses.append("e.rowid < ?")
            params.append(cursor)
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        params.append(limit)
        with self.connect() as connection:
            rows = connection.execute(
                f"""
                SELECT e.rowid AS event_rowid, e.*
                FROM events e
                {where}
                ORDER BY e.rowid DESC
                LIMIT ?
                """,
                params,
            ).fetchall()
            networks = self._networks(connection)
        items = [self._event_dict(row, networks) for row in rows]
        next_cursor = rows[-1]["event_rowid"] if len(rows) == limit else None
        return items, next_cursor

    def get_command(self, event_id: str) -> str | None:
        with self.connect() as connection:
            row = connection.execute("SELECT command FROM events WHERE id = ?", (event_id,)).fetchone()
        return row["command"] if row else None

    def iter_commands(
        self,
        query: str | None,
        ips: list[str] | None,
        team: int | None,
    ) -> Iterator[sqlite3.Row]:
        clauses, params = self._filters(query, ips, team)
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        with self.connect() as connection:
            rows = connection.execute(
                f"""
                SELECT e.id, e.started_at, e.host_ip, e.exit_code, e.command
                FROM events e
                {where}
                ORDER BY e.rowid DESC
                """,
                params,
            )
            yield from rows

    def latest_rowid(self) -> int:
        with self.connect() as connection:
            return connection.execute("SELECT COALESCE(MAX(rowid), 0) FROM events").fetchone()[0]

    def new_events(
        self,
        after: int,
        until: int,
        query: str | None,
        ips: list[str] | None,
        team: int | None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        clauses, params = self._filters(query, ips, team)
        clauses.extend(["e.rowid > ?", "e.rowid <= ?"])
        params.extend([after, until, limit])
        where = f"WHERE {' AND '.join(clauses)}"
        with self.connect() as connection:
            rows = connection.execute(
                f"""
                SELECT e.rowid AS event_rowid, e.*
                FROM events e
                {where}
                ORDER BY e.rowid ASC
                LIMIT ?
                """,
                params,
            ).fetchall()
            networks = self._networks(connection)
        return [self._event_dict(row, networks) for row in rows]

    def list_hosts(self) -> list[dict[str, Any]]:
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT host_ip, hostname, COUNT(*) AS command_count,
                       MAX(received_at) AS last_activity
                FROM events
                GROUP BY host_ip, hostname
                ORDER BY last_activity DESC
                LIMIT 500
                """
            ).fetchall()
            networks = self._networks(connection)
        return [
            {
                "host_ip": row["host_ip"],
                "hostname": row["hostname"],
                "command_count": row["command_count"],
                "last_activity": row["last_activity"],
                "teams": self._team_names(row["host_ip"], networks),
            }
            for row in rows
        ]

    def list_teams(self) -> list[dict[str, Any]]:
        with self.connect() as connection:
            teams = connection.execute("SELECT id, name FROM teams ORDER BY name").fetchall()
            networks = connection.execute(
                "SELECT id, team_id, cidr FROM team_networks ORDER BY cidr"
            ).fetchall()
        by_team: dict[int, list[dict[str, Any]]] = {}
        for network in networks:
            by_team.setdefault(network["team_id"], []).append(
                {"id": network["id"], "cidr": network["cidr"]}
            )
        return [
            {
                "id": team["id"],
                "name": team["name"],
                "mappings": by_team.get(team["id"], []),
                "networks": [item["cidr"] for item in by_team.get(team["id"], [])],
            }
            for team in teams
        ]

    def replace_teams(self, rows: list[tuple[str, str]]) -> None:
        with self.connect() as connection:
            connection.execute("DELETE FROM team_networks")
            connection.execute("DELETE FROM teams")
            team_ids: dict[str, int] = {}
            for cidr, name in rows:
                if name not in team_ids:
                    cursor = connection.execute("INSERT INTO teams(name) VALUES (?)", (name,))
                    team_ids[name] = cursor.lastrowid
                connection.execute(
                    "INSERT OR IGNORE INTO team_networks(team_id, cidr) VALUES (?, ?)",
                    (team_ids[name], cidr),
                )

    def clear_teams(self) -> None:
        with self.connect() as connection:
            connection.execute("DELETE FROM team_networks")
            connection.execute("DELETE FROM teams")

    def save_mapping(self, cidr: str, team: str, mapping_id: int | None = None) -> bool:
        with self.connect() as connection:
            team_row = connection.execute("SELECT id FROM teams WHERE name = ?", (team,)).fetchone()
            if team_row:
                team_id = team_row["id"]
            else:
                cursor = connection.execute("INSERT INTO teams(name) VALUES (?)", (team,))
                team_id = cursor.lastrowid

            if mapping_id is None:
                connection.execute(
                    """
                    INSERT INTO team_networks(team_id, cidr) VALUES (?, ?)
                    ON CONFLICT(cidr) DO UPDATE SET team_id = excluded.team_id
                    """,
                    (team_id, cidr),
                )
            else:
                exists = connection.execute(
                    "SELECT id FROM team_networks WHERE id = ?", (mapping_id,)
                ).fetchone()
                if not exists:
                    connection.rollback()
                    return False
                connection.execute(
                    "DELETE FROM team_networks WHERE cidr = ? AND id != ?",
                    (cidr, mapping_id),
                )
                connection.execute(
                    "UPDATE team_networks SET team_id = ?, cidr = ? WHERE id = ?",
                    (team_id, cidr, mapping_id),
                )
            connection.execute("DELETE FROM teams WHERE id NOT IN (SELECT team_id FROM team_networks)")
        return True

    def add_mappings(self, rows: list[tuple[str, str]]) -> None:
        with self.connect() as connection:
            team_ids: dict[str, int] = {}
            for cidr, name in rows:
                if name not in team_ids:
                    team_row = connection.execute("SELECT id FROM teams WHERE name = ?", (name,)).fetchone()
                    if team_row:
                        team_ids[name] = team_row["id"]
                    else:
                        cursor = connection.execute("INSERT INTO teams(name) VALUES (?)", (name,))
                        team_ids[name] = cursor.lastrowid
                connection.execute(
                    """
                    INSERT INTO team_networks(team_id, cidr) VALUES (?, ?)
                    ON CONFLICT(cidr) DO UPDATE SET team_id = excluded.team_id
                    """,
                    (team_ids[name], cidr),
                )
            connection.execute("DELETE FROM teams WHERE id NOT IN (SELECT team_id FROM team_networks)")

    def delete_mapping(self, mapping_id: int) -> bool:
        with self.connect() as connection:
            cursor = connection.execute("DELETE FROM team_networks WHERE id = ?", (mapping_id,))
            if not cursor.rowcount:
                connection.rollback()
                return False
            connection.execute("DELETE FROM teams WHERE id NOT IN (SELECT team_id FROM team_networks)")
        return True

    def count_events(self) -> int:
        with self.connect() as connection:
            return connection.execute("SELECT COUNT(*) FROM events").fetchone()[0]
