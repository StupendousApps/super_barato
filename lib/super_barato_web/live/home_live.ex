defmodule SuperBaratoWeb.HomeLive do
  use SuperBaratoWeb, :live_view

  import Ecto.Query

  alias SuperBarato.{Catalog, HomeCache, HomeData, Linker, Thumbnails}
  alias SuperBarato.Catalog.Product
  alias SuperBarato.Repo

  @results_per_page 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:cart, %{})
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
     |> push_event("seen_counter:reset", %{})}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    qs =
      [
        {"q", String.trim(q)},
        {"cat", socket.assigns.selected_category},
        {"sub", socket.assigns.selected_subcategory}
      ]
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)

    {:noreply, push_patch(socket, to: ~p"/?#{qs}")}
  end

  def handle_event("add", %{"id" => id}, socket) do
    id = String.to_integer(id)
    cart = Map.update(socket.assigns.cart, id, 1, &(&1 + 1))
    {:noreply, assign(socket, :cart, cart)}
  end

  def handle_event("inc", %{"id" => id}, socket) do
    id = String.to_integer(id)
    cart = Map.update(socket.assigns.cart, id, 1, &(&1 + 1))
    {:noreply, assign(socket, :cart, cart)}
  end

  def handle_event("dec", %{"id" => id}, socket) do
    id = String.to_integer(id)

    cart =
      case Map.get(socket.assigns.cart, id, 0) do
        qty when qty <= 1 -> Map.delete(socket.assigns.cart, id)
        qty -> Map.put(socket.assigns.cart, id, qty - 1)
      end

    {:noreply, assign(socket, :cart, cart)}
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
  # warms in ETS every 2 minutes. Filtered / search views compute
  # per-category popular terms on demand and skip preview bands.
  defp suggestions_for(%{"cat" => cat}) when cat not in [nil, ""],
    do: Catalog.popular_terms(cat, nil, 24)

  defp suggestions_for(%{"sub" => sub}) when sub not in [nil, ""],
    do: Catalog.popular_terms(nil, sub, 24)

  defp suggestions_for(_params), do: HomeCache.popular_terms()

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
    assigns =
      assigns
      |> assign(:cart_items, cart_items(assigns.cart))
      |> assign(:results_per_page, @results_per_page)

    ~H"""
    <div class="scroll" id="layout" phx-hook="Rails">
      <header class="topbar">
        <div class="container topbar__inner">
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
              name="q"
              value={@query}
              placeholder="Buscar cualquier producto del super…"
              autocomplete="off"
              phx-debounce="150"
              autofocus
            />
            <span class="kbd">⌘K</span>
          </form>

          <button
            type="button"
            class="cart-toggle rail-toggle"
            data-rail-toggle="right"
            aria-label="Mostrar/ocultar carrito"
          >
            <span class="cart-toggle__cart"><.icon_cart /></span>
            <span class="cart-toggle__close"><.icon_close /></span>
            <span :if={@cart_items != []} class="rail-toggle__badge">{length(@cart_items)}</span>
          </button>
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

        <aside class="cart-pane">
          <.rail_right cart_items={@cart_items} />
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
      phx-click="add"
      phx-value-id={@p.id}
      role="button"
      tabindex="0"
      aria-label={"Agregar #{@p.name}"}
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

  ## ── Rail components ──────────────────────────────────────────

  attr :cart_items, :list, required: true

  defp rail_right(assigns) do
    ~H"""
    <div class="cart-hd">
      <a class="logo" href="/" aria-label="SuperBarato.cl">
        <span class="super">SUPER</span><span class="barato">barato</span><span class="tld">.cl</span>
      </a>
    </div>

      <%= if @cart_items == [] do %>
        <div class="cart-empty">
          <div class="box">+</div>
          <div class="msg">Aún no hay productos</div>
          <div class="hint">Busca y agrega lo que necesites</div>
        </div>
      <% else %>
        <div class="cart-body">
          <div :for={it <- @cart_items} class="ci">
            <div class="thumb"></div>
            <div class="meta">
              <div class="n">{it.product.name}</div>
              <div class="u">{it.product.unit}</div>
            </div>
            <div class="side">
              <div class="price">
                {format_clp(it.mid)}<span class="spr">± {format_clp(it.spread)}</span>
              </div>
              <div class="qty">
                <button type="button" phx-click="dec" phx-value-id={it.product.id} aria-label="Menos">−</button>
                <span>{it.qty}</span>
                <button type="button" phx-click="inc" phx-value-id={it.product.id} aria-label="Más">+</button>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <div class="cart-ft">
        <%= if @cart_items == [] do %>
          <div class="ft-summary muted">
            <span>0 Productos</span>
            <span class="dots"></span>
            <span>—</span>
          </div>
          <button class="cta" disabled>Ver Compra Óptima</button>
        <% else %>
          <% {mid, spread, count} = cart_totals(@cart_items) %>
          <div class="ft-summary">
            <span>{count} Productos</span>
            <span class="dots"></span>
            <span class="total">
              {format_clp(mid)}<span class="spr">± {format_clp(spread)}</span>
            </span>
          </div>
          <button class="cta">Ver Compra Óptima</button>
        <% end %>
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
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"
         stroke-linecap="round" stroke-linejoin="round" class="icon" aria-hidden="true">
      <path d="M3 4h2.2l2.4 11.2a2 2 0 0 0 2 1.6h7.8a2 2 0 0 0 2-1.5L21 8H6.5"/>
      <circle cx="9.5" cy="20" r="1.4" />
      <circle cx="17.5" cy="20" r="1.4" />
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


  # `cart` is a `%{product_id => qty}` map. We resolve product
  # metadata + current price range on every render so prices stay
  # fresh without us having to rebroadcast updates. Single round-trip
  # via two batched lookups.
  defp cart_items(cart) when map_size(cart) == 0, do: []

  defp cart_items(cart) do
    pids = Map.keys(cart)
    products = Repo.all(from p in Product, where: p.id in ^pids) |> Map.new(&{&1.id, &1})
    ranges = Linker.price_range_by_product_ids(pids)

    for {pid, qty} <- cart, product = Map.get(products, pid) do
      {lo, hi} = Map.get(ranges, pid, {0, 0})
      mid = round((lo + hi) / 2 * qty)
      spread = round((hi - lo) / 2 * qty)

      %{
        product: %{id: product.id, name: product.canonical_name, image_url: product.image_url},
        qty: qty,
        lo: lo,
        hi: hi,
        mid: mid,
        spread: spread
      }
    end
  end

  defp cart_totals(items) do
    total_lo = Enum.reduce(items, 0, &(&1.lo * &1.qty + &2))
    total_hi = Enum.reduce(items, 0, &(&1.hi * &1.qty + &2))
    count = Enum.reduce(items, 0, &(&1.qty + &2))
    mid = round((total_lo + total_hi) / 2)
    spread = round((total_hi - total_lo) / 2)
    {mid, spread, count}
  end

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
