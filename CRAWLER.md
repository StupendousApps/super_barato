# Crawler

A map for when I come back to this. Not a tutorial.

## What it does

Crawls four Chilean supermarket chains (Unimarc, Jumbo, Santa Isabel, Lider), keeps the latest price + metadata in Postgres, and appends every price observation to file logs.

## Pipeline

Per chain, supervised together under `Crawler.Chain.Supervisor` with `:rest_for_one`:

```
                    ┌──────────────────────────────────────────────┐
                    │ Crawler.Chain.Supervisor (per chain)         │
                    │                                              │
                    │   Results ──► DB (categories, chain_listings)│
                    │      ▲        PriceLog (<dir>/<chain>/*.log) │
                    │      │                                       │
                    │      │ record(task, payload)                 │
                    │      │                                       │
                    │   Worker ──► adapter.handle_task(task)       │
                    │      │                                       │
                    │      │ pop                                   │
                    │      ▼                                       │
                    │   Queue ◄─ push ── Cron / Producer / Results │
                    │      ▲      └─── requeue (Worker on :blocked)│
                    │      │                                       │
                    │   Cron ──► Task.Supervisor ──► ProductProducer│
                    │                                              │
                    └──────────────────────────────────────────────┘
```

Four long-lived GenServers (Results, Queue, Worker, Cron) plus a Task.Supervisor for transient Producer tasks.

**Flow:**
1. Cron fires on schedule → spawns a Task under Task.Supervisor.
2. Task pushes one or more tasks onto the Queue.
3. Worker pops, paces, calls `adapter.handle_task/1`.
4. Adapter returns `{:ok, payload} | :blocked | {:error, _}`.
5. On `:ok` → Worker casts to Results, which persists.
6. On `:blocked` → Worker rotates profile via Session, requeues task at front.
7. On `:error` → Worker logs, task is dropped.

Results also pushes follow-up tasks for category tree walks (not currently used by any adapter).

## Stages

Two stages. `:prices` was folded into `:products`.

| Stage | Cadence | What it does |
|---|---|---|
| Categories | weekly | Walk chain's tree, upsert `categories` rows |
| Products | daily | For each leaf category, fetch + parse, upsert `chain_listings`, append to PriceLog |

The `:products` stage captures current prices as a side effect — the same search endpoints return them.

## Chain-specific notes

| Chain | Endpoint style | curl profile | Page size | Notes |
|---|---|---|---|---|
| Unimarc | SMU BFF JSON | default chrome116 | 50 | Term-fanout for top-level discovery + static fallback list |
| Jumbo | Cencosud BFF JSON | chrome116 | 40 | Static `categories.json`, keyed by `itemId` |
| Santa Isabel | Cencosud BFF (same as Jumbo) | chrome116 | 40 | Same code path as Jumbo, different `sales_channel` + categories URL |
| Lider | Next.js HTML (`__NEXT_DATA__`) | chrome107 required | 46 | Akamai blocks chrome110+ and all Firefox/Safari |

Adapter module per chain, all under `lib/super_barato/crawler/`. Jumbo and SantaIsabel share `Crawler.Cencosud` via a `Config` struct.

## Key files

