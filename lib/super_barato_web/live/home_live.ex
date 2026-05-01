defmodule SuperBaratoWeb.HomeLive do
  use SuperBaratoWeb, :live_view

  import Ecto.Query

  alias SuperBarato.{Catalog, Linker}
  alias SuperBarato.Catalog.Product
  alias SuperBarato.Repo

  @results_per_page 50

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
     |> assign(:products, [])
     |> assign(:total_count, 0)
     |> assign(:page_title, "SuperBarato.cl"), layout: false}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:query, params["q"] || "")
     |> assign(:selected_category, params["cat"])
     |> assign(:selected_subcategory, params["sub"])
     |> maybe_open_category()
     |> run_search()}
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
    {:noreply, socket |> assign(:query, q) |> run_search()}
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

  # Accordion toggle on the left rail. Clicking a category name opens
  # its subcategory list (or closes if already open). We don't change
  # the URL here — that's only for actual selections.
  def handle_event("toggle_category", %{"slug" => slug}, socket) do
    open = if socket.assigns.open_category == slug, do: nil, else: slug
    {:noreply, assign(socket, :open_category, open)}
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
      assign(socket, products: [], total_count: 0)
    else
      result =
        Catalog.list_products_page(
          q: q,
          app_category: cat,
          app_subcategory: sub,
          page: 1,
          per_page: @results_per_page
        )

      pids = Enum.map(result.items, & &1.id)
      ranges = Linker.price_range_by_product_ids(pids)
      chains = Linker.chains_by_product_ids(pids)

      products =
        Enum.map(result.items, fn p ->
          {min_p, max_p} = Map.get(ranges, p.id, {nil, nil})
          chain_count = chains |> Map.get(p.id, []) |> length()

          %{
            id: p.id,
            name: p.canonical_name,
            brand: p.brand,
            image_url: p.image_url,
            range: %{lo: min_p, hi: max_p, count: chain_count}
          }
        end)

      assign(socket, products: products, total_count: result.total_entries)
    end
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
          <div class="container">
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

        <main class="main">
         <div class="container">
          <div class="results-hd">
            <h2>
              Resultados
              <em :if={@query != ""}>"{@query}"</em>
            </h2>
            <div class="count">
              <%= cond do %>
                <% @query == "" and is_nil(@selected_category) and is_nil(@selected_subcategory) -> %>
                  6 supermercados
                <% @total_count > @results_per_page -> %>
                  {@total_count} resultados (mostrando {length(@products)})
                <% true -> %>
                  {@total_count} resultados
              <% end %>
            </div>
          </div>

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
                  :for={p <- @products}
                  type="button"
                  class="card"
                  phx-click="add"
                  phx-value-id={p.id}
                  aria-label={"Agregar #{p.name}"}
                >
                  <div class="img">
                    <img :if={p.image_url} src={p.image_url} alt="" loading="lazy" />
                    <div class="hover-cta"><span class="plus">+</span>Agregar</div>
                  </div>
                  <div class="name">{p.name}</div>
                  <div :if={p.brand} class="brand">{p.brand}</div>
                  <div class="range">
                    <%= cond do %>
                      <% is_nil(p.range.lo) -> %>
                        <span class="lo">—</span>
                      <% p.range.lo == p.range.hi -> %>
                        <span class="lo">{format_clp(p.range.lo)}</span>
                      <% true -> %>
                        <span class="lo">{format_clp(p.range.lo)}</span>
                        <span class="dash">–</span>
                        <span class="hi">{format_clp(p.range.hi)}</span>
                    <% end %>
                  </div>
                  <div class="stores">
                    <span class="dots">
                      <span :for={_ <- 1..max(p.range.count, 1)//1} class="d"></span>
                    </span>
                    {p.range.count} {if p.range.count == 1, do: "supermercado", else: "supermercados"}
                  </div>
                </button>
              </div>
          <% end %>
         </div>
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
