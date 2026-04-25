defmodule SuperBaratoWeb.Admin.ScheduleController do
  use SuperBaratoWeb, :controller

  alias SuperBarato.{Crawler, Crawler.Schedule, Crawler.Schedules}

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :app}

  @kinds ["discover_categories", "discover_products"]

  def index(conn, params) do
    chain = parse_chain(params["chain"])
    kind = parse_kind(params["kind"])
    filters = %{chain: params["chain"] || "", kind: params["kind"] || ""}

    conn
    |> nav_assigns()
    |> assign(:schedules, Schedules.list(chain: chain, kind: kind))
    |> assign(:active_chain, chain)
    |> assign(:filters, filters)
    |> assign(:page_title, "Cron Jobs")
    |> render(:index)
  end

  defp parse_chain(nil), do: nil
  defp parse_chain(""), do: nil

  defp parse_chain(s) when is_binary(s) do
    try do
      atom = String.to_existing_atom(s)
      if atom in Crawler.known_chains(), do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
  end

  defp parse_kind(kind) when kind in @kinds, do: kind
  defp parse_kind(_), do: nil

  def new(conn, _params) do
    changeset = Schedules.change_schedule(%Schedule{active: true})

    conn
    |> nav_assigns()
    |> assign(:page_title, "New Cron Job")
    |> assign(:changeset, changeset)
    |> assign(:action, ~p"/crawlers/schedules")
    |> render(:new)
  end

  def create(conn, %{"schedule" => attrs}) do
    case Schedules.create(attrs) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Cron job created. Cron reloaded.")
        |> redirect(to: ~p"/crawlers/schedules")

      {:error, changeset} ->
        conn
        |> nav_assigns()
        |> assign(:page_title, "New Cron Job")
        |> assign(:changeset, changeset)
        |> assign(:action, ~p"/crawlers/schedules")
        |> render(:new)
    end
  end

  def edit(conn, %{"id" => id}) do
    schedule = Schedules.get!(id)
    changeset = Schedules.change_schedule(schedule)

    conn
    |> nav_assigns()
    |> assign(:page_title, "Edit Cron Job")
    |> assign(:schedule, schedule)
    |> assign(:changeset, changeset)
    |> assign(:action, ~p"/crawlers/schedules/#{schedule.id}")
    |> render(:edit)
  end

  def update(conn, %{"id" => id, "schedule" => attrs}) do
    schedule = Schedules.get!(id)

    case Schedules.update(schedule, attrs) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Cron job updated. Cron reloaded.")
        |> redirect(to: ~p"/crawlers/schedules")

      {:error, changeset} ->
        conn
        |> nav_assigns()
        |> assign(:page_title, "Edit Cron Job")
        |> assign(:schedule, schedule)
        |> assign(:changeset, changeset)
        |> assign(:action, ~p"/crawlers/schedules/#{schedule.id}")
        |> render(:edit)
    end
  end

  def delete(conn, %{"id" => id}) do
    id |> Schedules.get!() |> Schedules.delete()

    conn
    |> put_flash(:info, "Cron job deleted. Cron reloaded.")
    |> redirect(to: ~p"/crawlers/schedules")
  end

  defp nav_assigns(conn) do
    conn
    |> assign(:top_nav, :crawlers)
    |> assign(:sub_nav, :schedules)
  end
end
