# Two-stage build that produces an OTP release. Same shape as the
# Dockerfile `mix phx.gen.release --docker` emits, with two extras:
#
#   * SQLite — Ecto.Adapters.SQLite3 ships a self-contained NIF, so no
#     system sqlite package is needed. We do install `ca-certificates`
#     in the runner so the price-log writer + outbound HTTPS work.
#   * curl-impersonate — the crawler shells out to per-profile binaries
#     under `priv/bin/curl_<profile>` to slip past Akamai's TLS
#     fingerprinting. The builder downloads the Linux-amd64 tarball and
#     unpacks it into the release; the runner copies them in.

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4.2
ARG DEBIAN_VERSION=bookworm-20250630-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git curl ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Pull deps (with the lockfile only — no source yet) so this layer
# caches well between code-only changes.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Fetch curl-impersonate Linux-amd64 binaries into priv/bin/. The
# install script picks the right tarball for the build platform; this
# image is amd64 (see deploy.yml's builder.arch).
COPY scripts/install_curl_impersonate.sh scripts/
RUN bash scripts/install_curl_impersonate.sh

# Compile assets + the release.
RUN mix assets.deploy
COPY config/runtime.exs config/
COPY rel rel
RUN mix compile
RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV=prod

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/super_barato ./

USER nobody

CMD ["/app/bin/server"]
