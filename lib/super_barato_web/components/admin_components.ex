defmodule SuperBaratoWeb.AdminComponents do
  @moduledoc """
  Function components shared by admin pages — page header, sortable
  table, pagination. Ported verbatim (with minor simplifications) from
  dotty_web so the class names line up with `priv/static/assets/css/admin/`.

  Intentionally no icon library dep: sort arrows render as Unicode
  characters, which is enough for a desktop admin.
  """
  use Phoenix.Component

  ## page_header

  attr :title, :string, required: true
  slot :back, doc: "back link; slot takes the label"
  slot :actions, doc: "buttons on the top-right"
  slot :filters, doc: "form row under the title"
  slot :tabs, doc: "tab strip (<.sub_nav>) under the title"

  def page_header(assigns) do
    ~H"""
    <header class="page-header">
      <a :for={b <- @back} href={Map.fetch!(b, :href)} class="page-header-back">
        ← {render_slot(b)}
      </a>
      <div class="page-header-row">
        <h1 class="page-header-title">{@title}</h1>
        <div :if={@actions != []} class="page-header-actions">
          {render_slot(@actions)}
        </div>
      </div>
      <div :if={@filters != []} class="page-header-filters">
        {render_slot(@filters)}
      </div>
      <div :if={@tabs != []}>
        {render_slot(@tabs)}
      </div>
    </header>
    """
  end

  ## sub_nav — tab strip under a page header

  attr :active, :any, required: true, doc: "value matching :value on the active item"

  slot :item, required: true do
    attr :href, :string, required: true
    attr :value, :any, required: true
  end

  def sub_nav(assigns) do
    ~H"""
    <nav class="sub-navigation">
      <ul>
        <li :for={item <- @item}>
          <a href={item.href} class={item.value == @active && "active"}>
            {render_slot(item)}
          </a>
        </li>
      </ul>
    </nav>
    """
  end

  ## table

  attr :rows, :list, required: true
  attr :row_id, :any, default: nil
  attr :empty, :string, default: "Nothing yet."
  attr :sort, :string, default: nil, doc: "current sort, e.g. \"name\" or \"-name\""
  attr :sort_path, :string, default: nil
  attr :params, :map, default: %{}, doc: "other query params to preserve when sorting"
  attr :muted, :any, default: nil, doc: "fn(row) -> boolean — mute row when true"

  slot :col, required: true do
    attr :label, :string, required: true
    attr :sort_by, :string
    attr :nowrap, :boolean
  end

  slot :action

  def table(assigns) do
    ~H"""
    <table class="data-table">
      <thead>
        <tr>
          <th :for={col <- @col} class={col[:nowrap] && "data-table-col-nowrap"}>
            <%= if col[:sort_by] && @sort_path do %>
              <a href={sort_href(@sort_path, @params, col[:sort_by], @sort)} class="sort-header">
                <span>{col.label}</span>
                <.sort_arrow field={col[:sort_by]} current={@sort} />
              </a>
            <% else %>
              {col.label}
            <% end %>
          </th>
          <th :if={@action != []} class="data-table-col-actions"></th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={row <- @rows}
          data-id={(@row_id && @row_id.(row)) || Map.get(row, :id)}
          class={@muted && @muted.(row) && "data-table-row-muted"}
        >
          <td :for={col <- @col} class={col[:nowrap] && "data-table-col-nowrap"}>
            {render_slot(col, row)}
          </td>
          <td :if={@action != []} class="data-table-col-actions">{render_slot(@action, row)}</td>
        </tr>
        <tr :if={@rows == []}>
          <td colspan={col_count(@col, @action)} class="data-table-empty">{@empty}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp sort_arrow(assigns) do
    ~H"""
    <span :if={@current == @field} class="sort-arrow">↓</span>
    <span :if={@current == "-" <> @field} class="sort-arrow">↑</span>
    """
  end

  ## pagination

  attr :result, :map, required: true, doc: "%{page:, total_pages:}"
  attr :base_url, :string, required: true
  attr :params, :map, default: %{}
  attr :window, :integer, default: 2

  def pagination(assigns) do
    assigns =
      assign(
        assigns,
        :items,
        pagination_items(assigns.result.page, assigns.result.total_pages, assigns.window)
      )

    ~H"""
    <nav :if={@result.total_pages > 1} class="pagination">
      <a
        :if={@result.page > 1}
        href={page_href(@base_url, @params, @result.page - 1)}
        class="btn btn-subtle"
        aria-label="Previous"
      >‹</a>

      <%= for item <- @items do %>
        <%= case item do %>
          <% :ellipsis -> %>
            <span class="pagination-ellipsis">…</span>
          <% page when page == @result.page -> %>
            <span class="btn btn-primary pagination-current" aria-current="page">{page}</span>
          <% page -> %>
            <a href={page_href(@base_url, @params, page)} class="btn btn-subtle">{page}</a>
        <% end %>
      <% end %>

      <a
        :if={@result.page < @result.total_pages}
        href={page_href(@base_url, @params, @result.page + 1)}
        class="btn btn-subtle"
        aria-label="Next"
      >›</a>
    </nav>
    """
  end

  ## helpers

  defp sort_href(path, params, field, current) do
    next =
      case current do
        ^field -> "-" <> field
        _ -> field
      end

    path <> "?" <> encode_query(Map.put(params, "sort", next))
  end

  defp page_href(path, params, page) do
    path <> "?" <> encode_query(Map.put(params, "page", page))
  end

  defp encode_query(params) do
    params
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> URI.encode_query()
  end

  defp col_count(cols, action), do: length(cols) + if(action != [], do: 1, else: 0)

  defp pagination_items(current, total, window) do
    lo = max(1, current - window)
    hi = min(total, current + window)

    [1, total]
    |> Kernel.++(Enum.to_list(lo..hi//1))
    |> Enum.uniq()
    |> Enum.sort()
    |> insert_ellipsis([])
  end

  defp insert_ellipsis([a, b | rest], acc) when b - a > 1,
    do: insert_ellipsis([b | rest], [:ellipsis, a | acc])

  defp insert_ellipsis([h | t], acc), do: insert_ellipsis(t, [h | acc])
  defp insert_ellipsis([], acc), do: Enum.reverse(acc)
end
