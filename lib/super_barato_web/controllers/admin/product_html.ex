defmodule SuperBaratoWeb.Admin.ProductHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin
  import SuperBaratoWeb.Admin.Components

  alias SuperBaratoWeb.Admin.ListingHTML

  embed_templates "product_html/*"

  defdelegate format_clp(n), to: ListingHTML
  defdelegate sort_dir(field, current), to: ListingHTML
  defdelegate sort_href(path, params, field, current), to: ListingHTML

  @doc """
  Picks the linked listing for `chain` from `listings` (a list of
  `%ChainListing{}` rows), or `nil` if the product isn't linked on
  that chain. When a chain has multiple linked listings (rare —
  future fuzzy-match), returns the cheapest current price.
  """
  def listing_for_chain(listings, chain) when is_list(listings) and is_atom(chain) do
    chain_str = Atom.to_string(chain)

    listings
    |> Enum.filter(&(&1.chain == chain_str))
    |> Enum.min_by(&effective_price/1, fn -> nil end)
  end

  @doc "Returns the listing's effective price — promo if set + lower, else regular."
  def effective_price(%{current_promo_price: promo, current_regular_price: reg})
      when is_integer(promo) and is_integer(reg) and promo < reg,
      do: promo

  def effective_price(%{current_regular_price: reg}) when is_integer(reg), do: reg
  def effective_price(_), do: nil
end
