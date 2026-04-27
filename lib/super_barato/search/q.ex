defmodule SuperBarato.Search.Q do
  @moduledoc """
  Multi-column LIKE filter with `&&` (AND) / `||` (OR) operators.

  Admin search boxes accept a free-form string. Without operators the
  whole string is matched as one substring across each given column.
  With `&&` between tokens, **every** token must appear in **at
  least one** of the columns. With `||`, any token matches.

  Examples (cols = `[:name, :brand]`):

      "Milo"            → name LIKE %Milo% OR brand LIKE %Milo%
      "Milo && 230 g"   → (name|brand LIKE %Milo%) AND (name|brand LIKE %230 g%)
      "Milo || Nesquik" → (name|brand LIKE %Milo%) OR  (name|brand LIKE %Nesquik%)

  Mixed expressions are not supported — the **first** operator found
  wins; any other instances of the unused operator stay literal in
  their token. Empty terms (`Milo&&`, `&&Milo`) are dropped, the
  remaining tokens still apply.

  `%` inside tokens is replaced with `\\%` to mirror existing
  SQLite-LIKE behavior in the catalog queries.
  """

  import Ecto.Query

  @doc """
  Apply the search to `query`. `cols` is the list of column atoms
  on the query's primary binding to LIKE-match against. Nil/empty
  `q` returns the query unchanged.
  """
  @spec filter(Ecto.Queryable.t(), String.t() | nil, [atom()]) :: Ecto.Queryable.t()
  def filter(query, nil, _cols), do: query
  def filter(query, "", _cols), do: query

  def filter(query, q, cols) when is_binary(q) and is_list(cols) and cols != [] do
    case parse(q) do
      :empty -> query
      {op, tokens} -> where(query, ^build(op, tokens, cols))
    end
  end

  @doc false
  # Public for tests. Returns `:empty` for input that produces no
  # tokens after splitting/trimming, otherwise `{:and | :or, [token,
  # ...]}`.
  def parse(q) when is_binary(q) do
    case first_operator(q) do
      :and ->
        case split(q, "&&") do
          [] -> :empty
          tokens -> {:and, tokens}
        end

      :or ->
        case split(q, "||") do
          [] -> :empty
          tokens -> {:or, tokens}
        end

      :none ->
        case String.trim(q) do
          "" -> :empty
          t -> {:or, [t]}
        end
    end
  end

  # Whichever of `&&` / `||` appears earliest wins — anything past
  # the chosen operator stays literal in its token.
  defp first_operator(q) do
    a = index_of(q, "&&")
    o = index_of(q, "||")

    cond do
      is_nil(a) and is_nil(o) -> :none
      is_nil(a) -> :or
      is_nil(o) -> :and
      a <= o -> :and
      true -> :or
    end
  end

  defp index_of(s, sub) do
    case :binary.match(s, sub) do
      :nomatch -> nil
      {pos, _} -> pos
    end
  end

  defp split(q, sep) do
    q
    |> String.split(sep)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Build the dynamic where clause:
  # for each token, OR the column matches together; combine
  # per-token expressions with AND or OR depending on `op`.
  defp build(op, tokens, cols) do
    Enum.reduce(tokens, nil, fn token, acc ->
      per_token = token_clause(token, cols)

      case {acc, op} do
        {nil, _} -> per_token
        {_, :and} -> dynamic(^acc and ^per_token)
        {_, :or} -> dynamic(^acc or ^per_token)
      end
    end)
  end

  defp token_clause(token, cols) do
    like = "%" <> String.replace(token, "%", "\\%") <> "%"

    Enum.reduce(cols, nil, fn col, acc ->
      col_dyn = dynamic([x], like(field(x, ^col), ^like))

      case acc do
        nil -> col_dyn
        _ -> dynamic(^acc or ^col_dyn)
      end
    end)
  end
end
