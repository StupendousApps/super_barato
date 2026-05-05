# Two-stage build that produces an OTP release. Same shape as the
# Dockerfile `mix phx.gen.release --docker` emits, with three extras:
#
#   * SQLite — Ecto.Adapters.SQLite3 ships a self-contained NIF, so no
#     system sqlite package is needed. We do install `ca-certificates`
#     in the runner so the price-log writer + outbound HTTPS work.
#   * curl-impersonate — the crawler shells out to per-profile binaries
#     under `priv/bin/curl_<profile>` to slip past Akamai's TLS
#     fingerprinting. The builder downloads the Linux-amd64 tarball and
#     unpacks it into the release; the runner copies them in.
#   * Build context is the *parent* of super_barato (the repo root that
#     also holds stupendous_admin and stupendous_thumbnails) so the
#     `path: "../<lib>"` deps resolve inside the build. Both `bin/kamal`
#     (via deploy.yml's builder.context) and the local smoke build use
#     that wider context.
#
# Local smoke (run from inside super_barato/):
#
#     docker build -f Dockerfile -t super_barato:test --platform linux/amd64 ..

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4.2
ARG DEBIAN_VERSION=bookworm-20260421-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git curl ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Vendor the path-deps first so subsequent COPY /super_barato can
# resolve `../stupendous_admin` and `../stupendous_thumbnails`
# relative to mix.exs.
WORKDIR /build
COPY stupendous_admin /build/stupendous_admin/
COPY stupendous_thumbnails /build/stupendous_thumbnails/

WORKDIR /build/super_barato

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Pull deps (with the lockfile only — no source yet) so this layer
# caches well between code-only changes.
COPY super_barato/mix.exs super_barato/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY super_barato/config/config.exs super_barato/config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY super_barato/priv priv
COPY super_barato/lib lib
COPY super_barato/assets assets

# Fetch curl-impersonate Linux-amd64 binaries into priv/bin/. The
# install script picks the right tarball for the build platform; this
# image is amd64 (see deploy.yml's builder.arch).
COPY super_barato/scripts/install_curl_impersonate.sh scripts/
RUN bash scripts/install_curl_impersonate.sh

# Compile first so Phoenix generates the colocated-hooks module that
# `assets/js/app.js` imports as `phoenix-colocated/super_barato`.
RUN mix compile

# Bundle assets + the release.
RUN mix assets.deploy
COPY super_barato/config/runtime.exs config/
COPY super_barato/rel rel
RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
    sqlite3 \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Run as UID 1000 — same as the deploy box's `ubuntu` user — so files
# written to the bind-mounted /data volumes are readable from the
# host shell without sudo.
RUN groupadd -g 1000 app && useradd -u 1000 -g 1000 -m -d /app app

WORKDIR /app

ENV MIX_ENV=prod

COPY --from=builder --chown=app:app /build/super_barato/_build/${MIX_ENV}/rel/super_barato ./

USER app

CMD ["/app/bin/server"]
