defmodule SuperBaratoWeb.HomeLive do
  use SuperBaratoWeb, :live_view

  alias SuperBarato.{Catalog, HomeCache, HomeData, Linker, Thumbnails}

  @results_per_page 50

  # Suggestion chip counts. Fewer chips as the scope narrows — each
  # additional chip is more redundant once the user has already typed
  # a query and/or picked a category.
  @suggestions_home 24
  @suggestions_category 16
  @suggestions_search 12
  @suggestions_search_category 8

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     # Selected category/subcategory filters (nil = no filter).
     |> assign(:selected_category, nil)
     |> assign(:selected_subcategory, nil)
     |> assign(:categories, Catalog.app_categories_with_subcategories())
     |> assign(:products, [])
     |> assign(:total_count, 0)
     |> assign(:page, 1)
     |> assign(:suggestions, [])
     |> assign(:category_previews, [])
     |> assign(:page_title, "SuperBarato.cl"), layout: false}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:query, params["q"] || "")
     |> assign(:selected_category, params["cat"])
     |> assign(:selected_subcategory, params["sub"])
     |> assign(:suggestions, suggestions_for(params))
     |> assign(:category_previews, category_previews_for(params))
     |> run_search()
     |> push_event("seen_counter:reset", %{})
     |> push_event("search:focus", %{})}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    trimmed = String.trim(q)
    # No-op if the trimmed query didn't actually change — the
    # phx-change event fires on every keystroke and trailing-space
    # / IME composition flakes can otherwise trigger a full
    # handle_params + re-render cycle for nothing.
    if trimmed == String.trim(socket.assigns.query) do
      {:noreply, socket}
    else
      qs =
        [
          {"q", trimmed},
          {"cat", socket.assigns.selected_category},
          {"sub", socket.assigns.selected_subcategory}
        ]
        |> Enum.reject(fn {_, v} -> v in [nil, ""] end)

      {:noreply, push_patch(socket, to: ~p"/?#{qs}")}
    end
  end

  def handle_event("product_detail", %{"id" => id}, socket) do
    product_id =
      cond do
        is_integer(id) -> id
        is_binary(id) -> String.to_integer(id)
        true -> 0
      end

    listings =
      Linker.listings_for_product(product_id)
      |> Enum.map(fn l ->
        %{
          chain: l.chain,
          name: l.name,
          brand: l.brand,
          image_url: l.image_url,
          pdp_url: l.pdp_url,
          regular_price: l.current_regular_price,
          promo_price: l.current_promo_price,
          raw: l.raw || %{}
        }
      end)

    {:reply, %{listings: listings}, socket}
  end

  def handle_event("load_more", _, socket) do
    %{products: existing, total_count: total, page: page} = socket.assigns

    cond do
      length(existing) >= total -> {:noreply, socket}
      total == 0 -> {:noreply, socket}
      true -> {:noreply, fetch_page(socket, page + 1)}
    end
  end

  ## ── Search ──────────────────────────────────────────────────

  # Hits the catalog only when there's something to search for OR a
  # category filter is active. The empty home view stays cheap (no
  # query) so first paint isn't gated on a catalog read.
  # Index view (no q, no filter) reads category previews and the
  # popular-term chips from the cache that `SuperBarato.HomeCache`
  # warms in ETS every 2 minutes. Search/filter views compute scoped
  # popular terms on demand (and skip preview bands).
  defp suggestions_for(params) do
    q = (params["q"] || "") |> String.trim()
    cat = params["cat"]
    sub = params["sub"]
    has_cat = cat not in [nil, ""] or sub not in [nil, ""]

    cond do
      q == "" and not has_cat ->
        # Cached, global popular terms — bounded by HomeCache (48).
        HomeCache.popular_terms() |> Enum.take(@suggestions_home)

      q == "" and has_cat ->
        Catalog.popular_terms(cat: cat, sub: sub, n: @suggestions_category)

      q != "" and not has_cat ->
        Catalog.popular_terms(q: q, n: @suggestions_search)

      true ->
        Catalog.popular_terms(q: q, cat: cat, sub: sub, n: @suggestions_search_category)
    end
  end

  defp category_previews_for(%{"cat" => cat}) when cat not in [nil, ""], do: []
  defp category_previews_for(%{"sub" => sub}) when sub not in [nil, ""], do: []
  defp category_previews_for(%{"q" => q}) when q not in [nil, ""], do: []
  defp category_previews_for(_params), do: HomeCache.category_previews()

  defp run_search(socket) do
    q = String.trim(socket.assigns.query)
    cat = socket.assigns.selected_category
    sub = socket.assigns.selected_subcategory

    if q == "" and is_nil(cat) and is_nil(sub) do
      assign(socket, products: [], total_count: 0, page: 1)
    else
      fetch_page(assign(socket, products: [], page: 1), 1)
    end
  end

  # Fetches `page` worth of products and either replaces the
  # `products` list (page 1) or appends to it (subsequent pages).
  # Pagination keys off the same sort that drives the initial load,
  # so OFFSET-based paging stays stable across requests.
  defp fetch_page(socket, page) do
    q = String.trim(socket.assigns.query)
    cat = socket.assigns.selected_category
    sub = socket.assigns.selected_subcategory

    result =
      Catalog.list_products_page(
        q: q,
        app_category: cat,
        app_subcategory: sub,
        sort: "-chain_count",
        page: page,
        per_page: @results_per_page
      )

    pids = Enum.map(result.items, & &1.id)
    listings = Linker.listings_by_product_ids(pids)

    new_products =
      Enum.map(result.items, fn p ->
        prices = HomeData.product_prices(Map.get(listings, p.id, []))

        %{
          id: p.id,
          name: p.canonical_name,
          brand: p.brand,
          image_url: Thumbnails.thumbnail_url(p),
          prices: prices
        }
      end)

    products =
      if page == 1, do: new_products, else: socket.assigns.products ++ new_products

    assign(socket,
      products: products,
      total_count: result.total_entries,
      page: page
    )
  end

  # Rail collapse is purely a frontend concern — see the `Rails` JS
  # hook in assets/js/app.js. The toggle button(s) inside each rail
  # flip a `data-collapsed="true"` attribute on the rail element and
  # write to localStorage. The server is never told.

  ## ── Render ───────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :results_per_page, @results_per_page)

    ~H"""
    <div class="scroll" id="layout" phx-hook="Rails">
      <header class="topbar">
        <div class="container topbar__inner">
          <div class="topbar__main">
          <div class="picker cat-picker" id="cat-picker" phx-hook="Picker">
            <div class={["search-cat-button", category_active?(@selected_category, @selected_subcategory) && "search-cat-button--filtered"]}>
              <.link
                :if={category_active?(@selected_category, @selected_subcategory)}
                patch={~p"/?#{cat_params(@query, nil, nil)}"}
                class="search-cat-button__x"
                aria-label="Quitar categoría"
              >×</.link>
              <button
                type="button"
                class="search-cat-button__toggle"
                data-picker-toggle
                aria-haspopup="true"
              >
                <span class="search-cat-button__label">{cat_picker_label(@categories, @selected_category, @selected_subcategory)}</span>
                <span class="search-cat-button__chev" aria-hidden="true"></span>
              </button>
            </div>
            <div class="picker__panel cat-panel" role="menu">
              <.link
                patch={~p"/?#{cat_params(@query, nil, nil)}"}
                class={["cat-panel__all", is_nil(@selected_category) and is_nil(@selected_subcategory) && "is-active"]}
              >Todas las categorías</.link>
              <div class="cat-panel__grid">
                <div :for={c <- @categories} class="cat-tile">
                  <.link
                    patch={~p"/?#{cat_params(@query, c.slug, nil)}"}
                    class={["cat-tile__head", @selected_category == c.slug and is_nil(@selected_subcategory) && "is-active"]}
                  >{c.name}</.link>
                  <ul :if={c.subcategories != []} class="cat-tile__subs">
                    <li :for={s <- c.subcategories}>
                      <.link
                        patch={~p"/?#{cat_params(@query, nil, s.slug)}"}
                        class={["cat-tile__sub", @selected_subcategory == s.slug && "is-active"]}
                      >{s.name}</.link>
                    </li>
                  </ul>
                </div>
              </div>
            </div>
          </div>

          <form class="search" phx-change="search" phx-submit="search">
            <%= if @query != "" do %>
              <.link
                patch={~p"/?#{cat_params("", @selected_category, @selected_subcategory)}"}
                class="mag mag--clearable"
                aria-label="Limpiar búsqueda"
              ></.link>
            <% else %>
              <span class="mag" aria-hidden="true"></span>
            <% end %>
            <input
              id="search-q"
              name="q"
              value={@query}
              placeholder="Buscar cualquier producto del super…"
              autocomplete="off"
              phx-debounce="350"
              autofocus
            />
            <span class="kbd">⌘K</span>
          </form>
          </div>

          <div class="topbar__aside">
          <a class="logo" href="/" aria-label="SuperBarato.cl">
            <span class="super">SUPER</span><span class="barato">barato</span><span class="tld">.cl</span>
          </a>

          <button
            type="button"
            class="cart-toggle rail-toggle"
            data-rail-toggle="right"
            aria-label="Mostrar/ocultar carrito"
          >
            <span class="cart-toggle__cart"><.icon_cart /></span>
            <span class="cart-toggle__close"><.icon_close /></span>
            <span class="rail-toggle__badge" data-cart-badge hidden></span>
          </button>
          </div>
        </div>
      </header>

      <div class="container layout-body">
        <main class="main">
          <div :if={@suggestions != []} class="suggestions">
            <.link
              :for={{term, _count} <- @suggestions}
              patch={~p"/?#{cat_params(term, @selected_category, @selected_subcategory)}"}
              class="suggestion-chip"
            >{term}</.link>
          </div>

          <%= cond do %>
            <% @products == [] and @query == "" and is_nil(@selected_category) and is_nil(@selected_subcategory) -> %>
              <section :for={band <- @category_previews} class="cat-band">
                <div class="cat-band__hd">
                  <h2>
                    <.link patch={~p"/?#{cat_params("", band.slug, nil)}"}>{band.name}</.link>
                  </h2>
                  <.link patch={~p"/?#{cat_params("", band.slug, nil)}"} class="cat-band__more">
                    Ver todo en {band.name}
                  </.link>
                </div>
                <div class="grid">
                  <.product_card :for={p <- band.products} p={p} />
                </div>
              </section>
            <% @products == [] -> %>
              <div class="results-empty">
                <div class="msg">Sin resultados</div>
                <div class="stats">Prueba otra búsqueda o categoría</div>
              </div>
            <% true -> %>
              <div class="grid">
                <.product_card
                  :for={{p, i} <- Enum.with_index(@products)}
                  p={p}
                  index={i + 1}
                />
              </div>
              <div
                :if={length(@products) < @total_count}
                id="infinite-scroll-sentinel"
                phx-hook="InfiniteScroll"
              ></div>
          <% end %>

          <footer class="site-footer">
            SuperBarato.cl — Super. Barato. ¿Se entiende?
          </footer>
        </main>

        <aside class="cart-pane" id="cart" phx-hook="Cart" phx-update="ignore">
          <div class="cart-body" data-cart-body>
            <div class="cart-empty">
              <div class="msg">Aún no hay productos</div>
              <div class="hint">Arrastra productos aquí</div>
            </div>
          </div>
          <div class="cart-footer" data-cart-footer hidden></div>
        </aside>
      </div>

      <%!-- Bottom-left "X / Y Productos" counter. The total comes
           from the server; the visible count is owned by the
           SeenCounter hook, which observes each .card with an
           IntersectionObserver and counts unique product ids that
           have entered the viewport. --%>
      <div
        :if={@total_count > 0}
        id="seen-counter"
        class="seen-counter"
        phx-hook="SeenCounter"
        data-total={@total_count}
      >
        <span data-seen>0</span> / {@total_count} Productos
      </div>
    </div>
    """
  end

  ## ── Card component ──────────────────────────────────────────

  attr :p, :map, required: true
  attr :index, :integer, default: nil

  defp product_card(assigns) do
    ~H"""
    <div
      class="card"
      data-product-id={@p.id}
      data-product-index={@index}
      data-product={Jason.encode!(%{id: @p.id, name: @p.name, brand: @p.brand, image_url: @p.image_url, prices: Enum.map(@p.prices, &Map.take(&1, [:chain, :price, :promo?]))})}
    >
      <div class="img">
        <img :if={@p.image_url} src={@p.image_url} alt="" loading="lazy" />
      </div>
      <div class="body">
        <div class="head">
          <div class="name">{@p.name}</div>
          <div :if={@p.brand} class="brand">{@p.brand}</div>
        </div>
        <%= if @p.prices == [] do %>
          <div class="prices prices--empty">Sin precio</div>
        <% else %>
          <ul class="prices">
            <li
              :for={row <- @p.prices}
              class={["price-row", row.promo? && "price-row--promo", row.lowest? && "price-row--lowest"]}
            >
              <a
                :if={row.url}
                href={row.url}
                target="_blank"
                rel="noopener noreferrer"
                class="price-link"
                onclick="event.stopPropagation()"
                title={"Ver en " <> row.name}
              >
                <img class="ch-icon" src={chain_icon_url(row.chain)} alt={row.name} />
                <span class="amt">{format_clp(row.price)}</span>
              </a>
              <span :if={!row.url} class="price-link price-link--nolink">
                <img class="ch-icon" src={chain_icon_url(row.chain)} alt={row.name} title={row.name} />
                <span class="amt">{format_clp(row.price)}</span>
              </span>
            </li>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end

  ## ── Inline icons (24×24, currentColor) ───────────────────────

  defp icon_close(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"
         stroke-linecap="round" stroke-linejoin="round" class="icon" aria-hidden="true">
      <path d="M6 6l12 12M18 6L6 18"/>
    </svg>
    """
  end

  defp icon_cart(assigns) do
    ~H"""
    <svg viewBox="0 0 130 110" class="icon" aria-hidden="true">
      <g transform="skewX(-10) translate(20 0)">
        <path d="M 4 18 L 22 18 L 30 30" fill="none" stroke="#0A0A0A" stroke-width="7" stroke-linecap="round" stroke-linejoin="round" />
        <path d="M 28 30 L 96 30 L 86 70 L 38 70 Z" fill="#0A0A0A" />
        <rect x="38" y="40" width="50" height="4" fill="#FFD43B" rx="2" />
        <rect x="42" y="50" width="42" height="4" fill="#FFD43B" opacity="0.7" rx="2" />
        <rect x="46" y="60" width="34" height="4" fill="#FFD43B" opacity="0.4" rx="2" />
      </g>
      <circle cx="56" cy="96" r="8" fill="#0A0A0A" />
      <circle cx="90" cy="96" r="8" fill="#0A0A0A" />
      <circle cx="56" cy="96" r="2.5" fill="#FFD43B" />
      <circle cx="90" cy="96" r="2.5" fill="#FFD43B" />
    </svg>
    """
  end

  ## ── Helpers ─────────────────────────────────────────────────

  defp category_active?(nil, nil), do: false
  defp category_active?(_, _), do: true

  # Trigger label for the bento category picker — reflects whatever
  # the user has selected in URL state.
  defp cat_picker_label(_cats, nil, nil), do: "Todas las categorías"

  defp cat_picker_label(cats, _, sub_slug) when is_binary(sub_slug) do
    Enum.find_value(cats, "todas", fn c ->
      Enum.find_value(c.subcategories, fn s -> s.slug == sub_slug && s.name end)
    end)
  end

  defp cat_picker_label(cats, cat_slug, _) when is_binary(cat_slug) do
    case Enum.find(cats, &(&1.slug == cat_slug)) do
      nil -> "todas"
      cat -> "Todo en #{cat.name}"
    end
  end

  # Build a query-string param list with q plus at most one of
  # cat/sub. Used by the bento tiles and the "Todas las categorías"
  # reset link.
  defp cat_params(q, cat, sub) do
    [{"q", String.trim(q)}, {"cat", cat}, {"sub", sub}]
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
  end


  # Static favicon path for each chain. Files live in
  # priv/static/images/chains/ — pre-baked, not crawled.
  defp chain_icon_url("jumbo"), do: "/images/chains/jumbo.png"
  defp chain_icon_url("santa_isabel"), do: "/images/chains/santa_isabel.png"
  defp chain_icon_url("unimarc"), do: "/images/chains/unimarc.ico"
  defp chain_icon_url("lider"), do: "/images/chains/lider.ico"
  defp chain_icon_url("tottus"), do: "/images/chains/tottus.png"
  defp chain_icon_url("acuenta"), do: "/images/chains/acuenta.ico"
  defp chain_icon_url(_), do: nil


  defp format_clp(nil), do: "—"

  defp format_clp(n) when is_integer(n) do
    "$" <> format_int_cl(n)
  end

  defp format_int_cl(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(".")
    |> String.reverse()
  end
end
