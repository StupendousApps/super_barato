defmodule SuperBaratoWeb.Admin.CategoryHTML do
  use SuperBaratoWeb, :html

  alias SuperBaratoWeb.Admin.CategoryController
  alias SuperBaratoWeb.Admin.ListingHTML

  embed_templates "category_html/*"

  defdelegate chain_label(chain), to: ListingHTML
  defdelegate format_datetime(dt), to: ListingHTML

  def chain_tabs, do: CategoryController.chains()

  def chain_tab_href(nil), do: ~p"/admin/categories"
  def chain_tab_href(chain), do: ~p"/admin/categories?#{[chain: chain]}"
end
