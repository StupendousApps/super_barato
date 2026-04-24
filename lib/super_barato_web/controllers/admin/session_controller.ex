defmodule SuperBaratoWeb.Admin.SessionController do
  use SuperBaratoWeb, :controller

  alias SuperBarato.Accounts
  alias SuperBarato.Accounts.User
  alias SuperBaratoWeb.UserAuth

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, false when action == :new

  def new(conn, _params) do
    form = Phoenix.Component.to_form(%{"email" => "", "password" => ""}, as: "user")
    render(conn, :new, form: form, error: nil)
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password} = params}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      %User{} = user ->
        if User.role_at_least?(user, :moderator) do
          conn
          |> put_session(:user_return_to, ~p"/admin")
          |> UserAuth.log_in_user(user, params)
        else
          render_error(conn, email, "Your account does not have admin access.")
        end

      nil ->
        render_error(conn, email, "Invalid email or password.")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out.")
    |> UserAuth.log_out_user()
  end

  defp render_error(conn, email, message) do
    form = Phoenix.Component.to_form(%{"email" => email, "password" => ""}, as: "user")

    conn
    |> put_flash(:error, message)
    |> render(:new, form: form, error: message)
  end
end
