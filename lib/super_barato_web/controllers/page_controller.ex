defmodule SuperBaratoWeb.PageController do
  use SuperBaratoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
