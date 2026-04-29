defmodule SuperBaratoWeb.Admin.AppCategoryHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin
  import SuperBaratoWeb.Admin.Components

  embed_templates "app_category_html/*"

  @doc "CLP integer formatted with thousands separators."
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

  @doc "Effective sale price — promo if it's a real discount, otherwise regular."
  def effective_price(%{current_promo_price: p, current_regular_price: r})
      when is_integer(p) and is_integer(r) and p < r,
      do: p

  def effective_price(%{current_regular_price: r}), do: r

  @doc "Display host for a PDP URL — strips `www.`."
  def pdp_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: nil} -> url
      %URI{host: host} -> String.replace_prefix(host, "www.", "")
    end
  end

  def pdp_host(_), do: nil

  @doc """
  Indicator direction for a column header. `field` is the bare sort
  key (e.g. `"name"`); `current` is the active sort key, optionally
  `-`-prefixed for desc.
  """
  def sort_dir(field, current) do
    cond do
      current == field -> :asc
      current == "-" <> field -> :desc
      true -> :none
    end
  end

  @doc """
  URL that flips the sort direction. `key` is the query-param name
  (`cat_sort` or `sub_sort`). Other params are preserved verbatim.
  """
  def sort_href(path, key, field, current, extras) do
    next = if current == field, do: "-" <> field, else: field
    qs = extras |> Map.put(key, next) |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    if qs == [], do: path, else: path <> "?" <> URI.encode_query(qs)
  end

  @doc "Builds the query map for drilling into a category or subcategory."
  def drill_to_category(slug, extras) do
    extras
    |> Map.put("category", slug)
    |> Map.delete("subcategory")
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  def drill_to_subcategory(category_slug, subcategory_slug, extras) do
    extras
    |> Map.put("category", category_slug)
    |> Map.put("subcategory", subcategory_slug)
    |> Map.delete("mapping")
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  def drill_to_mapping(category_slug, subcategory_slug, chain_category_id, extras) do
    extras
    |> Map.put("category", category_slug)
    |> Map.put("subcategory", subcategory_slug)
    |> Map.put("mapping", to_string(chain_category_id))
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Map.new()
  end
end
