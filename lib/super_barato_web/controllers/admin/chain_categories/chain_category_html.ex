defmodule SuperBaratoWeb.Admin.CategoryHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin
  import SuperBaratoWeb.Admin.Components

  alias SuperBaratoWeb.Admin.CategoryController
  alias SuperBaratoWeb.Admin.ListingHTML

  embed_templates "category_html/*"

  defdelegate format_datetime(dt), to: ListingHTML
  defdelegate sort_dir(field, current), to: ListingHTML
  defdelegate sort_href(path, params, field, current), to: ListingHTML
  defdelegate pdp_host(url), to: ListingHTML

  def chain_tabs, do: CategoryController.chains()

  def chain_tab_href(nil), do: ~p"/categories"
  def chain_tab_href(chain), do: ~p"/categories?#{[chain: chain]}"
end
