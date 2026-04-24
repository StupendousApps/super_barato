defmodule SuperBarato.PriceLog do
  @moduledoc """
  Append-only file-backed price history. Each `(chain, chain_sku)` gets
  a log file at `<root>/<chain>/<chain_sku>.log` with one line per
  observation:

      <unix_seconds> <regular_price> [<promo_price>]

  `promo_price` is omitted when the product wasn't on promo at capture
  time. Time comes first so `sort`, `head`, `tail`, `awk`, and `grep`
  work on ranges naturally.

  Writes are small (<50 bytes) and go out via `File.write/3` with
  `[:append, :binary]` — atomic on POSIX under PIPE_BUF (4096). No
  locking needed even under concurrent appenders.

  Root is configured via `:price_log_dir`:

      config :super_barato, :price_log_dir, "/data/prices"

  Default is `priv/data/prices`, suitable for dev.
  """

  @default_dir "priv/data/prices"

  @doc """
  Appends a price observation. `regular_price` is required; `promo_price`
  is optional. Creates the per-chain directory on first write.

  Returns `:ok` on success, `{:error, reason}` on I/O failure.
  """
  def append(chain, chain_sku, regular_price, promo_price \\ nil, opts \\ [])
      when is_atom(chain) and is_binary(chain_sku) and is_integer(regular_price) do
    unix = Keyword.get(opts, :now, System.system_time(:second))
    path = path_for(chain, chain_sku)

    line =
      case promo_price do
        nil -> "#{unix} #{regular_price}\n"
        p when is_integer(p) -> "#{unix} #{regular_price} #{p}\n"
      end

    case ensure_dir(Path.dirname(path)) do
      :ok -> File.write(path, line, [:append, :binary])
      err -> err
    end
  end

  @doc """
  Reads all observations for a `(chain, chain_sku)`. Returns a list of
  `{unix_seconds, regular_price, promo_price_or_nil}` tuples, oldest
  first. Returns `[]` when the file doesn't exist.
  """
  def read(chain, chain_sku) when is_atom(chain) and is_binary(chain_sku) do
    case File.read(path_for(chain, chain_sku)) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_line/1)
        |> Enum.reject(&is_nil/1)

      {:error, :enoent} ->
        []

      {:error, _} = err ->
        err
    end
  end

  @doc "Absolute log path for a given `(chain, chain_sku)`."
  def path_for(chain, chain_sku) when is_atom(chain) and is_binary(chain_sku) do
    Path.join([root_dir(), Atom.to_string(chain), chain_sku <> ".log"])
  end

  @doc "Root directory where logs live, resolved from app config."
  def root_dir do
    case Application.get_env(:super_barato, :price_log_dir) do
      nil -> Path.expand(@default_dir, File.cwd!())
      dir when is_binary(dir) -> dir
    end
  end

  defp parse_line(line) do
    case String.split(line, " ", trim: true) do
      [ts, regular] ->
        with {t, ""} <- Integer.parse(ts),
             {r, ""} <- Integer.parse(regular) do
          {t, r, nil}
        else
          _ -> nil
        end

      [ts, regular, promo] ->
        with {t, ""} <- Integer.parse(ts),
             {r, ""} <- Integer.parse(regular),
             {p, ""} <- Integer.parse(promo) do
          {t, r, p}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      err -> err
    end
  end
end
