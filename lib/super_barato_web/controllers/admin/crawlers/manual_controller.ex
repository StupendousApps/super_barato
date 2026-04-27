defmodule SuperBaratoWeb.Admin.ManualController do
  @moduledoc """
  Synchronous "Manual" crawl probe — drives `Crawler.Probe.run/1` for
  a single chain + kind (+ optional category) and renders the full
  report. No GenServers, no queue, no Worker; debugging-only.

  The URL the probe hits isn't a form input: it's resolved from the
  inputs (categories endpoint for `:categories`; the `pdp_url` of an
  existing listing in the chosen category for `:product_pdp`). The
  report shows the URL prominently so the operator can see what was
  actually fetched.
  """
  use SuperBaratoWeb, :controller

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.Probe

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :admin}
  plug :assign_nav

  defp assign_nav(conn, _opts) do
    conn
    |> assign(:top_nav, :crawlers)
    |> assign(:sub_nav, :manual)
  end

  def index(conn, params) do
    chain = parse_chain(params["chain"]) || List.first(Crawler.known_chains())
    kind = parse_kind(params["kind"]) || :categories
    category_slug = sanitize_slug(params["category_slug"])

    inputs = %{chain: chain, kind: kind, category_slug: category_slug}

    {report, resolved_url} =
      cond do
        params["run"] == "1" ->
          report = safe_run(inputs)
          {report, report.url}

        true ->
          # Don't probe; just resolve the URL so the form shows what
          # would be hit.
          case Probe.resolve_url(inputs) do
            {:ok, url} -> {nil, url}
            {:error, _} -> {nil, nil}
          end
      end

    conn
    |> assign(:page_title, "Crawlers · Manual probe")
    |> assign(:chains, Crawler.known_chains())
    |> assign(:kinds, Probe.kinds())
    |> assign(:chain, chain)
    |> assign(:kind, kind)
    |> assign(:category_slug, category_slug)
    |> assign(:category_options, Probe.category_options(chain))
    |> assign(:resolved_url, resolved_url)
    |> assign(:report, report)
    |> render(:index)
  end

  defp safe_run(inputs) do
    Probe.run(inputs)
  rescue
    err ->
      %{__exception__: true, message: Exception.message(err), stacktrace: __STACKTRACE__}
  end

  defp parse_chain(s) when is_binary(s) and s != "" do
    try do
      atom = String.to_existing_atom(s)
      if atom in Crawler.known_chains(), do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
  end

  defp parse_chain(_), do: nil

  defp parse_kind(s) when is_binary(s) and s != "" do
    try do
      atom = String.to_existing_atom(s)
      if atom in Probe.kinds(), do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
  end

  defp parse_kind(_), do: nil

  defp sanitize_slug(s) when is_binary(s) and s != "", do: s
  defp sanitize_slug(_), do: nil
end
