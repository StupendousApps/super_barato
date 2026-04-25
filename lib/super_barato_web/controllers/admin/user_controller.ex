defmodule SuperBaratoWeb.Admin.UserController do
  use SuperBaratoWeb, :controller

  alias SuperBarato.Accounts
  alias SuperBarato.Accounts.User

  plug :put_root_layout, html: {SuperBaratoWeb.AdminLayouts, :root}
  plug :put_layout, html: {SuperBaratoWeb.AdminLayouts, :app}

  def index(conn, _params) do
    conn
    |> assign(:top_nav, :users)
    |> assign(:users, Accounts.list_users())
    |> assign(:page_title, "Users")
    |> render(:index)
  end

  def edit(conn, %{"id" => id}) do
    user = Accounts.get_user!(id)
    changeset = Accounts.change_user_password(user)

    conn
    |> assign(:top_nav, :users)
    |> assign(:user, user)
    |> assign(:changeset, changeset)
    |> assign(:page_title, "Edit user · #{user.email}")
    |> render(:edit)
  end

  def delete(conn, %{"id" => id}) do
    user = Accounts.get_user!(id)
    current = conn.assigns.current_scope.user

    cond do
      user.id == current.id ->
        conn
        |> put_flash(:error, "You can't delete the account you're signed in with.")
        |> redirect(to: ~p"/users")

      true ->
        {:ok, _} = Accounts.delete_user(user)

        conn
        |> put_flash(:info, "User #{user.email} deleted.")
        |> redirect(to: ~p"/users")
    end
  end

  def update(conn, %{"id" => id, "user" => user_params}) do
    user = Accounts.get_user!(id)

    case Accounts.update_user_password(user, user_params) do
      {:ok, {_user, _expired_tokens}} ->
        conn
        |> put_flash(:info, "Password updated. The user's existing sessions were terminated.")
        |> redirect(to: ~p"/users")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign(:top_nav, :users)
        |> assign(:user, user)
        |> assign(:changeset, changeset)
        |> assign(:page_title, "Edit user · #{user.email}")
        |> render(:edit)
    end
  end

  # Used by the index template to render the role badge.
  def role_label(role) when is_atom(role), do: Atom.to_string(role)
  def role_label(role), do: to_string(role)

  def confirmed_label(%User{confirmed_at: nil}), do: "—"
  def confirmed_label(%User{confirmed_at: %DateTime{}}), do: "✓"
end
