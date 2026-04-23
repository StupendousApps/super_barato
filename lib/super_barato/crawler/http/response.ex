defmodule SuperBarato.Crawler.Http.Response do
  @moduledoc "Response returned by `SuperBarato.Crawler.Http`."

  @enforce_keys [:status]
  defstruct status: 0, headers: [], body: ""

  @type header :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: [header()],
          body: binary()
        }

  @doc """
  Returns all values for `name` (lower-cased). Multiple `Set-Cookie`
  headers, for example, come back as a list.
  """
  def get_header(%__MODULE__{headers: headers}, name) when is_binary(name) do
    name = String.downcase(name)
    for {k, v} <- headers, k == name, do: v
  end
end
