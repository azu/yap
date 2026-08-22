# chronixd-capture

A CLI for periodic screen context capture and querying on macOS 26. Captures screenshots, microphone transcription, camera frames, and window metadata.

### Subcommands

| Command | Description |
|---------|-------------|
| `capture` | Capture transcription and screen context periodically to disk (default) |
| `context` | Query captured context data by time range |
| `speakers` | Review and map persistent speaker profiles |
| `snapshot` | One-time screen context snapshot |
| `cameras` | List available cameras |

### Capture

```
USAGE: chronixd-capture capture --data-dir <data-dir> [--interval <interval>] [--camera <camera> ...] [--no-dedup] [--no-diarize] [--no-speaker-identify] [--locale <locale>]

OPTIONS:
  --data-dir <data-dir>   Persistent data directory (required).
  --interval <interval>   Capture interval in seconds (default: 30, minimum: 5).
  --camera <camera>       Camera device ID to capture. Can be specified multiple times.
  --no-dedup              Disable deduplication.
  --no-diarize            Disable speaker diarization (FluidAudio Sortformer).
  --no-speaker-identify   Disable persistent speaker identification (FluidAudio WeSpeaker).
  -l, --locale <locale>   (default: current)
  -h, --help              Show help information.
```

### Context

```
USAGE: chronixd-capture context --data-dir <data-dir> [--from <from>] [--to <to>] [--last <last>] [--device <device> ...] [--list-devices] [--detail] [--include-diagnostics] [--schema]

OPTIONS:
  --data-dir <data-dir>   Data directory (required).
  --from <from>           Start time (ISO 8601 or HH:mm for today).
  --to <to>               End time (defaults to now).
  --last <last>           Duration like 30m, 1h, 7d, 2h30m, or seconds.
  --device <device>       Capture device hostname to include. Repeat for multiple devices, or use `current` for this Mac. Defaults to all.
  --list-devices          List capture device hostnames found in capture files.
  --detail                Add screenshot and camera image paths and availability.
  --include-diagnostics   Include raw speaker_span and diarization_health records.
  --schema                Print all output fields, --detail additions, and usage notes.
  -h, --help              Show help information.
```

Output is NDJSON with a `type` field. Normal output contains `screenshot`, `transcription`, and `camera` records. Screenshot records include the foreground app, window title, and browser URL when available. `--detail` adds screenshot and camera image paths and whether those files are available; it is not required for URLs or transcriptions. Use `--schema` to see the complete field list and the fields added by each option. Raw `speaker_span` is used internally for speaker resolution; `speaker_span` and `diarization_health` are emitted only with `--include-diagnostics`.
When persistent speaker data is available, `context` adds `profileId` to transcription records and to speaker spans when diagnostics are included.

### Persistent Speakers

Sortformer keeps `speakerId` stable inside one capture session. WeSpeaker embeddings and a manual mapping associate it with a persistent `profileId` reusable across sessions.

```bash
# Review the anonymous speakers and transcription excerpts in one session
chronixd-capture speakers review --data-dir ~/chronixd-data --session a1b2c3d4

# Confirm that speaker 0 in the session is the persistent profile "self"
chronixd-capture speakers assign \
  --data-dir ~/chronixd-data \
  --session a1b2c3d4 \
  --speaker-index 0 \
  --profile self

# List profiles reconstructed from confirmed and high-confidence samples
chronixd-capture speakers list --data-dir ~/chronixd-data

# Permanently remove one profile's mappings and associated embeddings
# Stop capture before running this command.
chronixd-capture speakers forget \
  --data-dir ~/chronixd-data \
  --profile self \
  --confirm
```

The first confirmed session creates the initial profile. With at least two confirmed profiles, later matches update a profile only when both the distance and the gap from the second candidate are strong enough. A single profile can be recognized conservatively, but does not learn automatically because there is no competing voice to compare against.

Embeddings are comparison data for a person's voice. Protect the data directory like other sensitive personal data. `speakers forget` removes the selected profile's mappings and currently associated embeddings, but capture must be stopped first because a running process keeps profiles in memory.

> Microphone, Screen Recording, and Accessibility permissions are required. Camera permission is needed when using `--camera`.

### Examples

```bash
# Start capturing
chronixd-capture capture --data-dir ~/chronixd-data

# Capture with 10-second interval and webcam
chronixd-capture capture --data-dir ~/chronixd-data --interval 10 --camera "builtin_1"

# Query last 30 minutes
chronixd-capture context --data-dir ~/chronixd-data --last 30m

# Last 7 days (7 x 24 hours)
chronixd-capture context --data-dir ~/chronixd-data --last 7d

# Add screenshot and camera image paths and availability
chronixd-capture context --data-dir ~/chronixd-data --last 1h --detail

# Inspect finalized speaker spans and once-per-minute health records
chronixd-capture context --data-dir ~/chronixd-data --last 1h --include-diagnostics

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
| Speaker embeddings and mappings (NDJSON) | `{data-dir}/speakers/` | Persistent |

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
