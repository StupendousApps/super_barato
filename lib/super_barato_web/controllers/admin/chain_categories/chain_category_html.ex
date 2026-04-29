defmodule SuperBaratoWeb.Admin.ChainCategoryHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin
  import SuperBaratoWeb.Admin.Components

  alias SuperBaratoWeb.Admin.ChainCategoryController
  alias SuperBaratoWeb.Admin.ListingHTML

  embed_templates "chain_category_html/*"

  defdelegate format_datetime(dt), to: ListingHTML
  defdelegate sort_dir(field, current), to: ListingHTML
  defdelegate sort_href(path, params, field, current), to: ListingHTML
  defdelegate pdp_host(url), to: ListingHTML

  def chain_tabs, do: ChainCategoryController.chains()

  def chain_tab_href(nil), do: ~p"/chain-categories"
  def chain_tab_href(chain), do: ~p"/chain-categories?#{[chain: chain]}"
end
