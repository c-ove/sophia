# Athena — Wisdom of Commands

Athena is a client/server command-history system for Linux Bash and Zsh environments. Clients capture interactive commands, raw terminal output, source host information, exit status, and timing, then deliver those events to a central Python server. The web dashboard provides live activity, full-text search, source-host filters, target-team filters, and team/CIDR management.

The client is distributed as one static Go executable. Shell integration files are embedded in that executable; they do not need to be installed separately.

## Table of contents

- [Features](#features)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Server installation](#server-installation)
- [Server configuration](#server-configuration)
- [Running with systemd](#running-with-systemd)
- [Prebuilt Linux AMD64 binary](#prebuilt-linux-amd64-binary)
- [Building the Go client](#building-the-go-client)
- [Client configuration](#client-configuration)
- [Client subcommands](#client-subcommands)
- [Dashboard guide](#dashboard-guide)
- [Team mappings and target filtering](#team-mappings-and-target-filtering)
- [HTTP API](#http-api)
- [Data storage and retention](#data-storage-and-retention)
- [Security considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Development checks](#development-checks)
- [Limitations](#limitations)

## Features

### Client

- One statically linked Go binary with four subcommands: `shell`, `forwarder`, `history`, and `rerun`.
- Interactive Bash and Zsh capture using `preexec`/prompt hooks and a pseudo-terminal recorder.
- Command text, raw output, source IP, hostname, shell, timestamps, duration, and exit status.
- Embedded shell assets and automatic runtime-file cleanup.
- Local disk spooling when the server is unavailable.
- Batched delivery, retries, bounded queues, and server-side deduplication.
- Full server command history with event IDs.
- Command reruns by event ID with confirmation by default.

### Server and dashboard

- FastAPI ingestion and query API.
- SQLite persistence with FTS5 full-text search across command and output.
- Live updates over Server-Sent Events (SSE).
- Combined search, multi-host, and target-team filtering.
- Cursor-based event pagination.
- CSV team import and manual add/edit/delete controls.
- Consecutive `/24` generation for numbered teams.
- Clear-teams operation that preserves command history.
- Collapsible sidebar panels and per-event Output/Details dropdowns.
- Persistent light/dark-mode switch.
- ANSI/control-sequence cleanup before storage and display.

## Architecture

```text
Bash or Zsh
    │
    │ preexec / prompt hooks + pseudo-terminal output
    ▼
athena shell
    │
    │ completed JSON events written to local spool
    ▼
athena forwarder ───── retry/batch ─────► FastAPI server
                                              │
                                              ├── SQLite events + FTS5
                                              ├── Team/CIDR mappings
                                              ├── REST query APIs
                                              └── SSE live stream
                                                        │
                                                        ▼
                                                  Web dashboard
```

The source host is the machine running the command. Target teams are determined independently from IP addresses found in the command text.

## Repository layout

```text
.
├── client/
│   ├── *.go                    Go client implementation
│   ├── go.mod                  Go module; standard library only
│   ├── athena-shell.sh         Embedded Bash/Zsh capture hooks
│   ├── bashrc                  Embedded Bash startup file
│   ├── zdotdir/                Embedded Zsh startup files
│   └── dist/
│       └── athena-linux-amd64  Built static Linux client
├── deploy/
│   └── athena.service          Example systemd unit
├── server/
│   └── athena/
│       ├── main.py             HTTP routes and SSE
│       ├── db.py               SQLite storage and filtering
│       ├── schemas.py          Request validation
│       ├── sanitize.py         Terminal output cleanup
│       └── static/             Dashboard HTML, CSS, and JavaScript
├── pyproject.toml              Python package and server entry point
└── README.md
```

## Requirements

### Server

- Python 3.11 or newer.
- SQLite with FTS5 support; this is included with standard Python builds on normal Linux distributions.
- `python3-venv` when installing into a virtual environment on Debian/Ubuntu.

### Client build machine

- Go 1.23 or newer.
- No third-party Go modules and no C compiler.

### Client runtime

- Linux AMD64 for the provided `athena-linux-amd64` binary.
- Bash and/or Zsh.
- util-linux `script`.
- Standard command-line utilities used by the embedded hooks, including `base64`, `grep`, `tail`, `head`, `find`, `date`, and `stat`.
- Network access to the Athena server.

The Go binary contains all Athena-specific client code and shell assets. The shell and terminal utilities above remain operating-system dependencies.

## Server installation

Create an isolated Python environment and install the package:

```bash
cd /path/to/athena
python3 -m venv .venv
.venv/bin/python -m pip install -e .
```

Set the required ingestion token and start the server:

```bash
export ATHENA_TOKEN='replace-with-a-long-random-token'
export ATHENA_DB_PATH="$PWD/athena.db"
export ATHENA_HOST='0.0.0.0'
export ATHENA_PORT='8000'
.venv/bin/athena-server
```

The server fails startup if `ATHENA_TOKEN` is missing. Check availability with:

```bash
curl http://127.0.0.1:8000/api/health
```

Open the dashboard at `http://SERVER_IP:8000/`.

## Server configuration

Configuration is read from environment variables.

| Variable | Default | Purpose |
|---|---:|---|
| `ATHENA_TOKEN` | none; required | Bearer token for command ingestion |
| `ATHENA_DB_PATH` | `./athena.db` | SQLite database path |
| `ATHENA_HOST` | `0.0.0.0` | HTTP listen address |
| `ATHENA_PORT` | `8000` | HTTP listen port |
| `ATHENA_MAX_BATCH_BYTES` | `4194304` | Maximum request size |
| `ATHENA_MAX_EVENT_CHARS` | `262144` | Maximum command/output characters per event |
| `ATHENA_RETENTION_DAYS` | `30` | Event retention; `0` disables automatic retention deletion |

Only one Uvicorn worker should be used with the current SQLite/SSE design.

## Running with systemd

An example unit is provided at `deploy/athena.service`. Its default paths assume the application is installed at `/home/debian/athena` and runs as `debian`.

Create the environment file with restrictive permissions:

```bash
sudo install -m 600 /dev/null /home/debian/athena/athena.env
sudoedit /home/debian/athena/athena.env
```

Example contents:

```ini
ATHENA_TOKEN=replace-with-a-long-random-token
ATHENA_DB_PATH=/home/debian/athena/athena.db
ATHENA_HOST=0.0.0.0
ATHENA_PORT=8000
```

Install and start the unit:

```bash
sudo cp deploy/athena.service /etc/systemd/system/athena.service
sudo systemctl daemon-reload
sudo systemctl enable --now athena.service
sudo systemctl status athena.service
```

Adjust `User`, `Group`, `WorkingDirectory`, `EnvironmentFile`, and `ExecStart` if your installation differs.

## Prebuilt Linux AMD64 binary

A prebuilt client is included at:

```text
client/dist/athena-linux-amd64
```

Binary details:

| Property | Value |
|---|---|
| Platform | Linux AMD64 (`x86_64`) |
| Format | 64-bit ELF executable |
| Linking | Statically linked |
| Size | 6,529,184 bytes (~6.2 MiB) |
| SHA-256 | `bfdfce99a8a314c4b73f6344c643975d791da653bb7416954fa493309df57bf0` |

Verify the checksum before installation:

```bash
sha256sum client/dist/athena-linux-amd64
```

Install it on the client and make it executable:

```bash
scp client/dist/athena-linux-amd64 user@client:/home/user/athena
ssh user@client 'chmod 700 /home/user/athena'
/home/user/athena --help
```

No Go installation is required on the client when using this prebuilt binary.

## Building the Go client

Build for the Linux AMD64 client host:

```bash
cd client
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags='-s -w' \
  -o dist/athena-linux-amd64 .
```

Copy only the executable to the client:

```bash
scp dist/athena-linux-amd64 user@client:/home/user/athena
ssh user@client 'chmod 700 /home/user/athena'
```

Display built-in help:

```bash
/home/user/athena --help
```

## Client configuration

The server URL and token are required for all server-connected operations:

```bash
export ATHENA_SERVER_URL='http://SERVER_IP:8000'
export ATHENA_TOKEN='replace-with-the-server-token'
```

Optional settings:

| Variable | Default | Purpose |
|---|---:|---|
| `ATHENA_BASE_DIR` | `~/.cache/athena` | Runtime files, logs, and spool root |
| `ATHENA_SPOOL_DIR` | `$ATHENA_BASE_DIR/spool` | Queued event storage |
| `ATHENA_HOST_IP` | automatically detected | Override the reported source IP |
| `ATHENA_SHELL` | `$SHELL` | Default shell for `athena shell` and `rerun` |
| `ATHENA_MAX_OUTPUT_BYTES` | `65536` | Maximum captured output per command |
| `ATHENA_MAX_SPOOL_FILES` | `1000` | Maximum queued event files |
| `ATHENA_RETRY_SECONDS` | `5` | Forwarder retry delay after delivery failure |

Use HTTPS for `ATHENA_SERVER_URL` when traffic leaves a trusted lab network.

## Client subcommands

### `athena shell`

Start a captured interactive shell:

```bash
/home/user/athena shell --shell bash
/home/user/athena shell --shell zsh
```

If `--shell` is omitted, Athena uses `ATHENA_SHELL` or `$SHELL`.

The launcher:

1. Creates a unique session ID and secure spool directory.
2. Writes the embedded startup files to a private runtime directory.
3. Detects the source host IP.
4. Starts `athena forwarder` if one is not already running for that spool.
5. Starts Bash or Zsh under the terminal recorder.
6. Removes temporary runtime files and the raw terminal log when the shell exits.

Completed command events remain in the spool until delivered successfully.

### `athena forwarder`

Deliver queued events in the foreground:

```bash
/home/user/athena forwarder
```

This subcommand normally runs in the background after being started by `athena shell`. A per-spool file lock prevents duplicate forwarders. It batches up to 20 events, retries failures, and removes event files only after a successful server response. If a response is lost after acceptance, event IDs allow the server to deduplicate the retry.

### `athena history`

Print every command on the server, newest first:

```bash
/home/user/athena history
/home/user/athena history | less
```

Tab-separated columns are:

```text
TIMESTAMP  HOST  EXIT  EVENT_ID  COMMAND
```

Commands are quoted and escaped so multiline content stays on one output line. The full event ID can be passed to `athena rerun`.

### `athena rerun`

Fetch and execute a prior command by event ID:

```bash
/home/user/athena rerun EVENT_ID
/home/user/athena rerun --yes EVENT_ID
```

Without `--yes`, Athena prints the command and requires interactive confirmation. The command runs locally on the client where `rerun` is invoked, using Bash or Zsh as appropriate. It does not automatically run on the original source host. Its exit status becomes the `athena` process exit status.

When used inside `athena shell`, the rerun invocation and its output are captured as new command events.

## Dashboard guide

### Live feed and search

The root page shows commands newest first and updates automatically over SSE. Search covers both command text and output. Search is debounced and can be combined with host and target-team filters.

Each event card shows the timestamp, source host, target teams, and command. Open:

- **Output** for captured output.
- **Details** for exit status, duration, truncation state, and a clickable event ID.

Use **Load older commands** for cursor-based pagination.

### Host filters

Open the **Hosts** dropdown to search or select hosts. Multiple hosts can be selected. **Clear** removes only host selections; **Clear filters** in the main filter bar resets hosts, target team, and search.

### Team management

Open **Team mappings** to upload CSV, add or edit individual mappings, generate consecutive teams, or clear all teams. The panel and its nested controls are collapsed by default to keep the dashboard compact.

### Light and dark mode

Use the **Dark mode** switch at the bottom of the sidebar. The preference is saved in browser `localStorage` under `athena-theme` and restored on later visits. Light mode is the default.

## Team mappings and target filtering

### CSV import

CSV rows contain a CIDR range and team name:

```csv
192.168.1.0/24,Team 1
192.168.2.0/24,Team 2
192.168.20.0/24,Team 1
```

A team can have multiple ranges. Import is atomic and validates every row before making changes. **CSV import replaces all existing mappings.**

### Manual management

The manual editor supports adding, editing, and deleting individual mappings. Adding an existing CIDR to another team reassigns that CIDR.

### Consecutive team generation

The generator accepts a starting IPv4 `/24` and 1–100 teams. For example, `192.168.101.0/24` with `10` teams creates:

```text
192.168.101.0/24 → Team 1
192.168.102.0/24 → Team 2
...
192.168.110.0/24 → Team 10
```

Existing assignments for generated CIDRs are replaced.

### Clear teams

**Clear teams** asks for confirmation, then deletes all teams and CIDR mappings. It does not delete command events.

### Target-team semantics

Team filters match the target of a command, not the source host running it. Athena extracts IP addresses from the command text and compares them with team CIDR mappings.

For example, if a Blue Team host runs `ssh admin@192.168.2.50` and that address belongs to Red Team, the event matches the Red Team filter. Commands targeting multiple teams match each corresponding filter. Commands without a target IP have no target-team assignment.

Host/CIDR labels in the Hosts panel still describe source hosts. Target resolution currently uses IP literals, not DNS hostnames.

## HTTP API

Selected endpoints:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/events` | Authenticated batch ingestion |
| `GET` | `/api/events` | Search/filter events with pagination |
| `GET` | `/api/events/stream` | SSE live events |
| `GET` | `/api/commands/export` | Streaming tab-separated history |
| `GET` | `/api/commands/{event_id}/command` | Plain command text for reruns |
| `GET` | `/api/hosts` | Source hosts and activity counts |
| `GET` | `/api/teams` | Teams and mappings |
| `DELETE` | `/api/teams` | Clear all teams and mappings |
| `POST` | `/api/teams/import` | Replace mappings from CSV text |
| `POST` | `/api/teams/mappings` | Add or reassign a mapping |
| `PUT` | `/api/teams/mappings/{id}` | Update a mapping |
| `DELETE` | `/api/teams/mappings/{id}` | Delete a mapping |
| `POST` | `/api/teams/bulk` | Generate consecutive `/24` teams |
| `GET` | `/api/health` | Health and event count |

Event queries support `q`, `team`, `limit`, and `cursor`. Repeat `ip` to select multiple source hosts:

```text
/api/events?ip=10.1.10.3&ip=192.168.2.25&q=ssh&limit=50
```

Ingestion requires:

```http
Authorization: Bearer YOUR_ATHENA_TOKEN
Content-Type: application/json
```

## Data storage and retention

The server stores events, teams, and CIDR mappings in SQLite. Event command/output text is indexed in an external-content FTS5 table. Team mappings are applied at query time, so mapping changes affect existing events immediately.

Clients store undelivered events under `~/.cache/athena/spool` by default. Server acknowledgments and event IDs provide at-least-once delivery with deduplication.

The default server retention is 30 days. Set `ATHENA_RETENTION_DAYS=0` to disable retention deletion.

## Security considerations

Athena is currently designed for a trusted lab environment.

- Command text and output can contain credentials, tokens, or other sensitive data. Protect the database, spool, backups, and dashboard accordingly.
- The ingestion endpoint requires a bearer token. Dashboard reads and team-management endpoints do not currently provide multi-user authentication.
- The built-in server does not provide TLS. Use an authenticated HTTPS reverse proxy before exposing Athena outside a trusted network.
- Client spool and runtime files are created with user-only permissions.
- Reruns execute real commands. Review the fetched command before confirming; use `--yes` only when automation is intended.
- Output is rendered as text in the dashboard, not as HTML, and ANSI/control sequences are removed on ingestion.

## Troubleshooting

### Server will not start

Confirm `ATHENA_TOKEN` is set and inspect service logs:

```bash
journalctl -u athena.service -n 100 --no-pager
```

### Commands are not appearing

Check server health, client spool, and forwarder log:

```bash
curl http://SERVER_IP:8000/api/health
find ~/.cache/athena/spool -maxdepth 2 -type f
cat ~/.cache/athena/forwarder.log
```

Also verify `ATHENA_SERVER_URL` and `ATHENA_TOKEN` match the server.

### Events remain queued

Run the forwarder in the foreground to see delivery errors:

```bash
/home/user/athena forwarder
```

Stop any existing forwarder for that spool first if the file lock reports another instance.

### Source IP is incorrect

Automatic detection uses the primary outbound interface. Override it when a VPN or multi-homed host needs a specific address:

```bash
export ATHENA_HOST_IP='10.1.10.3'
```

### A command has no target team

Target teams require an IP literal in the command that belongs to a configured CIDR mapping. Source-host membership alone does not create a target-team assignment.

## Development checks

Python server and static assets:

```bash
python3 -m compileall -q server
node --check server/athena/static/app.js
```

Go client:

```bash
cd client
gofmt -w *.go
go test ./...
go vet ./...
```

Build the deployment binary with the command in [Building the Go client](#building-the-go-client).

For end-to-end verification, start the real server, run Bash and Zsh through `athena shell`, and confirm command/output capture, exit statuses, offline retry, history, reruns, SSE updates, host filters, target-team filters, CSV/manual mapping operations, and Clear teams.

## Limitations

- Ordinary interactive command output is captured well; full-screen terminal applications are best effort.
- Background output produced after a command returns may not be attributed to the original command.
- Target-team detection does not resolve DNS names or infer targets from command output.
- SQLite and the single-worker server are intended for a small central lab deployment, not a large multi-tenant service.
- The dashboard has no multi-user account or role system.
- The provided prebuilt client targets Linux AMD64; build another GOOS/GOARCH variant for other platforms.
