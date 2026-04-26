defmodule SuperBaratoWeb.AdminLayouts do
  @moduledoc """
  Root + admin layouts for the /admin section. All chrome (page
  header, table, forms, navigation, flash) comes from the
  `:stupendous_admin` library — this module just wires `<.admin_body>`
  and the navigation shape, then delegates everything else to library
  components.

  Templates: `root.html.heex` (the outer `<html>` shell, includes
  stylesheets and scripts) and `admin.html.heex` (top navigation +
  flash + page slot for content).
  """
  use SuperBaratoWeb, :html
  use StupendousAdmin

  embed_templates "admin_layouts/*"
end
