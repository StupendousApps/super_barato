defmodule SuperBaratoWeb.Admin.UserHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin

  alias SuperBaratoWeb.Admin.{ListingHTML, UserController}

  embed_templates "user_html/*"

  defdelegate format_datetime(dt), to: ListingHTML
  defdelegate role_label(role), to: UserController
  defdelegate confirmed_label(user), to: UserController
end
