defmodule SuperBaratoWeb.Admin.Components do
  @moduledoc """
  Shared admin-side function components and chain helpers. Imported
  by every admin HTML module via `use SuperBaratoWeb, :html`-adjacent
  conventions, so call sites can use `<.chain_badge chain={...} />`,
  `chain_label(...)`, etc. without per-module aliases.

  Anything that's app-specific *and* re-used across more than one
  admin page should land here. One-off helpers stay in their owning
  HTML module.
  """
  use Phoenix.Component

  ## Chain identity (label, favicon path, site URL)

  @chain_labels %{
    nil => "All",
    unimarc: "Unimarc",
    jumbo: "Jumbo",
    santa_isabel: "Santa Isabel",
    lider: "Líder",
    tottus: "Tottus",
    acuenta: "aCuenta"
  }

  @chain_favicons %{
    jumbo: "/images/chains/jumbo.png",
    santa_isabel: "/images/chains/santa_isabel.png",
    tottus: "/images/chains/tottus.png",
    lider: "/images/chains/lider.ico",
    unimarc: "/images/chains/unimarc.ico",
    acuenta: "/images/chains/acuenta.ico"
  }

  @chain_site_urls %{
    "jumbo" => "https://www.jumbo.cl",
    "santa_isabel" => "https://www.santaisabel.cl",
    "tottus" => "https://www.tottus.cl",
    "lider" => "https://super.lider.cl",
    "unimarc" => "https://www.unimarc.cl",
    "acuenta" => "https://www.acuenta.cl"
  }

  @doc "Human-friendly chain label, e.g. `:santa_isabel` -> `\"Santa Isabel\"`."
  def chain_label(chain) when is_atom(chain), do: Map.get(@chain_labels, chain, to_string(chain))

  def chain_label(chain) when is_binary(chain) do
    try do
      chain |> String.to_existing_atom() |> chain_label()
    rescue
      ArgumentError -> chain
    end
  end

  @doc """
  Public-served path to the chain's favicon, or `nil` for unknown chains.
  """
  def chain_favicon(chain) when is_atom(chain), do: Map.get(@chain_favicons, chain)

  def chain_favicon(chain) when is_binary(chain) do
    try do
      chain |> String.to_existing_atom() |> chain_favicon()
    rescue
      ArgumentError -> nil
    end
  end

  @doc """
  Canonical URL on the chain's site for `path` (slug, no leading slash).
  Returns nil for unknown chains. Used by category/listing tables to
  link out to the live page.
  """
  def chain_site_url(chain, path) when is_binary(chain) and is_binary(path) do
    case Map.fetch(@chain_site_urls, chain) do
      {:ok, base} -> base <> "/" <> path
      :error -> nil
    end
  end

  def chain_site_url(chain, path) when is_atom(chain),
    do: chain_site_url(Atom.to_string(chain), path)

  def chain_site_url(_, _), do: nil

  ## Components

  attr :chain, :any, required: true, doc: "atom or string chain id"

  @doc """
  Renders the chain's favicon as a small inline mark, with the chain
  label as `alt` + `title` for accessibility / hover. Falls back to
  the plain text label when no favicon is configured.

      <.chain_badge chain={:jumbo} />
      <.chain_badge chain={l.chain} />
  """
  def chain_badge(assigns) do
    src = chain_favicon(assigns.chain)
    label = chain_label(assigns.chain)
    assigns = assign(assigns, src: src, label: label)

    ~H"""
    <%= if @src do %>
      <img src={@src} alt={@label} title={@label} loading="lazy" class="chain-favicon" />
    <% else %>
      {@label}
    <% end %>
    """
  end
end
