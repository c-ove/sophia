import asyncio
from contextlib import asynccontextmanager
import csv
import hmac
import io
import ipaddress
import json
from pathlib import Path
import time
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, status
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from .config import Settings
from .db import Database
from .sanitize import clean_text
from .schemas import BulkTeamMappingIn, CommandBatchIn, TeamImportIn, TeamMappingIn

settings = Settings.from_env()
db = Database(settings.db_path, retention_days=settings.retention_days)
static_dir = Path(__file__).parent / "static"


def display_event(event: dict[str, Any]) -> dict[str, Any]:
    result = dict(event)
    result["command"] = clean_text(result["command"])
    result["output"] = clean_text(result["output"])
    return result


@asynccontextmanager
async def lifespan(_: FastAPI):
    if not settings.token:
        raise RuntimeError("ATHENA_TOKEN must be set before starting the server")
    db.initialize()
    yield


app = FastAPI(title="Athena", version="0.1.0", lifespan=lifespan)


@app.middleware("http")
async def limit_request_size(request: Request, call_next):
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > settings.max_batch_bytes:
        return JSONResponse({"detail": "request body is too large"}, status_code=413)
    return await call_next(request)


def require_token(authorization: Annotated[str | None, Header()] = None) -> None:
    expected = f"Bearer {settings.token}"
    if authorization is None or not hmac.compare_digest(authorization, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="valid ingestion credentials required",
        )


@app.post("/api/events", status_code=202)
def ingest_events(
    batch: CommandBatchIn,
    _: Annotated[None, Depends(require_token)],
) -> dict[str, int]:
    try:
        accepted, duplicates = db.insert_events(batch.events, settings.max_event_chars)
    except ValueError as exc:
        code = 413 if "exceeds" in str(exc) else 422
        raise HTTPException(status_code=code, detail=str(exc)) from exc
    return {"accepted": accepted, "duplicates": duplicates}


@app.get("/api/events")
def list_events(
    q: str | None = None,
    ip: Annotated[list[str] | None, Query()] = None,
    team: int | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    cursor: Annotated[int | None, Query(ge=1)] = None,
) -> dict[str, Any]:
    try:
        items, next_cursor = db.list_events(q, ip, team, limit, cursor)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"items": [display_event(item) for item in items], "next_cursor": next_cursor}


@app.get("/api/commands/export")
def export_commands(
    q: str | None = None,
    ip: Annotated[list[str] | None, Query()] = None,
    team: int | None = None,
) -> StreamingResponse:
    try:
        addresses = [str(ipaddress.ip_address(value)) for value in ip] if ip else None
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="invalid IP address") from exc

    def generate():
        yield "TIMESTAMP\tHOST\tEXIT\tEVENT_ID\tCOMMAND\n"
        for row in db.iter_commands(q, addresses, team):
            command = json.dumps(row["command"], ensure_ascii=False)
            exit_code = "" if row["exit_code"] is None else row["exit_code"]
            yield f"{row['started_at']}\t{row['host_ip']}\t{exit_code}\t{row['id']}\t{command}\n"

    return StreamingResponse(generate(), media_type="text/plain")


@app.get("/api/commands/{event_id}/command", response_class=PlainTextResponse)
def get_command(event_id: str) -> PlainTextResponse:
    command = db.get_command(event_id)
    if command is None:
        raise HTTPException(status_code=404, detail="command event not found")
    return PlainTextResponse(command)


@app.get("/api/hosts")
def list_hosts() -> dict[str, Any]:
    return {"items": db.list_hosts()}


@app.get("/api/teams")
def list_teams() -> dict[str, Any]:
    return {"items": db.list_teams()}


@app.delete("/api/teams")
def clear_teams() -> dict[str, Any]:
    db.clear_teams()
    return {"items": []}


@app.post("/api/teams/mappings")
def add_team_mapping(payload: TeamMappingIn) -> dict[str, Any]:
    db.save_mapping(payload.cidr, payload.team)
    return {"items": db.list_teams()}


