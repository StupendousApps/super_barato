# SQLite only allows one writer at a time, so running test modules
# concurrently hits SQLITE_BUSY. max_cases: 1 serialises the suite —
# runtime is still fine (~8s total), and it avoids per-file async: false.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(SuperBarato.Repo, :manual)

# Shared test-only supervision: crawler Registry for per-chain named
# processes, plus the StubAdapter agent for Worker/Results/integration
# tests. Keep these here so every test file doesn't have to bootstrap them.
case Registry.start_link(keys: :unique, name: SuperBarato.Crawler.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

{:ok, _} = SuperBarato.Test.StubAdapter.start_link()
