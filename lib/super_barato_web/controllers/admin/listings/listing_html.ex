defmodule SuperBaratoWeb.Admin.ListingHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin
  import SuperBaratoWeb.Admin.Components

  alias SuperBaratoWeb.Admin.ListingController

  embed_templates "listing_html/*"

  defdelegate thumbnail_url(product), to: SuperBarato.Thumbnails

  def chain_tab_href(nil), do: ~p"/listings"
  def chain_tab_href(chain), do: ~p"/listings?#{[chain: chain]}"

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

  @doc "Display host for a PDP URL — strips `www.`."
  def pdp_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: nil} -> url
      %URI{host: host} -> String.replace_prefix(host, "www.", "")
    end
  end

  def pdp_host(_), do: nil

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
