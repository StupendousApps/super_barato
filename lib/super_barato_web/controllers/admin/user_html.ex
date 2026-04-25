defmodule SuperBaratoWeb.Admin.UserHTML do
  use SuperBaratoWeb, :html

  alias SuperBaratoWeb.Admin.ListingHTML
  alias SuperBaratoWeb.Admin.UserController

  embed_templates "user_html/*"

  defdelegate format_datetime(dt), to: ListingHTML
  defdelegate role_label(role), to: UserController
  defdelegate confirmed_label(user), to: UserController

  defp error_messages(field) do
    Enum.map(field.errors, &SuperBaratoWeb.CoreComponents.translate_error/1)
  end
end
