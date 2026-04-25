defmodule SuperBaratoWeb.AdminLayouts do
  @moduledoc """
  Root + app layouts for the /admin section. All chrome (page header,
  table, forms, navigation, flash) comes from the `:stupendous_admin`
  library — this module just wires `<.admin_body>` and the navigation
  shape, then delegates everything else to library components.
  """
  use SuperBaratoWeb, :html
  use StupendousAdmin

  embed_templates "admin_layouts/*"
end
