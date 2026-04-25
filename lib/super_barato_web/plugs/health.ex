defmodule SuperBaratoWeb.Plugs.Health do
  @moduledoc """
  Tiny liveness probe at `GET /up`. Returns `200 OK` with no body,
  bypassing the router (and therefore CSRF, host constraints, the
  session store, and the rest of the browser pipeline). Mounted
  early in the endpoint so it stays cheap and works on every host.

  Used by Kamal's proxy healthcheck.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(_opts), do: :ok

  @impl true
  def call(%{request_path: "/up"} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "OK")
    |> halt()
  end

  def call(conn, _opts), do: conn
end
