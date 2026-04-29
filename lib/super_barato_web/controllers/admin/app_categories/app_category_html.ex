defmodule SuperBaratoWeb.Admin.AppCategoryHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin
  import SuperBaratoWeb.Admin.Components

  embed_templates "app_category_html/*"

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
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Map.new()
  end
end
