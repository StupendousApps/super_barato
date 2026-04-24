defmodule SuperBaratoWeb.Admin.ListingHTML do
  use SuperBaratoWeb, :html

  alias SuperBaratoWeb.Admin.ListingController

  embed_templates "listing_html/*"

  @chain_labels %{
    nil => "All",
    unimarc: "Unimarc",
    jumbo: "Jumbo",
    santa_isabel: "Santa Isabel",
    lider: "Líder",
    tottus: "Tottus"
  }

  def chain_label(chain) when is_atom(chain), do: Map.get(@chain_labels, chain, to_string(chain))

  def chain_label(chain) when is_binary(chain) do
    try do
      chain |> String.to_existing_atom() |> chain_label()
    rescue
      ArgumentError -> chain
    end
  end

  def chain_tab_href(nil), do: ~p"/admin/listings"
  def chain_tab_href(chain), do: ~p"/admin/listings?#{[chain: chain]}"

  @doc "Values usable as sub-nav items: nil for All, then each known chain."
  def chain_tabs, do: ListingController.chains()

  def format_clp(nil), do: "—"

  def format_clp(n) when is_integer(n) do
    "$" <>
      (n
       |> Integer.to_string()
       |> String.reverse()
       |> String.graphemes()
       |> Enum.chunk_every(3)
       |> Enum.map(&Enum.join/1)
       |> Enum.join(".")
       |> String.reverse())
  end

  def format_datetime(nil), do: "—"
  def format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
