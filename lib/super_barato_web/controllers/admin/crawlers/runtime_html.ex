defmodule SuperBaratoWeb.Admin.RuntimeHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin
  import SuperBaratoWeb.Admin.Components

  alias SuperBaratoWeb.Admin.ListingHTML

  embed_templates "runtime_html/*"

  defdelegate format_datetime(dt), to: ListingHTML
end
