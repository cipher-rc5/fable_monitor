# Web UI (`serve`)

`fable-monitor serve` runs a small, **read-only** HTTP dashboard over the same
observation log and state file every other command reads. It is the only
long-running mode of an otherwise poll-once CLI, and it exists so the monitor's
status — last poll, configured sources, recent events, active alerts — is
viewable in a browser without `zstd -dc … | jq`.

It is built with [htmx](https://htmx.org) and [Tailwind CSS
v4](https://tailwindcss.com), both pulled from a CDN. There is **no front-end
build step**, no `node_modules`, and no bundler: the Zig binary serves a static
HTML shell, and htmx does the rest in the browser.

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
browser ──GET / ─────────────▶  serve: returns the HTML shell
        ◀────────────────────   (shell <script>s pull htmx + Tailwind v4 from a CDN)

browser ──GET /ui/status ─────▶  serve: reads log + state, returns an HTML fragment
        ◀────────────────────   htmx swaps it into the page
        … repeats on hx-trigger="every Ns" …
```

The shell at `/` contains `hx-get` / `hx-trigger="load, every Ns"` attributes.
htmx issues the fragment requests and swaps the returned HTML into place, so the
page refreshes itself with no JavaScript of our own.

| Endpoint | `hx-trigger` | Content type | Shows |
|---|---|---|---|
| `GET /` | — | `text/html` | The page shell. Loads htmx + Tailwind v4 from a CDN, so the viewing machine needs internet access for those two assets (the data itself is local). |
| `GET /ui/status` | `load, every 5s` | `text/html` | Stat cards: source count, events logged, active-alert count, last observed time. |
| `GET /ui/alerts` | `load, every 5s` | `text/html` | Active (unacknowledged) alerts: tier, kind, title, first-alerted time, status. |
| `GET /ui/sources` | `load, every 30s` | `text/html` | Every configured source with its tier, kind, poll class, and last success / change time (joined from `state.source_status`). |
| `GET /ui/events?limit=N` | `load, every 10s` | `text/html` | The most recent `N` events (default 30), newest first, with per-kind badges. |
| `GET /healthz` | — | `text/plain` | `ok` — a liveness probe. |

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

## Implementation

`src/serve.zig`. A minimal HTTP/1.1 server on Zig's `std.Io.net` listener +
`std.http.Server`, one request per connection (`Connection: close`) — the
simplest robust model for a localhost dashboard, where htmx opens a fresh
connection per poll anyway. Fragments are assembled as plain HTML strings;
event rows reuse `zstd.decompress` + the `events.Event` JSON parser, and source
/ alert rows reuse `state.loadState`, so the UI can only ever show what the CLI
sees. The page shell is a single embedded string constant.
