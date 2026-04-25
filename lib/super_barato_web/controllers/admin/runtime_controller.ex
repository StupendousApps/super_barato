defmodule SuperBaratoWeb.Admin.RuntimeController do
  use SuperBaratoWeb, :controller

  alias SuperBarato.Crawler
  alias SuperBarato.Crawler.Status

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :app}

  def index(conn, _params) do
    conn
    |> assign(:top_nav, :crawlers)
    |> assign(:sub_nav, :runtime)
    |> assign(:snapshots, Status.all())
    |> assign(:page_title, "Crawlers · Live")
    |> render(:index)
  end

  @kinds ~w(discover_categories discover_products)

  def trigger(conn, %{"chain" => chain, "kind" => kind}) do
    chain_atom = parse_chain(chain)

    cond do
      is_nil(chain_atom) ->
        conn
        |> put_flash(:error, "Unknown chain: #{chain}")
        |> redirect(to: ~p"/admin/crawlers/live")

      kind not in @kinds ->
        conn
        |> put_flash(:error, "Unknown kind: #{kind}")
        |> redirect(to: ~p"/admin/crawlers/live")

      true ->
        case Crawler.trigger(chain_atom, kind) do
          :ok ->
            conn
            |> put_flash(:info, "Triggered #{kind} for #{chain}.")
            |> redirect(to: ~p"/admin/crawlers/live")

          {:error, :pipeline_not_running} ->
            conn
            |> put_flash(:error, "Pipeline for #{chain} is not running.")
            |> redirect(to: ~p"/admin/crawlers/live")

          {:error, reason} ->
            conn
            |> put_flash(:error, "Trigger failed: #{inspect(reason)}")
            |> redirect(to: ~p"/admin/crawlers/live")
        end
    end
  end

  defp parse_chain(s) when is_binary(s) do
    try do
      atom = String.to_existing_atom(s)
      if atom in Crawler.known_chains(), do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
  end
end
