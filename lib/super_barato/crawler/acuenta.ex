defmodule SuperBarato.Crawler.Acuenta do
  @moduledoc """
  Acuenta adapter — **plumbing only**. The chain is registered with the
  Crawler, surfaced in the admin UI, and given a (currently empty) cron
  schedule, but no parsers are wired up yet. Every `handle_task/1` call
  short-circuits with `{:error, :not_implemented}` so an accidental
  manual trigger is harmless.

  Backend (for the follow-up implementer): Instaleap multi-tenant
  GraphQL at `https://nextgentheadless.instaleap.io/api/v2` with header
  `client: SUPER_BODEGA` — the tenant id, derived from "Super Bodega
  aCuenta", the chain's previous retail brand. Operations the SPA
  dispatches against this endpoint (discoverable in
  `/_next/static/chunks/app/layout-*.js`) cover categories, search-by-
  category, and product-by-id.

  Owned by Walmart Chile (same parent as Lider) but a separate stack —
  Lider runs on Walmart Tipsa, Acuenta on Instaleap. Cross-chain EAN
  matching against Lider is expected to be high once the parser ships.
  """

  @behaviour SuperBarato.Crawler.Chain

  @chain :acuenta

  @impl true
  def id, do: @chain

  @impl true
  # Best guess until the parser lands; Instaleap exposes per-item EANs
  # in its product responses, so refreshing by EAN is the natural
  # cadence. Easy to flip to `:chain_sku` if the API turns out to
  # prefer item ids.
  def refresh_identifier, do: :ean

  @impl true
  def handle_task(_task), do: {:error, :not_implemented}
end