```
lib/super_barato/
├── crawler.ex                     # @adapters registry, known_chains
├── crawler/
│   ├── chain.ex                   # Behaviour: handle_task/1 + refresh_identifier/0
│   ├── chain/
│   │   ├── supervisor.ex          # :rest_for_one per chain
│   │   ├── queue.ex               # Bounded FIFO, blocking push/pop, requeue
│   │   ├── worker.ex              # pop → sleep → dispatch → route
│   │   ├── results.ex             # Persist + append to PriceLog
│   │   ├── cron.ex                # Scheduler (:every / :weekly cadences)
│   │   └── product_producer.ex    # Transient: stream leaf categories → Queue
│   ├── http.ex                    # curl-impersonate wrapper, blocked?/1
│   ├── session.ex                 # ETS: per-chain :profile, rotate_profile/2
│   ├── category.ex / listing.ex   # Plain structs
│   ├── unimarc.ex
│   ├── jumbo.ex / santa_isabel.ex / cencosud.ex
│   └── lider.ex
├── catalog.ex                     # Ecto upsert + query helpers
├── catalog/{category,chain_listing,product}.ex        # schemas
└── price_log.ex                   # append/read for <dir>/<chain>/<sku>.log

lib/mix/tasks/
├── crawler.categories.ex          # Debug — print, no writes
├── crawler.products.ex            # Debug — print, no writes
├── crawler.info.ex                # Debug — single SKU via fetch_product_info
└── crawler.trigger.ex             # Real — writes DB + PriceLog

config/
├── config.exs                     # Per-chain schedule, fallback profiles, curl dir
├── dev.exs / prod.exs             # Logger format, :chain + :role metadata
└── runtime.exs

test/support/fixtures/             # Real JSON/HTML payloads per chain
test/support/stub_adapter.ex       # Test stand-in for adapters
```

## CLI commands

| Command | Writes? | Purpose |
|---|---|---|
| `mix crawler.trigger <chain> discover` | yes | One-shot category walk |
| `mix crawler.trigger <chain> products [--limit N] [--category S] [--interval MS]` | yes | Leaf-category sweep |
| `mix crawler.categories <chain> [--summary] [--leaves-only]` | no | Adapter smoke — print category structs |
| `mix crawler.products <chain> --category S [--limit N] [--summary]` | no | Adapter smoke — print listings |
| `mix crawler.info <chain> <id> [<id>...]` | no | Adapter smoke — single-SKU refresh preview |

Smoke tasks print `%Listing{}` / `%Category{}` structs via `IO.inspect`. They skip the pipeline entirely — straight `adapter.handle_task/1`, no DB, no PriceLog.

`crawler.trigger` goes through the real persistence path (`Results.persist_sync/4`) but runs synchronously in the Mix process — doesn't need the chain supervisor to be up.

## Scheduling

Two cadence forms accepted by `Chain.Cron`:

```elixir
# Interval: N units from now, repeat
{:every, {N, :second | :minute | :hour | :day | :days}}

# Time-of-day: cross product of (days × times), UTC
{:weekly, [day_atoms], [%Time{}]}
#   day_atoms: :mon | :tue | :wed | :thu | :fri | :sat | :sun
#   :weekly [:mon..:sun] [~T[05:00:00]]   ≡ "daily at 05:00 UTC"
#   :weekly [:mon]       [~T[04:00:00]]   ≡ "once weekly, Mon 04:00"
```

Schedule lives per-chain in `config/config.exs` under `:super_barato, SuperBarato.Crawler, :chains`. Staggered so chains don't pound the network at the same moment. UTC — Chile is UTC-3/-4.

## Profile rotation

Akamai/WAF blocks certain TLS fingerprints. We work around it with `curl-impersonate`.

- `Crawler.Http` shells out to `priv/bin/curl_<profile>` (see `install_curl_impersonate.sh`).
- Per-chain **fallback list** in config (order = preference).
- Worker runs with the chain's current `:profile` (ETS, via `Session.get(chain, :profile)`).
- On any response that `Http.blocked?/1` says is a challenge (307, 403, 429, 503, or Akamai body markers): `Session.rotate_profile(chain, fallback_list)` and requeue the task.
- After cycling through every profile consecutively, Worker sleeps (`block_backoff_ms`, default 60s) to avoid hammering a dead endpoint.

Verified profile facts:
- Unimarc/Jumbo/SI: `chrome116` works, fallbacks `chrome107/100/99`.
- Lider: Akamai blocks `chrome110+` and all Firefox/Safari. Pinned to `chrome107`, fallbacks `chrome104/101/100/99/99_android/edge101/edge99`.

## Price logs

Files at `<price_log_dir>/<chain>/<chain_sku>.log`:

