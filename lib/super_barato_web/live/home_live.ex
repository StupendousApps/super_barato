defmodule SuperBaratoWeb.HomeLive do
  use SuperBaratoWeb, :live_view

  import Ecto.Query

  alias SuperBarato.{Catalog, Linker}
  alias SuperBarato.Catalog.Product
  alias SuperBarato.Repo

  @results_per_page 50

  @chain_names %{
    "jumbo" => "Jumbo",
    "santa_isabel" => "Santa Isabel",
    "unimarc" => "Unimarc",
    "lider" => "Líder",
    "tottus" => "Tottus",
    "acuenta" => "Acuenta"
  }

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
     |> assign(:page_title, "SuperBarato.cl"), layout: false}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:query, params["q"] || "")
     |> assign(:selected_category, params["cat"])
     |> assign(:selected_subcategory, params["sub"])
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
        prices = product_prices(Map.get(listings, p.id, []))

        %{
          id: p.id,
          name: p.canonical_name,
          brand: p.brand,
          image_url: p.image_url,
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
    <div class="layout" id="layout" phx-hook="Rails">
      <%!-- Cart rail collapse state is a pure frontend concern —
           the `Rails` JS hook flips a `data-rail-right` attribute
           on <html> and persists to localStorage. --%>
      <div class="center">
        <div class="search-block">
          <div class="container">
            <div class="search-row">
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
                <span class="mag" aria-hidden="true"></span>
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
            </div>
          </div>
        </div>

        <main class="main">
         <div class="container">
          <%= cond do %>
            <% @products == [] and @query == "" and is_nil(@selected_category) and is_nil(@selected_subcategory) -> %>
              <div class="results-empty">
                <div class="arrow">↑</div>
                <div class="msg">Busca un producto o elige una categoría</div>
                <div class="stats">Jumbo · Líder · Santa Isabel · Unimarc · Tottus · Acuenta</div>
              </div>
            <% @products == [] -> %>
              <div class="results-empty">
                <div class="msg">Sin resultados</div>
                <div class="stats">Prueba otra búsqueda o categoría</div>
              </div>
            <% true -> %>
              <div class="grid">
                <button
                  :for={{p, i} <- Enum.with_index(@products)}
                  type="button"
                  class="card"
                  data-product-id={p.id}
                  data-product-index={i + 1}
                  phx-click="add"
                  phx-value-id={p.id}
                  aria-label={"Agregar #{p.name}"}
                >
                  <div class="img">
                    <img :if={p.image_url} src={p.image_url} alt="" loading="lazy" />
                  </div>
                  <div class="body">
                    <div class="head">
                      <div class="name">{p.name}</div>
                      <div :if={p.brand} class="brand">{p.brand}</div>
                    </div>
                    <%= if p.prices == [] do %>
                      <div class="prices prices--empty">Sin precio</div>
                    <% else %>
                      <ul class="prices">
                        <li :for={row <- p.prices} class={["price-row", row.promo? && "price-row--promo", row.lowest? && "price-row--lowest"]}>
                          <img class="ch-icon" src={chain_icon_url(row.chain)} alt={row.name} title={row.name} />
                          <span class="amt">{format_clp(row.price)}</span>
                        </li>
                      </ul>
                    <% end %>
                  </div>
                </button>
              </div>
              <div
                :if={length(@products) < @total_count}
                id="infinite-scroll-sentinel"
                phx-hook="InfiniteScroll"
              ></div>
          <% end %>
         </div>
        </main>
      </div>

      <aside class="rail rail--right">
        <.rail_right cart_items={@cart_items} />
      </aside>

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

  ## ── Rail components ──────────────────────────────────────────

  attr :cart_items, :list, required: true

  defp rail_right(assigns) do
    ~H"""
    <div class="cart-hd">
      <a class="logo" href="/" aria-label="SuperBarato.cl">
        <span class="super">SUPER</span><span class="barato">barato</span><span class="tld">.cl</span>
      </a>
      <button
        type="button"
        class="rail-toggle"
        data-rail-toggle="right"
        aria-label="Mostrar/ocultar carrito"
      >
        <.icon_sidebar_right />
        <span :if={@cart_items != []} class="rail-toggle__badge">{length(@cart_items)}</span>
      </button>
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

  defp icon_sidebar_right(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" class="icon" aria-hidden="true">
      <path d="M5.579 19.807h13.054c2.137 0 3.367-1.289 3.367-3.579V7.78c0-2.29-1.23-3.587-3.367-3.587H5.579C3.298 4.193 2 5.49 2 7.78v8.448c0 2.29 1.298 3.579 3.579 3.579Zm.009-1.365c-1.408 0-2.222-.806-2.222-2.214V7.78c0-1.408.814-2.222 2.222-2.222h8.643v12.884H5.588Zm12.824-12.884c1.408 0 2.222.814 2.222 2.222v8.448c0 1.408-.814 2.214-2.222 2.214h-2.85V5.558h2.85Zm-1.221 3.155h1.815a.483.483 0 0 0 .483-.475.475.475 0 0 0-.483-.475H17.19a.475.475 0 0 0-.484.475c0 .254.22.475.484.475Zm0 2.197h1.815a.483.483 0 0 0 .483-.483.475.475 0 0 0-.483-.467H17.19a.475.475 0 0 0-.484.467c0 .254.22.483.484.483Zm0 2.188h1.815a.475.475 0 0 0 .483-.466.475.475 0 0 0-.483-.475H17.19a.475.475 0 0 0-.484.475c0 .254.22.466.484.466Z"/>
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


  # Per-chain effective price for a product, ordered by @chain_order.
  # Each entry: %{chain, name, price, promo?}. Listings without a
  # current_regular_price are dropped. If a chain has multiple
  # listings linked, we pick the cheapest effective price.
  defp product_prices(listings) do
    rows =
      listings
      |> Enum.reject(&is_nil(&1.current_regular_price))
      |> Enum.map(fn l ->
        reg = l.current_regular_price
        promo = l.current_promo_price
        promo? = is_integer(promo) and is_integer(reg) and promo < reg
        eff = if promo?, do: promo, else: reg
        %{chain: l.chain, price: eff, promo?: promo?}
      end)
      |> Enum.group_by(& &1.chain)
      |> Enum.map(fn {_chain, rows} -> Enum.min_by(rows, & &1.price) end)
      |> Enum.sort_by(& &1.price)
      |> Enum.map(fn row ->
        Map.put(row, :name, Map.get(@chain_names, row.chain, row.chain))
      end)

    case rows do
      [_only] ->
        Enum.map(rows, &Map.put(&1, :lowest?, false))

      [] ->
        []

      _ ->
        min_price = rows |> Enum.map(& &1.price) |> Enum.min()
        Enum.map(rows, &Map.put(&1, :lowest?, &1.price == min_price))
    end
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
