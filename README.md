# chronixd-capture

A CLI for periodic screen context capture and querying on macOS 26. Captures screenshots, microphone transcription, camera frames, and window metadata.

### Subcommands

| Command | Description |
|---------|-------------|
| `capture` | Capture transcription and screen context periodically to disk (default) |
| `context` | Query captured context data by time range |
| `snapshot` | One-time screen context snapshot |
| `cameras` | List available cameras |

### Capture

```
USAGE: chronixd-capture capture --data-dir <data-dir> [--interval <interval>] [--camera <camera> ...] [--no-dedup] [--locale <locale>]

OPTIONS:
  --data-dir <data-dir>   Persistent data directory (required).
  --interval <interval>   Capture interval in seconds (default: 30, minimum: 5).
  --camera <camera>       Camera device ID to capture. Can be specified multiple times.
  --no-dedup              Disable deduplication.
  -l, --locale <locale>   (default: current)
  -h, --help              Show help information.
```

### Context

```
USAGE: chronixd-capture context --data-dir <data-dir> [--from <from>] [--to <to>] [--last <last>] [--device <device> ...] [--list-devices] [--detail] [--schema]

OPTIONS:
  --data-dir <data-dir>   Data directory (required).
  --from <from>           Start time (ISO 8601 or HH:mm for today).
  --to <to>               End time (defaults to now).
  --last <last>           Duration like 30m, 1h, 2h30m.
  --device <device>       Capture device hostname to include. Repeat for multiple devices, or use `current` for this Mac. Defaults to all.
  --list-devices          List capture device hostnames found in data-dir.
  --detail                Output all record types with full fields.
  --schema                Print the output schema for AI consumption.
  -h, --help              Show help information.
```

Output is NDJSON with `type` field per record: `screenshot`, `transcription`, `camera`, `summary`.

> Microphone, Screen Recording, and Accessibility permissions are required. Camera permission is needed when using `--camera`.

### Examples

```bash
# Start capturing
chronixd-capture capture --data-dir ~/chronixd-data

# Capture with 10-second interval and webcam
chronixd-capture capture --data-dir ~/chronixd-data --interval 10 --camera "builtin_1"

# Query last 30 minutes
chronixd-capture context --data-dir ~/chronixd-data --last 30m

# Query with full details (image paths, transcription)
chronixd-capture context --data-dir ~/chronixd-data --last 1h --detail

# List capture devices available in the data directory
chronixd-capture context --data-dir ~/chronixd-data --list-devices

# Query only context captured on the current Mac
chronixd-capture context --data-dir ~/chronixd-data --last 1h --device current

# Query one named capture device
chronixd-capture context --data-dir ~/chronixd-data --last 1h --device work-laptop

# Query a specific time range
chronixd-capture context --data-dir ~/chronixd-data --from "10:00" --to "11:30" --detail

# Pipe to Claude for activity analysis
chronixd-capture context --data-dir ~/chronixd-data --last 30m --detail | claude -p "What was I doing?"
```

### Data Storage

| Data | Location | Lifetime |
|------|----------|----------|
| Screenshots | `/tmp/chronixd-capture/{session}/screenshots/` | Temporary (OS cleanup) |
| Camera images | `/tmp/chronixd-capture/{session}/cameras/` | Temporary |
| Structured data (NDJSON) | `{data-dir}/captures/` | Persistent |
| Summaries (NDJSON) | `{data-dir}/summaries/` | Persistent (written by external tools) |

### Install

```bash
VERSION=$(basename $(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/azu/chronixd-capture/releases/latest))
curl -fsSL "https://github.com/azu/chronixd-capture/releases/download/${VERSION}/chronixd-capture-${VERSION}.tar.gz" | tar xz -C /usr/local/bin
```

### Building

```bash
swift build --disable-sandbox -c release
```

### chronixd-capture.app

`.app` bundle for the resident daemon:

```bash
./scripts/bundle-chronixd-capture.sh
open .build/chronixd-capture.app
```
