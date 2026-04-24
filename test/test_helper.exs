ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(SuperBarato.Repo, :manual)

# Shared test-only supervision: crawler Registry for per-chain named
# processes, plus the StubAdapter agent for Worker/Results/integration
# tests. Keep these here so every test file doesn't have to bootstrap them.
case Registry.start_link(keys: :unique, name: SuperBarato.Crawler.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

{:ok, _} = SuperBarato.Test.StubAdapter.start_link()
