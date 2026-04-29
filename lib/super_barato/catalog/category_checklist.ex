defmodule SuperBarato.Catalog.CategoryChecklist do
  @moduledoc """
  Parser for the per-chain category checklist files at
  `priv/repo/seeds/categories/<chain>.txt`.

  Each entry is three lines, separated by a blank line:

      <status>
      <count> <ancestry-path>
      <slug>

  Status syntax:

      [ ]                                              unchecked
      [-]                                              checked, no chain category fits
      [N]                                              checked, no 1:1 mapping is possible
      [x]: {category: "<cat>", subcategory: "<sub>"}   mapped to a unified subcategory

  An entry parses into:

      %{
        status:  :unchecked | :no_match | :no_mapping | :mapped,
        count:   non_neg_integer,
        path:    String.t,
        slug:    String.t,
        mapping: nil | %{category: String.t, subcategory: String.t}
      }
  """

  @type status :: :unchecked | :no_match | :no_mapping | :mapped

  @type mapping :: %{category: String.t(), subcategory: String.t()}

  @type entry :: %{
          status: status,
          count: non_neg_integer,
          path: String.t(),
          slug: String.t(),
          mapping: mapping | nil
        }

  @spec parse_file(Path.t()) :: [entry]
  def parse_file(path), do: path |> File.read!() |> parse()

  @spec write_file!(Path.t(), [entry]) :: :ok
  def write_file!(path, entries) do
    File.write!(path, serialize(entries))
  end

  @spec serialize([entry]) :: String.t()
  def serialize(entries) do
    entries
    |> Enum.map(&serialize_entry/1)
    |> Enum.join("\n")
  end

  defp serialize_entry(%{status: status, count: count, path: path, slug: slug, mapping: mapping}) do
    status_line(status, mapping) <> "\n" <>
      String.pad_leading(Integer.to_string(count), 4) <> "  " <> path <> "\n" <>
      slug <> "\n"
  end

  defp status_line(:unchecked, _), do: "[ ]"
  defp status_line(:no_match, _), do: "[-]"
  defp status_line(:no_mapping, _), do: "[N]"

  defp status_line(:mapped, %{category: cat, subcategory: sub}),
    do: ~s/[x]: {category: "#{cat}", subcategory: "#{sub}"}/

  @spec parse(String.t()) :: [entry]
  def parse(text) do
    text
    |> String.split(~r/\r?\n\r?\n+/, trim: true)
    |> Enum.map(&parse_block/1)
  end

  defp parse_block(block) do
    [status_line, count_path_line, slug_line] =
      block |> String.split("\n", parts: 3) |> Enum.map(&String.trim_trailing/1)

    {status, mapping} = parse_status(String.trim(status_line))
    {count, path} = parse_count_path(count_path_line)

    %{
      status: status,
      count: count,
      path: path,
      slug: String.trim(slug_line),
      mapping: mapping
    }
  end

  defp parse_status("[ ]"), do: {:unchecked, nil}
  defp parse_status("[-]"), do: {:no_match, nil}
  defp parse_status("[N]"), do: {:no_mapping, nil}

  defp parse_status("[x]:" <> rest) do
    cat = capture!(rest, ~r/category:\s*"([^"]+)"/, "category")
    sub = capture!(rest, ~r/subcategory:\s*"([^"]+)"/, "subcategory")
    {:mapped, %{category: cat, subcategory: sub}}
  end

  defp parse_status(other),
    do: raise(ArgumentError, "unrecognized checklist status: #{inspect(other)}")

  defp parse_count_path(line) do
    case Regex.run(~r/^\s*(\d+)\s+(.+)$/, line) do
      [_, n, path] -> {String.to_integer(n), path}
      _ -> raise ArgumentError, "expected '<count>  <path>', got: #{inspect(line)}"
    end
  end

  defp capture!(s, regex, label) do
    case Regex.run(regex, s) do
      [_, value] -> value
      _ -> raise ArgumentError, "missing #{label} in mapped entry: #{inspect(s)}"
    end
  end
end
