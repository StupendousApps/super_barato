# Deploying a Stupendous Elixir/Phoenix app via Kamal

This is the playbook for taking a Phoenix app and getting it on a real server,
captured from the super_barato deploy. It applies to any Phoenix app in this
org regardless of whether it uses Postgres or SQLite — DB-specific bits are
called out where they diverge.

The target environment we standardize on:

- **Host**: a Linux amd64 box (Kimsufi for the Stupendous fleet — `ubuntu`
  user, passwordless sudo, Docker installed by `kamal setup`).
- **Image registry**: GHCR (`ghcr.io`).
- **Reverse proxy**: kamal-proxy (TLS via Let's Encrypt, host-based routing).
- **Build host**: your laptop, with Docker Desktop. (See `Common errors` for
  why we don't use OrbStack.)

---

## 0. Project layout

The only files you create per app to make it deployable:

```
.
├── Gemfile                            # pins kamal gem
├── bin/kamal                          # Bundler wrapper (chmod +x)
├── mise.toml                          # erlang, elixir, ruby pins
├── Dockerfile                         # two-stage release build
├── .dockerignore
├── config/deploy.yml                  # kamal config
├── .kamal/secrets                     # macOS keychain reads (gitignored values)
├── rel/overlays/bin/server            # release entry point (chmod +x)
├── rel/overlays/bin/migrate           # release migrator (chmod +x)
├── lib/<app>/release.ex               # SuperBarato.Release-style helper
└── lib/<app>_web/plugs/health.ex      # /up healthcheck
```

`mix phx.gen.release --docker` generates many of these. We diverge from its
defaults in a few places (call those out below).

---

## 1. Tooling pins

### mise.toml

```toml
[tools]
erlang = "28.4.2"
elixir = "1.19.5"
ruby = "3.4.5"        # for the kamal gem
```

`erlang` + `elixir` should match what you're running locally and what the
Docker base image provides. `ruby` is purely so `bin/kamal` works.

### Gemfile

```ruby
source 'https://rubygems.org'

# Only Kamal — this repo is an Elixir/Phoenix app, Ruby is here purely
# to run `bin/kamal`.
gem 'kamal', '~> 2.4'
```

### bin/kamal (chmod +x)

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "rubygems"
require "bundler/setup"

load Gem.bin_path("kamal", "kamal")
```

Run `bundle install` once after creating these.

---

## 2. Database setup

### Postgres

`config/runtime.exs` (prod block):

```elixir
database_url =
  System.get_env("DATABASE_URL") ||
    raise """
    environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """

config :my_app, MyApp.Repo,
  url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  socket_options: if(System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: [])
```

In `config/deploy.yml`:

```yaml
env:
  secret:
    - DATABASE_URL
```

`DATABASE_URL` lives in `.kamal/secrets`.

### SQLite

`config/runtime.exs` (prod block):

```elixir
database_path =
  System.get_env("DATABASE_PATH") ||
    raise """
    environment variable DATABASE_PATH is missing.
    Example: /data/db/my_app.db
    """

config :my_app, MyApp.Repo,
  database: database_path,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
  journal_mode: :wal,
  busy_timeout: 5_000
```

In `config/deploy.yml`:

```yaml
env:
  clear:
    DATABASE_PATH: /data/db/my_app.db
```

`config/test.exs` should also have `journal_mode: :wal` and `busy_timeout`,
plus `ExUnit.start(max_cases: 1)` in `test_helper.exs` (SQLite serializes
writers, so async test modules hit `SQLITE_BUSY` without it).

mix.exs swap: `{:postgrex, ">= 0.0.0"}` → `{:ecto_sqlite3, "~> 0.18"}`.

---

## 3. Dockerfile

Two-stage build. Keep `mix phx.gen.release --docker` as the starting point;
the changes we layer on:

1. **`mix compile` before `mix assets.deploy`** — Phoenix's colocated-hooks
   import (`phoenix-colocated/<app>`) is generated during compile; esbuild
   needs it on `NODE_PATH`.
2. **chmod +x on `rel/overlays/bin/{server,migrate}`** — `phx.gen.release`
   writes them as 0644, container exits 126 ("permission denied") otherwise.
   Fix once locally: `chmod +x rel/overlays/bin/{server,migrate}` then commit.
   git tracks the mode bit.
3. **Run as UID 1000** — match the deploy box's `ubuntu` user so files
   written to bind-mounted volumes are readable from the host without sudo.
4. **Migrate on container start** — modify `bin/server` (see §5).

Skeleton (Phoenix + Postgres):

```dockerfile
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4.2
ARG DEBIAN_VERSION=bookworm-20260421-slim   # check hub.docker.com/r/hexpm/elixir/tags

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git curl ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Compile first so phoenix-colocated/<app> exists for esbuild.
RUN mix compile

RUN mix assets.deploy
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# Run as UID 1000 (= ubuntu on the host) so bind-mount writes are
# readable from the host shell without sudo.
RUN groupadd -g 1000 app && useradd -u 1000 -g 1000 -m -d /app app
WORKDIR /app

ENV MIX_ENV=prod

COPY --from=builder --chown=app:app /app/_build/${MIX_ENV}/rel/my_app ./

USER app
CMD ["/app/bin/server"]
```

**SQLite:** `ecto_sqlite3` ships sqlite as a NIF. No extra system package
needed in the runner.

**Path-deps (e.g. shared internal libraries):** if `mix.exs` has
`{:foo, path: "../foo"}`, the build context must include `../`.
Two changes:

1. Restructure the Dockerfile so all `COPY` lines are prefixed with
   `my_app/...` and the path-dep is copied separately:
   ```dockerfile
   WORKDIR /build
   COPY foo /build/foo/

   WORKDIR /build/my_app
   COPY my_app/mix.exs my_app/mix.lock ./
   ...
   ```
2. In `config/deploy.yml`:
   ```yaml
   builder:
     arch: amd64
     context: ../
     dockerfile: Dockerfile
   ```

For local smoke from inside the app dir: `docker build -f Dockerfile -t my_app:test --platform linux/amd64 ..`.

---

## 4. .dockerignore

```
.git
!.git/HEAD
!.git/refs

/cover/
/doc/
/test/
/tmp/
.elixir_ls/
*.ez

/_build/
/deps/

erl_crash.dump

# Built inside the image via mix assets.deploy.
priv/static/assets/

# Bind mounts in prod.
priv/data/

# (SQLite app only) — same dir, called out explicitly.
priv/repo/

# Kamal secret reader — don't leak macOS keychain wrappers into the image.
.kamal/secrets*

.dockerignore
Dockerfile
```

If you've expanded the build context to the parent (path-dep case), put a
`.dockerignore` at the parent dir too — otherwise sibling repos' `_build`
and `deps` will inflate the context.

---

## 5. Release scripts

### lib/<app>/release.ex

Generated by `mix phx.gen.release`. Add a `seed/0` function alongside
`migrate/0` — `priv/repo/seeds.exs` is **not** shipped in the OTP
release, so `Code.eval_file/1` against that path fails with `enoent`
in prod. Pattern:

```elixir
def seed do
  load_app()
  for repo <- repos(),
      do: {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _ -> seed_data() end)
end

defp seed_data do
  # Inline whatever priv/repo/seeds.exs would do — superadmin,
  # default rows, etc. Reuse context functions; keep it idempotent.
end
```

Then on prod:

```bash
bin/kamal app exec --reuse 'bin/my_app eval "MyApp.Release.seed()"'
```

### rel/overlays/bin/server (chmod +x)

Modify to migrate on boot:

```sh
#!/bin/sh
set -eu

cd -P -- "$(dirname -- "$0")"

# Idempotent. Ecto.Migrator skips already-applied migrations.
./my_app eval MyApp.Release.migrate

PHX_SERVER=true exec ./my_app start
```

This makes deploys self-migrating — no separate `kamal migrate` step.

### rel/overlays/bin/migrate (chmod +x)

Keep the generated version; it's still useful for ad-hoc ops:

```sh
#!/bin/sh
set -eu
cd -P -- "$(dirname -- "$0")"
exec ./my_app eval MyApp.Release.migrate
```

---

## 6. Healthcheck — `/up`

Don't try to fit the healthcheck into the router (host constraints, sessions,
CSRF all get in the way). Mount it as an early plug in the endpoint:

```elixir
# lib/<app>_web/plugs/health.ex
defmodule MyAppWeb.Plugs.Health do
  @behaviour Plug
  import Plug.Conn

  def init(_), do: :ok

  def call(%{request_path: "/up"} = conn, _) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "OK")
    |> halt()
  end

  def call(conn, _), do: conn
end
```

Wire it in the endpoint **before** `Plug.Static`:

```elixir
plug MyAppWeb.Plugs.Health
plug Plug.Static, ...
```

In `config/deploy.yml`:

```yaml
proxy:
  healthcheck:
    path: /up
    interval: 5
```

Kamal 2.4 requires the hash form here (`healthcheck: false` errors with
"should be a hash").

---

## 7. config/deploy.yml

Annotated reference (copy + adapt):

```yaml
service: my_app

ssh:
  user: ubuntu                           # passwordless sudo on the box

image: stupendousapps/my_app             # GHCR namespace/repo

servers:
  web:
    hosts:
      - 51.161.116.221
    options:
      memory: 1g
      memory-reservation: 256m

proxy:
  ssl: true
  hosts:
    - my-app.tld
    - www.my-app.tld
    - admin.my-app.tld                   # if you split admin onto a subdomain
  app_port: 4000
  healthcheck:
    path: /up
    interval: 5

registry:
  server: ghcr.io
  username: fceruti
  password:
    - KAMAL_REGISTRY_PASSWORD            # GHCR PAT in keychain

env:
  secret:
    - SECRET_KEY_BASE
    # Postgres:
    - DATABASE_URL
    # SQLite:
    # (no secret needed, path is in env.clear)
  clear:
    PHX_HOST: my-app.tld
    # No PORT — Phoenix defaults to 4000 in prod, matches proxy.app_port.
    # Use a different port only in config/dev.exs to dodge local
    # collisions when running multiple apps.
    # SQLite:
    DATABASE_PATH: /data/db/my_app.db
    # File-logging retention (defaults shown; override to tune):
    LOG_DIR: /data/log
    # LOG_MAX_FILES: "5"
    # LOG_MAX_BYTES: "10485760"

# One bind mount per concern. Easier ops: backup the DB without
# touching logs, etc.
#
# Postgres apps drop the db mount.
volumes:
  - "/data/my_app/db:/data/db"           # SQLite only
  - "/data/my_app/log:/data/log"
  - "/data/my_app/uploads:/data/uploads" # if you have user uploads

aliases:
  console: app exec --interactive --reuse "bin/my_app remote"
  shell:   app exec --interactive --reuse "bash"
  logs:    app logs -f
  migrate: app exec --reuse "bin/migrate"

builder:
  arch: amd64
  # Path-dep case only:
  # context: ../
  # dockerfile: Dockerfile
```

---

## 8. .kamal/secrets

Pulls from the macOS keychain, never disk. Setup once per workstation:

```bash
security add-generic-password -a "$USER" -s my-app-ghcr-pat        -w
security add-generic-password -a "$USER" -s my-app-secret-key-base -w
# Postgres:
security add-generic-password -a "$USER" -s my-app-database-url    -w
```

Each `-w` prompts for the value; paste and hit return.

```bash
# .kamal/secrets
export KAMAL_REGISTRY_PASSWORD=$(security find-generic-password -a "$USER" -s my-app-ghcr-pat -w)
export SECRET_KEY_BASE=$(security find-generic-password -a "$USER" -s my-app-secret-key-base -w)
export DATABASE_URL=$(security find-generic-password -a "$USER" -s my-app-database-url -w)
```

The first kamal run will prompt the keychain for each entry — tick "Always
Allow".

Generate a fresh `SECRET_KEY_BASE` and stash it:

```bash
security add-generic-password -U -a "$USER" -s my-app-secret-key-base \
  -w "$(mix phx.gen.secret)"
```

Copy the GHCR PAT from another Stupendous app:

```bash
PAT=$(security find-generic-password -a "$USER" -s dotty-web-ghcr-pat -w)
security add-generic-password -U -a "$USER" -s my-app-ghcr-pat -w "$PAT"
```

---

## 9. File logging with retention

Hook in `Application.start/2` (only when `LOG_DIR` is set, so dev/test stay
stdout-only):

```elixir
defp configure_file_logging do
  case System.get_env("LOG_DIR") do
    nil -> :ok
    dir ->
      File.mkdir_p!(dir)
      file = dir |> Path.join("my_app.log") |> String.to_charlist()

      max_files = env_int("LOG_MAX_FILES", 5)
      max_bytes = env_int("LOG_MAX_BYTES", 10_485_760)

      :ok = :logger.add_handler(:file_log, :logger_disk_log_h, %{
        config: %{
          file: file,
          type: :wrap,
          max_no_files: max_files,
          max_no_bytes: max_bytes
        },
        formatter: Logger.Formatter.new(
          format: "$time $metadata[$level] $message\n",
          metadata: [:request_id]
        )
      })
  end
end
```

`:logger_disk_log_h` (not `:logger_std_h`) is the rotating handler — std_h
doesn't rotate. `type: :wrap` auto-evicts the oldest file when the wrap is
full, so logs never grow unbounded.

Stdout handler stays mounted alongside, so `kamal app logs -f` keeps
working; the file is the durable copy.

---

## 10. Volume permissions

The container runs as UID 1000, so the host directories the volumes bind to
must be owned by UID 1000 (= `ubuntu`). Provision once before the first
deploy:

```bash
ssh ubuntu@<host> "sudo mkdir -p /data/my_app/{db,log,uploads} \
  && sudo chown -R ubuntu:ubuntu /data/my_app"
```

Skip the `db` line for Postgres apps.

---

## 11. First deploy — concrete checklist

```bash
# 1. Tooling
mise install                                            # erlang/elixir/ruby
bundle install                                          # kamal gem

# 2. Secrets in macOS keychain (once per workstation)
security add-generic-password -a "$USER" -s my-app-ghcr-pat -w
security add-generic-password -U -a "$USER" -s my-app-secret-key-base \
  -w "$(mix phx.gen.secret)"
# + DATABASE_URL etc. as needed

# 3. DNS — add A records for every host in proxy.hosts → server IP

# 4. Provision host volumes with the right ownership
ssh ubuntu@<host> "sudo mkdir -p /data/my_app/{db,log} \
  && sudo chown -R ubuntu:ubuntu /data/my_app"

# 5. Smoke-build locally (catches Dockerfile mistakes without touching prod)
docker build -f Dockerfile -t my_app:test --platform linux/amd64 .
# (or: ... --platform linux/amd64 ..  if path-dep build context)

# 6. Run kamal setup (provisions Docker on the box, builds, pushes,
#    starts container, requests Let's Encrypt certs)
bin/kamal setup

# 7. Verify
curl -sI https://my-app.tld/up                          # expect 200
bin/kamal logs -f                                       # tail in prod
```

After that, normal flow is just `bin/kamal deploy` after each `git push`.
Migrations run automatically on container start (the modified `bin/server`).

---

## 12. Common errors + fixes

| Error | Cause | Fix |
|---|---|---|
| `OS monotonic time stepped backwards! Aborted` during build | Erlang's strict monotonic check trips under emulation/virtualization. Hits Apple Silicon under Rosetta, OrbStack on Intel under load, some QEMU configs. | Use Docker Desktop (native HyperKit/Hypervisor framework) or Kamal's remote builder (`builder.remote: ssh://user@host`). Don't bother with `ERL_AFLAGS` — there's no flag that disables the check. |
| `failed to connect to the docker API at unix:///Users/$USER/.orbstack/run/docker.sock` | Stale docker context after switching from OrbStack. | `docker context use desktop-linux`. Optionally `docker context rm orbstack`. |
| `failed to build: no valid drivers found: unable to parse docker host orbstack` | Kamal's buildx builder cached against the dead orbstack endpoint. | `docker buildx rm kamal-local-docker-container`. Kamal recreates it on next deploy. |
| `proxy/healthcheck: should be a hash` | Kamal 2.4 changed the schema. | `healthcheck: false` → `healthcheck: { path: /up, interval: 5 }`. |
| `Missing my_app/Dockerfile` from Kamal | `dockerfile:` in deploy.yml is resolved relative to the cwd, not relative to `context:`. | `dockerfile: Dockerfile` (bare filename), let Docker resolve via `-f` from cwd. |
| `Cannot compile dependency :foo because it isn't available, please ensure the dependency is at "/foo"` | Path-dep references `"../foo"` but the Docker build context doesn't include the parent. | Expand build context: `builder.context: ../` and restructure Dockerfile COPY paths to `my_app/...`. |
| `mix esbuild ... exited with 1: Could not resolve "phoenix-colocated/my_app"` | `mix assets.deploy` ran before `mix compile`. | Move `RUN mix compile` before `RUN mix assets.deploy` in the Dockerfile. |
| `exec: "/app/bin/server": permission denied` (container exit 126) | `mix phx.gen.release` writes `rel/overlays/bin/{server,migrate}` as 0644. | `chmod +x rel/overlays/bin/{server,migrate}` and commit. git tracks mode bits. |
| `eacces` writing to `/data/log/...` (BEAM crash on boot) | Container UID can't write to host bind-mount. | Match container UID to host's `ubuntu` (1000). Dockerfile: `RUN groupadd -g 1000 app && useradd -u 1000 -g 1000 -m -d /app app` + `USER app`. Then `sudo chown -R ubuntu:ubuntu /data/my_app` on the host. |
| `no such table: <something>` on first container start | DB exists (volume mounted) but migrations haven't run. | `bin/server` should run `MyApp.Release.migrate` before starting the app (see §5). For one-off recovery: `bin/kamal app exec "bin/migrate"` (no `--reuse`, since the running container is dead). |
| `target failed to become healthy within configured timeout (30s)` | `/up` doesn't respond within 30s. Often the app crashed during boot — check `bin/kamal app logs` for the actual stack trace. | Read the logs; this is always a downstream symptom. |
| `Plug.SSL is redirecting GET /up to https://... with status 301` (and healthcheck still fails) | `force_ssl` in `config/prod.exs` is 301-redirecting Kamal's HTTP-only healthcheck before `/up` can respond. The proxy doesn't set `X-Forwarded-Proto` on its internal probe. | Drop the `force_ssl:` block from `config/prod.exs` entirely. Kamal's proxy already redirects HTTP→HTTPS at the edge for real traffic; the app doesn't need to do it again. |
| Phoenix logs `Running ... at :::4000` but `app_port` in deploy.yml is something else | Mismatch between Phoenix's bind port and what Kamal's proxy probes. | Easiest: leave Phoenix at the default 4000 in prod (omit any `PORT` env or `port:` override in `runtime.exs`) and set `proxy.app_port: 4000`. Use a different port (e.g. 4003) only in `config/dev.exs` where local-collision matters. |
| `failed to fetch hexpm/elixir:1.19.5-erlang-...-debian-XXXXXXXX-slim` | The base image tag's debian snapshot date isn't published. hexpm only keeps recent ones. | Pick a real tag from `hub.docker.com/v2/namespaces/hexpm/repositories/elixir/tags?name=1.19.5-erlang-28.4`. |

---

## 13. Notes for future-you

- **Host-based subdomain split.** Phoenix's `host:` option in router scopes
  is the only thing you need — no custom plug. `scope "/", MyApp.Admin,
  host: "admin."` matches any subdomain starting with `admin.`. dotty_web
  uses this; super_barato uses this; nothing else needed.
  **Declare the host-constrained scope BEFORE the catch-all public scope.**
  Phoenix matches in declaration order, and a `scope "/"` without a
  `host:` constraint matches every host — including the admin subdomain.
  If the public scope is declared first, `admin.example.com/` lands on
  the public home page instead of the admin dashboard.
- **Migrations on boot vs. pre-deploy hook.** Both work. Boot-time is
  simpler (one less moving part) but adds a few hundred ms on every
  container start. Pre-deploy hook (`.kamal/hooks/pre-deploy`) is cleaner
  if startup latency matters or migrations are slow.
- **Stable identity for the GHCR PAT.** It's a per-user token, not
  per-app. One PAT in your keychain, copied into each app's
  `<app>-ghcr-pat` keychain entry via `security find-generic-password ...
  | security add-generic-password ... -w "$(...)"`.
- **Build on the box** (`builder.remote: ssh://user@host`) when the
  Mac-side Docker is flaky. The deploy box is native amd64 Linux — no
  emulation, no clock drift, no surprises. Adds ~30s SSH overhead per
  build but is rock-solid.
- **Don't trust `kamal app logs -f` to capture everything.** It's the
  Docker stdout stream. Once a container recycles, those lines are gone.
  The file handler at `LOG_DIR` is the durable copy — read from
  `/data/my_app/log/` on the host directly.
- **TLS lives on the proxy, not the app.** Drop the default `force_ssl:`
  block out of `config/prod.exs`. The Kamal proxy terminates TLS and
  redirects HTTP→HTTPS at the edge; running the same logic inside the
  app just 301s your healthcheck (which probes HTTP-only with no
  `X-Forwarded-Proto`). Real users never see HTTP.
- **Phoenix port stays at 4000 in prod.** Don't set `PORT` in deploy.yml
  or override the bind port in `runtime.exs`. Match `proxy.app_port:
  4000` in deploy.yml and the proxy → container handoff just works.
  Use non-default ports only in `config/dev.exs` to avoid local
  collisions when multiple apps run side-by-side.
