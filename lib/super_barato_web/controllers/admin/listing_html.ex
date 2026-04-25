defmodule SuperBaratoWeb.Admin.ListingHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin

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

  ## Sort helpers (consumed by the library's <.table>).

  @doc "Atom direction for the column header indicator."
  def sort_dir(field, current) do
    cond do
      current == field -> :asc
      current == "-" <> field -> :desc
      true -> :none
    end
  end

  @doc "URL the column header links to — flips direction on each click."
  def sort_href(path, params, field, current) do
    next = if current == field, do: "-" <> field, else: field
    qs = params |> Map.put("sort", next) |> Enum.reject(fn {_, v} -> v in [nil, ""] end)

    case qs do
      [] -> path
      _ -> path <> "?" <> URI.encode_query(qs)
    end
  end
end