@app.post("/api/teams/bulk")
def bulk_add_teams(payload: BulkTeamMappingIn) -> dict[str, Any]:
    network = ipaddress.ip_network(payload.cidr)
    first_address = int(network.network_address)
    if first_address + (payload.teams - 1) * 256 > 0xFFFFFFFF:
        raise HTTPException(status_code=422, detail="team ranges extend beyond the IPv4 address space")
    rows = [
        (str(ipaddress.ip_network((first_address + index * 256, 24))), f"Team {index + 1}")
        for index in range(payload.teams)
    ]
    db.add_mappings(rows)
    return {"items": db.list_teams(), "ranges": len(rows)}


@app.put("/api/teams/mappings/{mapping_id}")
def update_team_mapping(mapping_id: int, payload: TeamMappingIn) -> dict[str, Any]:
    if not db.save_mapping(payload.cidr, payload.team, mapping_id):
        raise HTTPException(status_code=404, detail="team mapping not found")
    return {"items": db.list_teams()}


@app.delete("/api/teams/mappings/{mapping_id}")
def delete_team_mapping(mapping_id: int) -> dict[str, Any]:
    if not db.delete_mapping(mapping_id):
        raise HTTPException(status_code=404, detail="team mapping not found")
    return {"items": db.list_teams()}


@app.post("/api/teams/import")
def import_teams(payload: TeamImportIn) -> dict[str, Any]:
    rows: list[tuple[str, str]] = []
    network_owners: dict[str, str] = {}
    try:
        for line_number, row in enumerate(csv.reader(io.StringIO(payload.content)), start=1):
            if not row or all(not value.strip() for value in row):
                continue
            if len(row) != 2:
                raise ValueError(f"row {line_number}: expected CIDR,Team")
            cidr, name = row[0].strip(), row[1].strip()
            if not name:
                raise ValueError(f"row {line_number}: team name is empty")
            network = ipaddress.ip_network(cidr, strict=False)
            canonical = str(network)
            if canonical in network_owners and network_owners[canonical] != name:
                raise ValueError(
                    f"row {line_number}: {canonical} is already assigned to {network_owners[canonical]}"
                )
            network_owners[canonical] = name
            rows.append((canonical, name))
    except (ValueError, csv.Error) as exc:
        if isinstance(exc, ValueError) and str(exc).startswith("row "):
            detail = str(exc)
        else:
            detail = f"invalid CSV: {exc}"
        raise HTTPException(status_code=422, detail=detail) from exc
    if not rows:
        raise HTTPException(status_code=422, detail="CSV contains no team mappings")
    db.replace_teams(rows)
    return {"items": db.list_teams(), "ranges": len(rows)}


@app.get("/api/events/stream")
async def stream_events(
    request: Request,
    q: str | None = None,
    ip: Annotated[list[str] | None, Query()] = None,
    team: int | None = None,
) -> StreamingResponse:
    if ip:
        try:
            ip = [str(ipaddress.ip_address(value)) for value in ip]
        except ValueError as exc:
            raise HTTPException(status_code=422, detail="invalid IP address") from exc

    async def events():
        last_id = await asyncio.to_thread(db.latest_rowid)
        last_heartbeat = time.monotonic()
        yield "retry: 2000\n\n"
        while not await request.is_disconnected():
            await asyncio.sleep(1)
            latest = await asyncio.to_thread(db.latest_rowid)
            if latest > last_id:
                items = await asyncio.to_thread(db.new_events, last_id, latest, q, ip, team)
                for item in items:
                    payload = json.dumps(display_event(item), separators=(",", ":"))
                    yield f"event: command\ndata: {payload}\n\n"
                last_id = latest
                last_heartbeat = time.monotonic()
            if time.monotonic() - last_heartbeat >= 15:
                yield ": keepalive\n\n"
                last_heartbeat = time.monotonic()

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/api/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "events": db.count_events()}


@app.get("/", include_in_schema=False)
def index() -> FileResponse:
    return FileResponse(static_dir / "index.html")


app.mount("/static", StaticFiles(directory=static_dir), name="static")
