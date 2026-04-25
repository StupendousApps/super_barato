defmodule SuperBaratoWeb.Admin.RuntimeHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin

  alias SuperBaratoWeb.Admin.ListingHTML

  embed_templates "runtime_html/*"

  defdelegate chain_label(chain), to: ListingHTML
  defdelegate format_datetime(dt), to: ListingHTML
end
