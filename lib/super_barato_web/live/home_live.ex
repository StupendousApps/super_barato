defmodule SuperBaratoWeb.HomeLive do
  use SuperBaratoWeb, :live_view

  alias SuperBarato.Catalog

  # Wireframe placeholder data. Prices in CLP, keyed by supermarket id
  # (jumbo, lider, santa, unimarc, tottus, acuenta). Real data will come
  # from the catalog once the crawler seeds it.
  @products [
    %{id: 1, name: "Leche entera Colun 1 L", unit: "1 L",
      prices: %{"jumbo" => 1190, "lider" => 1090, "santa" => 1150, "unimarc" => 1240, "tottus" => 1120, "acuenta" => 990}},
    %{id: 2, name: "Pan de molde blanco Ideal 500 g", unit: "500 g",
      prices: %{"jumbo" => 2290, "lider" => 2190, "santa" => 2290, "unimarc" => 2390, "tottus" => 2250, "acuenta" => 2090}},
    %{id: 3, name: "Arroz Tucapel Grado 1, 1 kg", unit: "1 kg",
      prices: %{"jumbo" => 1690, "lider" => 1590, "santa" => 1690, "unimarc" => 1790, "tottus" => 1590, "acuenta" => 1490}},
    %{id: 4, name: "Aceite maravilla Chef 900 ml", unit: "900 mL",
      prices: %{"jumbo" => 2190, "lider" => 1990, "santa" => 2090, "unimarc" => 2290, "tottus" => 2090, "acuenta" => 1890}},
    %{id: 5, name: "Huevos blancos XL 1/2 docena", unit: "6 un",
      prices: %{"jumbo" => 2490, "lider" => 2290, "santa" => 2390, "unimarc" => 2590, "tottus" => 2390, "acuenta" => 2190}},
    %{id: 6, name: "Azúcar granulada IANSA 1 kg", unit: "1 kg",
      prices: %{"jumbo" => 1390, "lider" => 1290, "santa" => 1350, "unimarc" => 1490, "tottus" => 1290, "acuenta" => 1190}},
    %{id: 7, name: "Fideos spaghetti Carozzi 400 g", unit: "400 g",
      prices: %{"jumbo" => 890, "lider" => 790, "santa" => 850, "unimarc" => 990, "tottus" => 790, "acuenta" => 690}},
    %{id: 8, name: "Yogurt natural Soprole 1 L", unit: "1 L",
      prices: %{"jumbo" => 1890, "lider" => 1790, "santa" => 1890, "unimarc" => 1990, "tottus" => 1790, "acuenta" => nil}},
    %{id: 9, name: "Papel higiénico Confort 12 un", unit: "12 rollos",
      prices: %{"jumbo" => 6990, "lider" => 6490, "santa" => 6790, "unimarc" => 7290, "tottus" => 6590, "acuenta" => 5990}},
    %{id: 10, name: "Detergente Ariel 3 kg", unit: "3 kg",
      prices: %{"jumbo" => 8990, "lider" => 8490, "santa" => 8790, "unimarc" => 9290, "tottus" => 8590, "acuenta" => 7990}},
    %{id: 11, name: "Palta Hass, kilo", unit: "x kg",
      prices: %{"jumbo" => 3990, "lider" => 3790, "santa" => 3890, "unimarc" => nil, "tottus" => 3790, "acuenta" => 3490}},
    %{id: 12, name: "Tomate larga vida, kilo", unit: "x kg",
      prices: %{"jumbo" => 1490, "lider" => 1290, "santa" => 1390, "unimarc" => 1590, "tottus" => 1290, "acuenta" => 1190}}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:cart, %{})
     # Accordion: which app_category slug is open in the left rail.
     # Nil = all collapsed.
     |> assign(:open_category, nil)
     # Selected category/subcategory filters (nil = no filter).
     |> assign(:selected_category, nil)
     |> assign(:selected_subcategory, nil)
     |> assign(:categories, Catalog.app_categories_with_subcategories())
     |> assign(:page_title, "SuperBarato.cl"), layout: false}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:selected_category, params["cat"])
     |> assign(:selected_subcategory, params["sub"])
     |> maybe_open_category()}
  end

  # Keep the accordion in sync with the URL — if a subcategory is
  # selected, its parent category must be expanded so the user can see
  # the highlighted row.
  defp maybe_open_category(socket) do
    case {socket.assigns.selected_subcategory, socket.assigns.selected_category} do
      {nil, nil} ->
        socket

      {nil, cat_slug} ->
        assign(socket, :open_category, cat_slug)

      {sub_slug, _} ->
        cat = Enum.find(socket.assigns.categories, &Enum.any?(&1.subcategories, fn s -> s.slug == sub_slug end))
        assign(socket, :open_category, cat && cat.slug)
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, :query, q)}
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

  # Rail collapse is purely a frontend concern — see the `Rails` JS
  # hook in assets/js/app.js. The toggle button(s) inside each rail
  # flip a `data-collapsed="true"` attribute on the rail element and
  # write to localStorage. The server is never told.

  # Accordion toggle on the left rail. Clicking a category name opens
  # its subcategory list (or closes if already open). We don't change
  # the URL here — that's only for actual selections.
  def handle_event("toggle_category", %{"slug" => slug}, socket) do
    open = if socket.assigns.open_category == slug, do: nil, else: slug
    {:noreply, assign(socket, :open_category, open)}
  end

  ## ── Render ───────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:products, products_for(assigns.query))
      |> assign(:cart_items, cart_items(assigns.cart))

    ~H"""
    <div class="layout" id="layout" phx-hook="Rails">
      <%!-- Rails are always rendered. The collapsed/expanded state
           is a pure frontend concern — the `Rails` JS hook flips a
           `data-collapsed` attribute on the rail and persists to
           localStorage. The server never sees the toggle. --%>
      <aside class="rail rail--left">
        <.rail_left
          categories={@categories}
          open_category={@open_category}
          selected_category={@selected_category}
          selected_subcategory={@selected_subcategory}
        />
      </aside>

      <div class="center">
        <div class="search-block">
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

        <main class="main">
          <div class="results-hd">
            <h2>
              Resultados
              <em :if={@query != ""}>"{@query}"</em>
            </h2>
            <div class="count">
              <%= if @query == "" do %>
                6 supermercados · 24.302 productos
              <% else %>
                {length(@products)} resultados · 6 supermercados
              <% end %>
            </div>
          </div>

          <%= if @query == "" do %>
            <div class="results-empty">
              <div class="arrow">↑</div>
              <div class="msg">Busca un producto para ver resultados</div>
              <div class="stats">Jumbo · Líder · Santa Isabel · Unimarc · Tottus · Acuenta</div>
            </div>
          <% else %>
            <div class="grid">
              <button
                :for={p <- @products}
                type="button"
                class="card"
                phx-click="add"
                phx-value-id={p.id}
                aria-label={"Agregar #{p.name}"}
              >
                <div class="img">
                  <div class="hover-cta"><span class="plus">+</span>Agregar</div>
                </div>
                <div class="name">{p.name}</div>
                <div class="unit">{p.unit}</div>
                <div class="range">
                  <span class="lo">{format_clp(p.range.lo)}</span>
                  <span class="dash">–</span>
                  <span class="hi">{format_clp(p.range.hi)}</span>
                </div>
                <div class="stores">
                  <span class="dots">
                    <span :for={_ <- 1..p.range.count//1} class="d"></span>
                  </span>
                  {p.range.count} supermercados
                </div>
              </button>
            </div>
          <% end %>
        </main>
      </div>

      <aside class="rail rail--right">
        <.rail_right cart_items={@cart_items} />
      </aside>
    </div>
    """
  end

  ## ── Rail components ──────────────────────────────────────────

  attr :categories, :list, required: true
  attr :open_category, :string, default: nil
  attr :selected_category, :string, default: nil
  attr :selected_subcategory, :string, default: nil

  defp rail_left(assigns) do
    ~H"""
    <div class="rail-hd">
      <button
        type="button"
        class="rail-toggle"
        data-rail-toggle="left"
        aria-label="Mostrar/ocultar categorías"
      >
        <.icon_sidebar_left />
      </button>
      <div class="rail-title">Categorías</div>
    </div>
    <nav class="cat-list">
        <%= for cat <- @categories do %>
          <% open? = @open_category == cat.slug %>
          <% selected? = @selected_category == cat.slug and is_nil(@selected_subcategory) %>
          <div class={["cat", open? && "cat--open", selected? && "cat--selected"]}>
            <button
              type="button"
              class="cat-row"
              phx-click="toggle_category"
              phx-value-slug={cat.slug}
              aria-expanded={open?}
            >
              <span class="cat-name">{cat.name}</span>
              <span class="cat-count">{length(cat.subcategories)}</span>
              <span class="cat-chev"><.icon_chevron_right /></span>
            </button>
            <%= if open? do %>
              <ul class="sub-list">
                <li>
                  <.link
                    patch={~p"/?#{[cat: cat.slug]}"}
                    class={["sub-link", "sub-link--all", selected? && "sub-link--selected"]}
                  >
                    Todo en {cat.name}
                  </.link>
                </li>
                <li :for={sub <- cat.subcategories}>
                  <.link
                    patch={~p"/?#{[sub: sub.slug]}"}
                    class={["sub-link", @selected_subcategory == sub.slug && "sub-link--selected"]}
                  >
                    {sub.name}
                  </.link>
                </li>
              </ul>
            <% end %>
          </div>
        <% end %>
      </nav>
    """
  end

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

  defp icon_sidebar_left(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" class="icon" aria-hidden="true">
      <path d="M5.579 19.807h13.054c2.137 0 3.367-1.289 3.367-3.579V7.78c0-2.29-1.23-3.587-3.367-3.587H5.579C3.298 4.193 2 5.49 2 7.78v8.448c0 2.29 1.298 3.579 3.579 3.579Zm.009-1.365c-1.408 0-2.222-.806-2.222-2.214V7.78c0-1.408.814-2.222 2.222-2.222h2.875v12.884H5.588Zm12.824-12.884c1.408 0 2.222.814 2.222 2.222v8.448c0 1.408-.814 2.214-2.222 2.214H9.795V5.558h8.617Zm-11.577 3.155a.483.483 0 0 0 .483-.475c0-.254-.229-.475-.483-.475H5.011a.475.475 0 0 0-.475.475c0 .254.221.475.475.475h1.824Zm0 2.197a.483.483 0 0 0 .483-.483.475.475 0 0 0-.483-.467H5.011a.467.467 0 0 0-.475.467c0 .254.221.483.475.483h1.824Zm0 2.188a.475.475 0 0 0 .483-.466c0-.255-.229-.475-.483-.475H5.011a.475.475 0 0 0-.475.475c0 .254.221.466.475.466h1.824Z"/>
    </svg>
    """
  end

  defp icon_sidebar_right(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" class="icon" aria-hidden="true">
      <path d="M5.579 19.807h13.054c2.137 0 3.367-1.289 3.367-3.579V7.78c0-2.29-1.23-3.587-3.367-3.587H5.579C3.298 4.193 2 5.49 2 7.78v8.448c0 2.29 1.298 3.579 3.579 3.579Zm.009-1.365c-1.408 0-2.222-.806-2.222-2.214V7.78c0-1.408.814-2.222 2.222-2.222h8.643v12.884H5.588Zm12.824-12.884c1.408 0 2.222.814 2.222 2.222v8.448c0 1.408-.814 2.214-2.222 2.214h-2.85V5.558h2.85Zm-1.221 3.155h1.815a.483.483 0 0 0 .483-.475.475.475 0 0 0-.483-.475H17.19a.475.475 0 0 0-.484.475c0 .254.22.475.484.475Zm0 2.197h1.815a.483.483 0 0 0 .483-.483.475.475 0 0 0-.483-.467H17.19a.475.475 0 0 0-.484.467c0 .254.22.483.484.483Zm0 2.188h1.815a.475.475 0 0 0 .483-.466.475.475 0 0 0-.483-.475H17.19a.475.475 0 0 0-.484.475c0 .254.22.466.484.466Z"/>
    </svg>
    """
  end

  defp icon_chevron_right(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" class="icon icon--chev" aria-hidden="true">
      <path d="M9 6l6 6-6 6"/>
    </svg>
    """
  end

  ## ── Helpers ─────────────────────────────────────────────────

  defp products_for(""), do: []

  defp products_for(query) do
    q = String.downcase(String.trim(query))

    @products
    |> Enum.filter(fn p -> q == "" or String.contains?(String.downcase(p.name), q) end)
    |> Enum.map(&Map.put(&1, :range, price_range(&1)))
  end

  defp price_range(%{prices: prices}) do
    vals = prices |> Map.values() |> Enum.reject(&is_nil/1)
    %{lo: Enum.min(vals), hi: Enum.max(vals), count: length(vals)}
  end

  defp cart_items(cart) when map_size(cart) == 0, do: []

  defp cart_items(cart) do
    for {id, qty} <- cart, product = Enum.find(@products, &(&1.id == id)) do
      r = price_range(product)
      mid = round((r.lo + r.hi) / 2 * qty)
      spread = round((r.hi - r.lo) / 2 * qty)
      %{product: product, qty: qty, lo: r.lo, hi: r.hi, mid: mid, spread: spread}
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
