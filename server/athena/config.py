from dataclasses import dataclass
from pathlib import Path
import os


@dataclass(frozen=True)
class Settings:
    db_path: Path
    token: str
    host: str
    port: int
    max_batch_bytes: int
    max_event_chars: int
    retention_days: int

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            db_path=Path(os.getenv("ATHENA_DB_PATH", "./athena.db")).expanduser(),
            token=os.getenv("ATHENA_TOKEN", ""),
            host=os.getenv("ATHENA_HOST", "0.0.0.0"),
            port=int(os.getenv("ATHENA_PORT", "8000")),
            max_batch_bytes=int(os.getenv("ATHENA_MAX_BATCH_BYTES", str(4 * 1024 * 1024))),
            max_event_chars=int(os.getenv("ATHENA_MAX_EVENT_CHARS", "262144")),
            retention_days=int(os.getenv("ATHENA_RETENTION_DAYS", "30")),
        )
