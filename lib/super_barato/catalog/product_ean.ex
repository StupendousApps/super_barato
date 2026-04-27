defmodule SuperBarato.Catalog.ProductEan do
  @moduledoc """
  A GS1-assigned GTIN-13 anchoring `Catalog.Product`. Many EANs may
  point at the same product (cross-country dupes, manufacturer
  relabels, etc.) — the linker's lookup index. Owned by the Catalog
  context; created by `SuperBarato.Linker.Backfill` and mutated by
  the admin merge action.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.Product

  schema "product_eans" do
    belongs_to :product, Product
    field :ean, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(product_ean, attrs) do
    product_ean
    |> cast(attrs, [:product_id, :ean])
    |> validate_required([:product_id, :ean])
    |> unique_constraint(:ean)
    |> foreign_key_constraint(:product_id)
  end
end
