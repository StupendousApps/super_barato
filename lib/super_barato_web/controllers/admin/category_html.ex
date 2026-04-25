defmodule SuperBaratoWeb.Admin.CategoryHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin

  alias SuperBaratoWeb.Admin.CategoryController
  alias SuperBaratoWeb.Admin.ListingHTML

  embed_templates "category_html/*"

  defdelegate chain_label(chain), to: ListingHTML
  defdelegate format_datetime(dt), to: ListingHTML
  defdelegate sort_dir(field, current), to: ListingHTML
  defdelegate sort_href(path, params, field, current), to: ListingHTML

  def chain_tabs, do: CategoryController.chains()

  def chain_tab_href(nil), do: ~p"/categories"
  def chain_tab_href(chain), do: ~p"/categories?#{[chain: chain]}"
end
