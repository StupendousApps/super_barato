defmodule SuperBarato.Fixtures do
  @moduledoc """
  Loads raw API/page fixtures captured from real chains.
  Tests use these as deterministic inputs for parsers.
  """

  @root Path.expand("fixtures", __DIR__)

  @doc "Reads a fixture file as a binary."
  def read!(chain, name) when is_atom(chain) do
    @root
    |> Path.join(Atom.to_string(chain))
    |> Path.join(name)
    |> File.read!()
  end

  @doc "Reads + Jason.decodes a JSON fixture."
  def json!(chain, name) do
    chain |> read!(name) |> Jason.decode!()
  end
end
