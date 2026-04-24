defmodule SuperBaratoWeb.HomeLive do
  use SuperBaratoWeb, :live_view

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
     |> assign(:show_login, false)
     |> assign(:page_title, "SuperBarato.cl"), layout: false}
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

  def handle_event("open_login", _params, socket) do
    {:noreply, assign(socket, :show_login, true)}
  end

  def handle_event("close_login", _params, socket) do
    {:noreply, assign(socket, :show_login, false)}
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

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:products, products_for(assigns.query))
      |> assign(:cart_items, cart_items(assigns.cart))

    ~H"""
    <div class="app">
      <div class="stage">
        <div class="frame">
          <div class="right">
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

          <aside class="cart">
            <div class="cart-hd">
              <a class="logo" href="/" aria-label="SuperBarato.cl">
                <span class="super">SUPER</span><span class="barato">barato</span><span class="tld">.cl</span>
              </a>
              <button type="button" class="login" phx-click="open_login">Ingresar</button>
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
          </aside>
        </div>
      </div>

      <%= if @show_login do %>
        <div class="modal-backdrop" phx-click="close_login">
          <div class="modal" phx-click-away="close_login" onclick="event.stopPropagation()">
            <div class="modal-hd">
              <h2>Ingresar</h2>
              <button type="button" class="modal-close" phx-click="close_login" aria-label="Cerrar">×</button>
            </div>
            <form method="post" action={~p"/users/log-in"} class="modal-form">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

              <label>
                <span>Email</span>
                <input type="email" name="user[email]" required autocomplete="email" autofocus />
              </label>

              <label>
                <span>Contraseña</span>
                <input type="password" name="user[password]" required autocomplete="current-password" />
              </label>

              <button type="submit" class="cta">Ingresar</button>
            </form>
          </div>
        </div>
      <% end %>
    </div>
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
