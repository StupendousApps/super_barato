defmodule SuperBaratoWeb.Admin.RuntimeController do
  use SuperBaratoWeb, :controller

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
end
