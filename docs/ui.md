# Web UI (`serve`)

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

`fable-monitor serve` runs a small, **read-only** HTTP dashboard over the same
observation log and state file every other command reads. It is the only
long-running mode of an otherwise poll-once CLI, and it exists so the monitor's
status — last poll, configured sources, recent events, active alerts — is
viewable in a browser without `zstd -dc … | jq`.

The dependency-free JavaScript and CSS in `src/serve/` are embedded in the Zig
binary and served from `/static/app.js` and `/static/app.css`. There is no CDN,
front-end build step, `node_modules`, or runtime asset download.

## Quick start

```sh
just ui                                   # serves the installed agent's data on :8787
just ui 9000                              # choose a port

# or directly:
./zig-out/bin/fable-monitor serve         # default port 8787
./zig-out/bin/fable-monitor serve 9000    # positional port
FABLE_MONITOR_PORT=9000 ./zig-out/bin/fable-monitor serve
```

Then open <http://127.0.0.1:8787> (or your chosen port).

Port resolution, highest precedence first: the positional `serve <port>`
argument, then `FABLE_MONITOR_PORT`, then the default **8787**.

## How the frontend connects to the backend

```
browser ──GET / ─────────────▶  serve: returns the HTML shell and local assets

browser ──GET /ui/status ─────▶  serve: reads log + state, returns an HTML fragment
        ◀────────────────────   local app.js swaps it into the page periodically
```

The embedded script issues fragment requests and swaps the returned HTML into
place, so the page refreshes itself without a full reload.

| Endpoint | Refresh | Content type | Shows |
|---|---|---|---|
| `GET /` | — | `text/html` | The page shell; all executable/style assets are local. |
| `GET /static/app.js`, `/static/app.css` | — | JS/CSS | Immutable bytes embedded in the binary. |
| `GET /ui/status` | `load, every 5s` | `text/html` | Stat cards: source count, events logged, active-alert count, last observed time. |
| `GET /ui/alerts` | `load, every 5s` | `text/html` | Active (unacknowledged) alerts: tier, kind, title, first-alerted time, status. |
| `GET /ui/sources` | `load, every 30s` | `text/html` | Every configured source with its tier, kind, poll class, and last success / change time (joined from `state.source_status`). |
| `GET /ui/events?limit=N` | `load, every 10s` | `text/html` | The most recent `N` events (default 30), newest first, with per-kind badges. |
| `GET /healthz` | — | `text/plain` | `ok` — a liveness probe. |
| `GET /readyz` | — | `text/plain` | `200 ready`, or `503` when state is unreadable, required/minimum decisive coverage is stale, or delivery work is overdue. |
| `GET /reader?url=…` | on demand | `text/html` | Article proxy; disabled unless `FABLE_MONITOR_READER=1`. |

Unknown paths return `404`.

## Which data it shows

The `serve` command honours the same path variables as the rest of the CLI
(see [deployment.md](deployment.md)):

- `FABLE_MONITOR_LOG` — the observation log (`events.jsonl.zst`).
- `FABLE_MONITOR_STATE` — the state file (`state.jsonl.zst`).

`just ui` sets both to the installed agent's files under
`~/Library/Application Support/fable-monitor/`, so the dashboard reflects what
the scheduled poller is actually doing. Point them elsewhere to inspect a
different deployment, a fixture replay, or a throwaway dev run.

The same source-selection options the poller uses also apply, so the **Sources**
panel lists exactly the set the poller would act on: `FABLE_MONITOR_SOURCES`
(external config), `FABLE_MONITOR_ONLY`, and `FABLE_MONITOR_DISABLE`.

## Safety model

- **Read-only.** The server never writes the log or state. It is safe to run
  alongside the scheduled poller, which owns those files; the UI only reads
  them.
- **Loopback only.** It binds `127.0.0.1`, so it is not reachable from other
  hosts. To view it remotely, use an SSH tunnel
  (`ssh -L 8787:127.0.0.1:8787 host`) or a reverse proxy you control rather than
  changing the bind address.
- **No mutation endpoints.** There is no acknowledge/poll/delete action in the
  UI; those remain CLI-only (`ack`, `poll`).
- **Per-request arena + escaping.** Each request renders from a fresh arena (so
  a long-lived server does not accumulate memory), and all dynamic text from the
  log/state is HTML-escaped before it reaches the page.
- **Security headers.** Every response sets CSP, nosniff, frame denial,
  no-referrer, a restrictive permissions policy, and `Cache-Control: no-store`.

`/healthz` is liveness-only: it proves the UI process can answer HTTP and does
not inspect monitoring state. `/readyz` is the operational readiness probe. A
decisive source is fresh for two of its configured intervals; every ID in
`FABLE_MONITOR_REQUIRED_SOURCES` must be fresh and at least
`FABLE_MONITOR_MIN_DECISIVE_SOURCES` decisive sources must be fresh. Readiness
also fails if a pending delivery is due and its lease has expired.

## Article reader

The reader is disabled by default. Enable it only for a trusted, loopback or
authenticated deployment with `FABLE_MONITOR_READER=1`. The initial URL must be
an exact URL already present in the retained UI event window or alert state, and
its host must occur in configured sources, events, or alerts. Only public HTTPS,
port 443, without URL credentials is accepted. Literal loopback, private,
link-local, multicast, unspecified, documentation, and metadata ranges are
rejected for IPv4/IPv6. Hostnames are resolved by the process, every answer must
be public, and the validated addresses are pinned into curl to prevent a second
DNS lookup. Redirects are not followed; curl limits connection time to 5 seconds,
total time to 15 seconds, response size to 16 MiB, and content type to HTML/XHTML;
scripts are stripped before rendering.

These are meaningful SSRF limits, not complete proxy isolation. Accepted client
sockets still have no request/header deadline. Reader work is admitted through a
bounded detached-worker limit so a fetch does not occupy the accept loop, but the
HTTP server otherwise remains single-threaded. Keep the reader disabled where
those residual risks are unacceptable.

## Implementation

`src/serve.zig`. A minimal HTTP/1.1 server on Zig's `std.Io.net` listener +
`std.http.Server`, one request per connection (`Connection: close`) — the
simplest model for a localhost dashboard, where the browser opens a fresh
connection per poll. Fragments are assembled as plain HTML strings;
event rows reuse `zstd.decompress` + the `events.Event` JSON parser, and source
/ alert rows reuse `state.loadState`, so the UI can only ever show what the CLI
sees. The page shell is a single embedded string constant.
