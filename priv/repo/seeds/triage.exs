#!/usr/bin/env elixir
# Triage primitives — driven by the LLM, one chain entry at a time.
#
#   elixir priv/repo/seeds/triage.exs next <chain>
#       Prints the first [ ] block: count + path + slug.
#       Exits with the empty string and code 0 once a chain is done.
#
#   elixir priv/repo/seeds/triage.exs search <keyword> [<keyword>...]
#       Greps categories.jsonl for records that match ALL keywords
#       (case-insensitive, accent-stripped). Prints id + kind + path
#       + keywords for each hit, sorted by kind then path.
#
#   elixir priv/repo/seeds/triage.exs mark <chain> <slug> <id|-|N>
#       Rewrites the status line of the entry with the given slug.
#       <id> = 8-char hex (writes "[x]: <id>")
#       -    = "[-]"   (no fit)
#       N    = "[N]"   (no 1:1 mapping)
#
# Plain elixir — no mix boot, no Repo. State lives entirely in
# priv/repo/seeds/categories/*.txt and priv/repo/seeds/categories.jsonl.

defmodule Triage do
  @root Path.expand(Path.join([__DIR__]))
  @categories_dir Path.join(@root, "categories")
  @jsonl_path Path.join(@root, "categories.jsonl")

  def main(["next", chain]) do
    chain_path = Path.join(@categories_dir, "#{chain}.txt")

    case File.read(chain_path) do
      {:ok, body} ->
        case first_unchecked(body) do
          nil ->
            IO.puts("DONE — no [ ] entries left in #{chain}")

          %{count: c, path: p, slug: s} ->
            IO.puts("count: #{c}")
            IO.puts("path:  #{p}")
            IO.puts("slug:  #{s}")
        end

      {:error, reason} ->
        IO.puts(:stderr, "error reading #{chain_path}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def main(["search" | keywords]) when keywords != [] do
    needles = Enum.map(keywords, &normalize/1)

    @jsonl_path
    |> File.stream!()
    |> Stream.map(&Jason.decode!/1)
    |> Stream.filter(fn r ->
      hay = haystack(r)
      Enum.all?(needles, &String.contains?(hay, &1))
    end)
    |> Enum.sort_by(fn r -> {r["kind"], r["path"]} end)
    |> Enum.each(fn r ->
      kw = (r["keywords"] || []) |> Enum.join(", ")
      kw_part = if kw == "", do: "", else: "  [#{kw}]"
      IO.puts("#{r["id"]}  #{r["kind"]}  #{r["path"]}#{kw_part}")
    end)
  end

  def main(["mark", chain, slug, status]) do
    chain_path = Path.join(@categories_dir, "#{chain}.txt")
    body = File.read!(chain_path)
    blocks = String.split(body, "\n\n", trim: true)

    new_status =
      cond do
        status == "-" -> "[-]"
        status == "N" -> "[N]"
        Regex.match?(~r/^[0-9a-f]{8}$/, status) -> "[x]: #{status}"
        true -> raise "status must be <id> (8 hex), '-' or 'N'; got #{inspect(status)}"
      end

    {new_blocks, found} =
      Enum.map_reduce(blocks, false, fn block, found ->
        case String.split(block, "\n", parts: 3) do
          [_status, count_path, ^slug] ->
            {Enum.join([new_status, count_path, slug], "\n"), true}

          _ ->
            {block, found}
        end
      end)

    if found do
      File.write!(chain_path, Enum.join(new_blocks, "\n\n") <> "\n")
      IO.puts("marked #{chain}/#{slug} as #{new_status}")
    else
      IO.puts(:stderr, "no entry with slug #{inspect(slug)} in #{chain}")
      System.halt(1)
    end
  end

  def main(_args) do
    IO.puts(:stderr, """
    usage:
      triage.exs next <chain>
      triage.exs search <keyword> [<keyword>...]
      triage.exs mark <chain> <slug> <id|-|N>
    """)

    System.halt(1)
  end

  # --- helpers ---

  defp first_unchecked(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.find_value(fn block ->
      case String.split(block, "\n", parts: 3) do
        ["[ ]", count_path, slug] ->
          case Regex.run(~r/^\s*(\d+)\s+(.+)$/, count_path) do
            [_, n, p] -> %{count: String.to_integer(n), path: p, slug: slug}
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp normalize(s) do
    s
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end

  defp haystack(record) do
    parts = [
      record["name"],
      record["path"],
      record["slug"],
      record["category_name"],
      record["category_slug"],
      Enum.join(record["keywords"] || [], " ")
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> normalize()
  end
end

Mix.install([{:jason, "~> 1.0"}])

Triage.main(System.argv())
