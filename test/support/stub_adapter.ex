defmodule SuperBarato.Test.StubAdapter do
  @moduledoc """
  Test-only `Crawler.Chain` implementation. Responses are configured per
  test via `set_response/3` (keyed by chain + task tag). Also records
  received tasks for assertion.

  Backed by an Agent started in `setup` so each test can program its own
  responses without cross-test contamination — use distinct chain atoms.
  """

  @behaviour SuperBarato.Crawler.Chain

  use Agent

  # Start the agent once for the test run; state is a two-level map
  # %{chain => %{task_tag => response}} plus %{chain => [received_tasks]}.
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{responses: %{}, received: %{}} end, name: __MODULE__)
  end

  @doc "Sets the response for a given chain + task tag."
  def set_response(chain, task_tag, response) do
    Agent.update(__MODULE__, fn s ->
      put_in(s, [:responses, Access.key(chain, %{}), task_tag], response)
    end)
  end

  @doc "Returns tasks received by the stub for a chain, in order."
  def received(chain) do
    Agent.get(__MODULE__, fn s -> get_in(s, [:received, chain]) || [] end)
  end

  @doc "Clears state for a specific chain. Use in setup."
  def reset(chain) do
    Agent.update(__MODULE__, fn s ->
      s
      |> update_in([:responses], &Map.delete(&1, chain))
      |> update_in([:received], &Map.delete(&1, chain))
    end)
  end

  # Chain behaviour

  @impl true
  def id, do: :stub

  @impl true
  def refresh_identifier, do: :ean

  @impl true
  def handle_task(task) do
    {chain, tag} = chain_and_tag(task)

    Agent.update(__MODULE__, fn s ->
      update_in(s, [:received, Access.key(chain, [])], fn list -> (list || []) ++ [task] end)
    end)

    case Agent.get(__MODULE__, fn s -> get_in(s, [:responses, chain, tag]) end) do
      nil -> {:error, {:no_stub_configured, chain, tag}}
      fun when is_function(fun, 1) -> fun.(task)
      resp -> resp
    end
  end

  defp chain_and_tag({tag, %{chain: chain}}), do: {chain, tag}
  defp chain_and_tag({tag, _}), do: {nil, tag}
end
