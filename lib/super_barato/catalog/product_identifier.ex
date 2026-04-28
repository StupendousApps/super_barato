defmodule SuperBarato.Catalog.ProductIdentifier do
  @moduledoc """
  Typed identifier anchoring `Catalog.Product`. Each row pairs a
  `kind` (`"ean_13"`, `"ean_8"`, `"<chain>_sku"`) with a `value`. The
  `(kind, value)` unique index enforces that no identifier can anchor
  two different Products — the linker relies on this for safe
  find-or-create lookups.

  A Product may carry multiple identifiers: cross-country GTIN dupes,
  manufacturer relabels, *and* any number of per-chain SKUs that
  observed the product over time. Listings with no EAN still anchor
  via their chain-scoped SKU (`tottus_sku`, `lider_usitemid`, …),
  which is enough to keep them out of the "Unlinked" bucket.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Catalog.Product

  @kinds ~w(ean_13 ean_8 jumbo_sku santa_isabel_sku lider_sku tottus_sku unimarc_sku acuenta_sku)

  schema "product_identifiers" do
    belongs_to :product, Product
    field :kind, :string
    field :value, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Permitted `kind` strings — open-ended; admins can add more."
  def known_kinds, do: @kinds

  def changeset(product_identifier, attrs) do
    product_identifier
    |> cast(attrs, [:product_id, :kind, :value])
    |> validate_required([:product_id, :kind, :value])
    |> validate_format(:kind, ~r/^[a-z0-9_]+$/)
    |> unique_constraint([:kind, :value], name: :product_identifiers_kind_value_index)
    |> foreign_key_constraint(:product_id)
  end
end
