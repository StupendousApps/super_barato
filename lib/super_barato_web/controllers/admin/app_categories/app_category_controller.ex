defmodule SuperBaratoWeb.Admin.AppCategoryController do
  use SuperBaratoWeb, :controller

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :admin}

  def index(conn, _params) do
    conn
    |> assign(:top_nav, :app_categories)
    |> assign(:page_title, "App Categories")
    |> render(:index)
  end
end
