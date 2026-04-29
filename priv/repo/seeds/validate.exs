# Validate that every [x]: {category, subcategory} reference points
# at a real (AppCategory.slug, AppSubcategory.slug) pair from the DB.
#
#   mix run priv/repo/seeds/validate.exs
#
# Exits 1 on the first mismatched mapping so this can be wired into
# CI / pre-commit later.

alias SuperBarato.Catalog.{AppCategory, AppSubcategory, CategoryChecklist}
alias SuperBarato.Repo
import Ecto.Query

valid_pairs =
  Repo.all(
    from s in AppSubcategory,
      join: c in AppCategory,
      on: c.id == s.app_category_id,
      select: {c.slug, s.slug}
  )
  |> MapSet.new()

dir = Path.expand("categories", __DIR__)
chains = ~w(jumbo santa_isabel lider tottus unimarc acuenta)

errors =
  Enum.flat_map(chains, fn chain ->
    path = Path.join(dir, "#{chain}.txt")

    if File.exists?(path) do
      path
      |> CategoryChecklist.parse_file()
      |> Enum.filter(&(&1.status == :mapped))
      |> Enum.reject(fn e ->
        MapSet.member?(valid_pairs, {e.mapping.category, e.mapping.subcategory})
      end)
      |> Enum.map(&{chain, &1})
    else
      []
    end
  end)

case errors do
  [] ->
    IO.puts("OK — all [x] mappings reference real (category, subcategory) pairs.")

  _ ->
    IO.puts("FAIL — #{length(errors)} invalid mapping(s):")

    for {chain, e} <- errors do
      IO.puts("  [#{chain}] #{e.path}")
      IO.puts("    slug:    #{e.slug}")
      IO.puts("    points to: category=#{e.mapping.category}, subcategory=#{e.mapping.subcategory}")
    end

    System.halt(1)
end
