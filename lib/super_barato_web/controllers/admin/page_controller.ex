defmodule SuperBaratoWeb.Admin.PageController do
  use SuperBaratoWeb, :controller

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :app}

  def index(conn, _params) do
    conn
    |> assign(:page_title, "Dashboard")
    |> assign(:top_nav, :dashboard)
    |> render(:index)
  end
end
