defmodule SuperBaratoWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use SuperBaratoWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint SuperBaratoWeb.Endpoint

      use SuperBaratoWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SuperBaratoWeb.ConnCase
    end
  end

  setup tags do
    SuperBarato.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Register an admin and stamp the conn with a session for them.
  Drop into a test:

      setup :register_and_log_in_admin
  """
  def register_and_log_in_admin(%{conn: conn}, attrs \\ %{}) do
    base = %{
      email: "admin#{System.unique_integer([:positive])}@example.com",
      password: "correct-horse-battery"
    }

    {:ok, admin} = StupendousAdmin.Accounts.register_admin_user(Map.merge(base, attrs))
    %{conn: log_in_admin(conn, admin), admin: admin}
  end

  @doc "Stamp `conn` with an admin session (no Repo writes needed beyond the token)."
  def log_in_admin(conn, admin) do
    token = StupendousAdmin.Accounts.generate_admin_user_session_token(admin)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:admin_token, token)
  end
end