```
1776000000 1490
1776086400 1490 990
1776172800 1490
```

Format: `<unix_seconds> <regular_price> [<promo_price>]`. Time first = works with `sort`, `head`, `tail`, `awk`, `grep range`.

**Config**: `:super_barato, :price_log_dir` (default `priv/data/prices`, gitignored). Prod should override to somewhere outside the release.

**Writes**: `File.write(path, line, [:append, :binary])` — atomic under PIPE_BUF (4096). No locking.

**Pruning** (run periodically — no built-in cron entry):

```bash
# Gzip anything untouched in 90 days
find /data/prices -name '*.log' -mtime +90 -exec gzip {} \;

# Delete logs for inactive chains
rm -rf /data/prices/<chain>
```

**Read from Elixir**: `SuperBarato.PriceLog.read(chain, chain_sku)` → `[{unix, regular, promo_or_nil}]`.

## Configuration cheat sheet

Top-level in `config/config.exs`:

```elixir
config :super_barato, SuperBarato.Crawler,
  chains_enabled: false,     # master switch — flip on in prod to start pipeline
  chains: [
    <chain>: [
      interval_ms: 1_000,            # worker pacing
      fallback_profiles: [...],      # rotation order on block
      schedule: [                    # {cadence, {mfa}} tuples
        {{:weekly, [:mon], [~T[04:00:00]]}, {Queue, :push, [...]}},
        {{:weekly, [:mon..:sun], [~T[05:00:00]]}, {ProductProducer, :run, [[chain: :...]]}}
      ]
    ],
    ...
  ]

config :super_barato,
  curl_impersonate_dir: "priv/bin",
  curl_impersonate_profile: :chrome116,   # default for chains not specifying
  price_log_dir: "priv/data/prices"
```

## Adding a new chain

1. **Probe** — use `priv/bin/curl_chrome116` (or older) to find the API/HTML endpoints. Save a few responses as fixtures under `test/support/fixtures/<chain>/`.

2. **Adapter** — `lib/super_barato/crawler/<chain>.ex` with `@behaviour Crawler.Chain`. Implement `id/0`, `refresh_identifier/0`, `handle_task/1`. Expose parse helpers with `@doc false` so tests can feed decoded fixtures directly.

3. **Register** — add to `@adapters` in `lib/super_barato/crawler.ex`.

4. **Config** — add a `chains: [<chain>: [...]]` block to `config/config.exs` with interval, fallback profiles, and schedule.

5. **Tests** — `test/super_barato/crawler/<chain>_test.exs` with fixture-driven parser assertions.

6. **Verify live** — `mix crawler.categories <chain> --summary`, `mix crawler.products <chain> --category X --summary`. Expect real data back.

## Debugging

| Symptom | Check |
|---|---|
| Empty results | Run a smoke task (`crawler.categories <chain>`) — does adapter work? |
| `:blocked` repeating | Check current `Session.get(chain, :profile)`; update fallback list |
| "all profiles blocked" | Akamai changed the blocklist. Probe with other curl-impersonate profiles; update config |
| DB rows missing | Is `chains_enabled: true`? Is the chain's Supervisor alive? Check Logger for `chain=<x>` lines |
| Worker stuck | `:sys.get_state({:via, Registry, {SuperBarato.Crawler.Registry, {Worker, :<chain>}}})` |
| Test flakes in pipeline integration | DataCase sandbox + async — check `async: false` and `start_supervised` ordering |

## Tests

`mix test` — 132 as of writing. Three kinds:

- **Unit** (parsers, Session, Http.blocked?, Cron delay_ms, PriceLog) — fast, deterministic.
- **Per-module** (Queue, Worker, Results, Cron, ProductProducer) — use StubAdapter + Ecto sandbox.
- **Integration** (`pipeline_integration_test.exs`) — end-to-end Cron → DB via StubAdapter.

Fixtures at `test/support/fixtures/<chain>/` are real responses captured via curl-impersonate. Re-capture when upstream schemas drift.
