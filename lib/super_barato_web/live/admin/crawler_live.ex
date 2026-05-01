defmodule SuperBaratoWeb.Admin.CrawlerLive do
  @moduledoc """
  Live runtime view for the crawler pipeline. Self-tics every 500 ms,
  fetches a fresh `Status.all/0 + Status.persistence/0` snapshot, and
  re-renders the topology graph + per-chain row.

  Replaces the old `RuntimeController` GET. The previous controller's
  POSTs (`toggle`, `trigger`, `flush`) live here as `handle_event/3`
  callbacks.
  """

  use SuperBaratoWeb, :live_view
  use StupendousAdmin

  import SuperBaratoWeb.Admin.Components

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.Status
  alias SuperBaratoWeb.Admin.ListingHTML

  defdelegate format_datetime(dt), to: ListingHTML

  @tick_ms 500
  @kinds ~w(discover_categories discover_products refresh_listings)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign(:top_nav, :crawlers)
     |> assign(:sub_nav, :runtime)
     |> assign(:page_title, "Crawlers · Live")
     |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    new_state = Crawler.set_enabled(not Crawler.enabled?())
    msg = "Crawler operation #{if new_state, do: "enabled", else: "paused"}."
    {:noreply, socket |> put_flash(:info, msg) |> refresh()}
  end

  def handle_event("trigger", %{"chain" => chain, "kind" => kind}, socket) do
    chain_atom = parse_chain(chain)

    cond do
      is_nil(chain_atom) ->
        {:noreply, put_flash(socket, :error, "Unknown chain: #{chain}")}

      kind not in @kinds ->
        {:noreply, put_flash(socket, :error, "Unknown kind: #{kind}")}

      true ->
        case Crawler.trigger(chain_atom, kind) do
          :ok ->
            {:noreply, put_flash(socket, :info, "Triggered #{kind} for #{chain}.")}

          {:error, :pipeline_not_running} ->
            {:noreply, put_flash(socket, :error, "Pipeline for #{chain} is not running.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Trigger failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("flush", %{"chain" => chain}, socket) do
    case parse_chain(chain) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown chain: #{chain}")}

      chain_atom ->
        case Crawler.flush_queue(chain_atom) do
          {:ok, n} ->
            {:noreply, put_flash(socket, :info, "Flushed #{n} task(s) from #{chain}.")}

          {:error, :pipeline_not_running} ->
            {:noreply, put_flash(socket, :error, "Pipeline for #{chain} is not running.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Flush failed: #{inspect(reason)}")}
        end
    end
  end

  defp refresh(socket) do
    socket
    |> assign(:snapshots, Status.all())
    |> assign(:persistence, Status.persistence())
    |> assign(:crawler_enabled, Crawler.enabled?())
  end

  defp parse_chain(s) when is_binary(s) do
    try do
      atom = String.to_existing_atom(s)
      if atom in Crawler.known_chains(), do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.sub_navigation active={@sub_nav}>
      <:item key={:runtime} href={~p"/crawlers/live"}>Live</:item>
      <:item key={:schedules} href={~p"/crawlers/schedules"}>Cron Jobs</:item>
      <:item key={:manual} href={~p"/crawlers/manual"}>Manual</:item>
    </.sub_navigation>

    <.admin_container>
      <.page_header title="Crawlers · Live">
        <:actions>
          <.button
            phx-click="toggle"
            variant={(@crawler_enabled && :subtle) || :primary}
            size={:sm}
            data-confirm={
              if @crawler_enabled,
                do: "Pause all crawler activity?",
                else: "Resume crawler activity?"
            }
          >
            <.sfsymbol name={(@crawler_enabled && "pause.circle") || "play.circle"} />
            {(@crawler_enabled && "Pause") || "Resume"}
          </.button>
        </:actions>
      </.page_header>

      <.pipeline_graph snapshots={@snapshots} persistence={@persistence} />

      <.section_header title="Per-chain controls" />

      <.table rows={@snapshots} empty="No chains registered.">
        <:col :let={s} label="Chain"><.chain_badge chain={s.chain} /></:col>
        <:col :let={s} label="Pipeline" align={:center}>
          <.pill color={(s.running && :green) || :regular}>
            {(s.running && "running") || "idle"}
          </.pill>
        </:col>
        <:col :let={s} label="Profile">{s.profile || "—"}</:col>
        <:col :let={s} label="Queue" align={:right}>
          {s.queue_depth || 0}<span :if={s.queue_capacity}>/{s.queue_capacity}</span>
        </:col>
        <:col :let={s} label="Listings" align={:right}>
          <div>{s.listings_count}</div>
          <div class="cell-secondary">{format_datetime(s.last_priced_at)}</div>
        </:col>
        <:col :let={s} label="Categories" align={:right}>
          <div>{s.categories_count}</div>
          <div class="cell-secondary">{format_datetime(s.last_seen_at)}</div>
        </:col>
        <:action :let={s}>
          <.row_actions>
            <.button
              phx-click="trigger"
              phx-value-chain={s.chain}
              phx-value-kind="discover_categories"
              variant={:subtle}
              size={:sm}
              disabled={!s.running}
            >
              <.sfsymbol name="folder" /> Categories
            </.button>
            <.button
              phx-click="trigger"
              phx-value-chain={s.chain}
              phx-value-kind="discover_products"
              variant={:subtle}
              size={:sm}
              disabled={!s.running}
            >
              <.sfsymbol name="play.circle" /> Products
            </.button>
            <.button
              phx-click="trigger"
              phx-value-chain={s.chain}
              phx-value-kind="refresh_listings"
              variant={:subtle}
              size={:sm}
              disabled={!s.running}
            >
              <.sfsymbol name="arrow.clockwise" /> Price
            </.button>
            <.button
              phx-click="flush"
              phx-value-chain={s.chain}
              variant={:subtle}
              size={:sm}
              disabled={!s.running}
              data-confirm={"Drop every queued task for #{s.chain}? This is non-reversible."}
            >
              <.sfsymbol name="trash" /> Flush
            </.button>
          </.row_actions>
        </:action>
      </.table>
    </.admin_container>
    """
  end

  # ---------------------------------------------------------------
  # Topology graph
  #
  # Plain HTML grid (no SVG) for layout simplicity — six rows of
  # Scheduler → Queue → Fetcher boxes in the left column, all feeding
  # one PersistenceServer box in the right column.
  # ---------------------------------------------------------------

  defp pipeline_graph(assigns) do
    ~H"""
    <div class="pipeline-graph">
      <div class="pipeline-graph__chains">
        <div :for={s <- @snapshots} class="pipeline-graph__row">
          <div class="pipeline-graph__chain"><.chain_badge chain={s.chain} /></div>
          <.stage_box
            label="Scheduler"
            running={s.running}
            primary={"#{s.schedule_count} entries"}
            secondary={"mbox #{s.scheduler_mailbox || 0}"}
          />
          <.arrow />
          <.stage_box
            label="Queue"
            running={s.running}
            primary={"#{s.queue_depth || 0} / #{s.queue_capacity || 0}"}
            secondary={queue_fill_label(s)}
            tone={queue_tone(s)}
          />
          <.arrow />
          <.stage_box
            label="Fetcher"
            running={s.running}
            primary={s.profile || "idle"}
            secondary={"mbox #{s.fetcher_mailbox || 0}"}
          />
          <.arrow />
        </div>
      </div>

      <div class="pipeline-graph__sink">
        <.stage_box
          label="PersistenceServer"
          running={@persistence.alive}
          primary={"#{format_float(@persistence.ops_per_sec)} ops/s"}
          secondary={persistence_secondary(@persistence)}
          tone={persistence_tone(@persistence)}
          wide
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :primary, :string, required: true
  attr :secondary, :string, default: nil
  attr :running, :boolean, default: true
  attr :tone, :atom, default: :neutral, values: [:neutral, :warn, :critical, :idle]
  attr :wide, :boolean, default: false

  defp stage_box(assigns) do
    ~H"""
    <div class={[
      "pipeline-stage",
      "pipeline-stage--#{@tone}",
      not @running && "pipeline-stage--idle",
      @wide && "pipeline-stage--wide"
    ]}>
      <div class="pipeline-stage__label">{@label}</div>
      <div class="pipeline-stage__primary">{@primary}</div>
      <div :if={@secondary} class="pipeline-stage__secondary">{@secondary}</div>
    </div>
    """
  end

  defp arrow(assigns), do: ~H[<div class="pipeline-arrow">→</div>]

  defp queue_fill_label(%{queue_depth: d, queue_capacity: c}) when is_integer(d) and is_integer(c) and c > 0 do
    "#{round(d / c * 100)}% full"
  end

  defp queue_fill_label(_), do: "—"

  defp queue_tone(%{queue_depth: d, queue_capacity: c}) when is_integer(d) and is_integer(c) and c > 0 do
    cond do
      d / c >= 0.9 -> :critical
      d / c >= 0.6 -> :warn
      true -> :neutral
    end
  end

  defp queue_tone(_), do: :neutral

  defp persistence_secondary(p) do
    parts = [
      "mbox #{p.mailbox_len}",
      "total #{p.total_handled}"
    ]

    parts = if p.last_handled_at, do: parts ++ ["last #{format_datetime(p.last_handled_at)}"], else: parts

    Enum.join(parts, " · ")
  end

  defp persistence_tone(%{alive: false}), do: :critical
  defp persistence_tone(%{mailbox_len: n}) when n > 100, do: :critical
  defp persistence_tone(%{mailbox_len: n}) when n > 25, do: :warn
  defp persistence_tone(_), do: :neutral

  defp format_float(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 1)
  defp format_float(_), do: "0.0"
end
