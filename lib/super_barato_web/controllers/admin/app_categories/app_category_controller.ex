defmodule SuperBaratoWeb.Admin.AppCategoryController do
  use SuperBaratoWeb, :controller

  import Ecto.Query

  alias SuperBarato.Catalog.{AppCategory, AppSubcategory, CategoryMapping, ChainCategory}
  alias SuperBarato.Repo

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :admin}

  @sort_dirs ~w(asc desc)

  def index(conn, params) do
    cat_sort = parse_sort(params["cat_sort"])
    sub_sort = parse_sort(params["sub_sort"])

    selected_cat = lookup_category(params["category"])
    selected_sub = lookup_subcategory(selected_cat, params["subcategory"])

    categories = list_categories(cat_sort)
    sub_counts = subcategory_counts()
    mapping_counts_by_cat = mapping_counts_by_category()

    subcategories =
      if selected_cat,
        do: list_subcategories(selected_cat.id, sub_sort),
        else: []

    mapping_counts_by_sub =
      if selected_cat,
        do: mapping_counts_by_subcategory(selected_cat.id),
        else: %{}

    mappings = if selected_sub, do: list_mappings(selected_sub.id), else: []

    conn
    |> assign(:top_nav, :app_categories)
    |> assign(:page_title, "App Categories")
    |> assign(:categories, categories)
    |> assign(:sub_counts, sub_counts)
    |> assign(:mapping_counts_by_cat, mapping_counts_by_cat)
    |> assign(:selected_cat, selected_cat)
    |> assign(:subcategories, subcategories)
    |> assign(:mapping_counts_by_sub, mapping_counts_by_sub)
    |> assign(:selected_sub, selected_sub)
    |> assign(:mappings, mappings)
    |> assign(:cat_sort, cat_sort)
    |> assign(:sub_sort, sub_sort)
    |> render(:index)
  end

  defp lookup_category(nil), do: nil
  defp lookup_category(""), do: nil
  defp lookup_category(slug), do: Repo.get_by(AppCategory, slug: slug)

  defp lookup_subcategory(nil, _), do: nil
  defp lookup_subcategory(_cat, nil), do: nil
  defp lookup_subcategory(_cat, ""), do: nil

  defp lookup_subcategory(%AppCategory{id: id}, slug),
    do: Repo.get_by(AppSubcategory, app_category_id: id, slug: slug)

  defp parse_sort(nil), do: "position"
  defp parse_sort("name"), do: "name"
  defp parse_sort("-name"), do: "-name"
  defp parse_sort(_), do: "position"

  defp list_categories(sort) do
    AppCategory
    |> apply_sort(sort)
    |> Repo.all()
  end

  defp list_subcategories(cat_id, sort) do
    AppSubcategory
    |> where([s], s.app_category_id == ^cat_id)
    |> apply_sort(sort)
    |> Repo.all()
  end

  defp apply_sort(query, "name"), do: order_by(query, [c], asc: c.name)
  defp apply_sort(query, "-name"), do: order_by(query, [c], desc: c.name)
  defp apply_sort(query, _position), do: order_by(query, [c], asc: c.position, asc: c.name)

  defp subcategory_counts do
    Repo.all(
      from s in AppSubcategory,
        group_by: s.app_category_id,
        select: {s.app_category_id, count(s.id)}
    )
    |> Map.new()
  end

  defp mapping_counts_by_category do
    Repo.all(
      from m in CategoryMapping,
        join: s in AppSubcategory,
        on: s.id == m.app_subcategory_id,
        group_by: s.app_category_id,
        select: {s.app_category_id, count(m.id)}
    )
    |> Map.new()
  end

  defp mapping_counts_by_subcategory(cat_id) do
    Repo.all(
      from m in CategoryMapping,
        join: s in AppSubcategory,
        on: s.id == m.app_subcategory_id,
        where: s.app_category_id == ^cat_id,
        group_by: m.app_subcategory_id,
        select: {m.app_subcategory_id, count(m.id)}
    )
    |> Map.new()
  end

  defp list_mappings(sub_id) do
    Repo.all(
      from m in CategoryMapping,
        join: c in ChainCategory,
        on: c.id == m.chain_category_id,
        where: m.app_subcategory_id == ^sub_id,
        order_by: [asc: c.chain, asc: c.name],
        select: %{id: m.id, chain: c.chain, name: c.name, slug: c.slug}
    )
  end

  @doc false
  def sort_dirs, do: @sort_dirs

  @doc """
  Persists the order received from the drag-sort frontend. `params["ids"]`
  is a list of stringified ids in the new visual order; the row at index
  N gets `position = N`. Updates run inside one transaction so a partial
  failure leaves the table consistent.
  """
  def reorder_categories(conn, %{"ids" => ids}) do
    persist_positions(AppCategory, ids)
    send_resp(conn, :no_content, "")
  end

  def reorder_subcategories(conn, %{"ids" => ids}) do
    persist_positions(AppSubcategory, ids)
    send_resp(conn, :no_content, "")
  end

  defp persist_positions(schema, ids) when is_list(ids) do
    Repo.transaction(fn ->
      ids
      |> Enum.with_index()
      |> Enum.each(fn {raw_id, index} ->
        case parse_id(raw_id) do
          nil ->
            :skip

          id ->
            from(r in schema, where: r.id == ^id)
            |> Repo.update_all(set: [position: index])
        end
      end)
    end)
  end

  defp parse_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_id(n) when is_integer(n), do: n
  defp parse_id(_), do: nil
end
