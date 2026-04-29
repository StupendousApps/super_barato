defmodule SuperBarato.Catalog.CategoryChecklist do
  @moduledoc """
  Parser for the per-chain category checklist files at
  `priv/repo/seeds/categories/<chain>.txt`.

  Each entry is three lines, separated by a blank line:

      <entry-id> <status>
      <count> <ancestry-path>
      <slug>

  `entry-id` is an 8-char md5 prefix of `<chain>|<slug>`, stamped by
  `dump_categories.sh`. It anchors a row for bash-side `sed`
  rewrites — triage tools find an entry by its id and only edit the
  status portion.

  Status syntax:

      [ ]            unchecked
      [-]            checked, no chain category fits
      [N]            checked, no 1:1 mapping is possible
      [x] <id>       mapped to a unified subcategory; <id> is the
                     8-char path-derived hash from categories.jsonl

  An entry parses into:

      %{
        entry_id: String.t,
        status:   :unchecked | :no_match | :no_mapping | :mapped,
        count:    non_neg_integer,
        path:     String.t,
        slug:     String.t,
        mapping:  nil | %{id: String.t}
      }
  """

  @type status :: :unchecked | :no_match | :no_mapping | :mapped

  @type mapping :: %{id: String.t()}

  @type entry :: %{
          entry_id: String.t(),
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

  defp serialize_entry(%{
         entry_id: eid,
         status: status,
         count: count,
         path: path,
         slug: slug,
         mapping: mapping
       }) do
    eid <>
      " " <>
      status_payload(status, mapping) <>
      "\n" <>
      String.pad_leading(Integer.to_string(count), 4) <> "  " <> path <> "\n" <> slug <> "\n"
  end

  defp status_payload(:unchecked, _), do: "[ ]"
  defp status_payload(:no_match, _), do: "[-]"
  defp status_payload(:no_mapping, _), do: "[N]"
  defp status_payload(:mapped, %{id: id}), do: "[x] #{id}"

  @spec parse(String.t()) :: [entry]
  def parse(text) do
    text
    |> String.split(~r/\r?\n\r?\n+/, trim: true)
    |> Enum.map(&parse_block/1)
  end

  defp parse_block(block) do
    [status_line, count_path_line, slug_line] =
      block |> String.split("\n", parts: 3) |> Enum.map(&String.trim_trailing/1)

    {entry_id, status, mapping} = parse_status(String.trim(status_line))
    {count, path} = parse_count_path(count_path_line)

    %{
      entry_id: entry_id,
      status: status,
      count: count,
      path: path,
      slug: String.trim(slug_line),
      mapping: mapping
    }
  end

  defp parse_status(line) do
    case Regex.run(~r/^([0-9a-f]{8})\s+(.+)$/, line) do
      [_, eid, payload] ->
        {status, mapping} = parse_payload(payload)
        {eid, status, mapping}

      _ ->
        raise ArgumentError,
              "expected `<entry-id> <status>`, got: #{inspect(line)}"
    end
  end

  defp parse_payload("[ ]"), do: {:unchecked, nil}
  defp parse_payload("[-]"), do: {:no_match, nil}
  defp parse_payload("[N]"), do: {:no_mapping, nil}

  defp parse_payload("[x] " <> id) do
    id = String.trim(id)

    if Regex.match?(~r/^[0-9a-f]{8}$/, id) do
      {:mapped, %{id: id}}
    else
      raise ArgumentError, "expected 8-char hex id after `[x]`, got: #{inspect(id)}"
    end
  end

  defp parse_payload(other),
    do: raise(ArgumentError, "unrecognized status payload: #{inspect(other)}")

  defp parse_count_path(line) do
    case Regex.run(~r/^\s*(\d+)\s+(.+)$/, line) do
      [_, n, path] -> {String.to_integer(n), path}
      _ -> raise ArgumentError, "expected '<count>  <path>', got: #{inspect(line)}"
    end
  end
end
