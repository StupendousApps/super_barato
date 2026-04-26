defmodule SuperBarato.Crawler.Schedule do
  @moduledoc """
  A persisted crawler schedule — what Chain.Cron loads at boot instead
  of reading from `config/config.exs`.

  Each row defines a weekly cadence: fire `{kind}` for `{chain}` on
  every (day × time) combination. Two `kind`s are supported today:

    * `"discover_categories"` — pushes a one-shot category-walk task
      onto the chain's Queue.
    * `"discover_products"` — runs the `ProductProducer` that streams
      leaf-category slugs onto the Queue.

  `to_cron_entry/1` returns the `{cadence, mfa}` tuple expected by
  `Chain.Cron`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SuperBarato.Crawler

  @kinds ~w(discover_categories discover_products)
  @days ~w(mon tue wed thu fri sat sun)

  schema "crawler_schedules" do
    field :chain, :string
    field :kind, :string
    field :days, :string
    field :times, :string
    field :active, :boolean, default: true
    field :note, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Known kinds. Matches the enum the admin UI will render."
  def kinds, do: @kinds

  @doc "Known day abbreviations in week order."
  def days, do: @days

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:chain, :kind, :days, :times, :active, :note])
    |> validate_required([:chain, :kind, :days, :times])
    |> validate_inclusion(:kind, @kinds)
    |> validate_chain()
    |> validate_days()
    |> validate_times()
    |> unique_constraint([:chain, :kind])
  end

  defp validate_chain(changeset) do
    known = Crawler.known_chains() |> Enum.map(&Atom.to_string/1)

    validate_inclusion(changeset, :chain, known,
      message: "must be one of: #{Enum.join(known, ", ")}"
    )
  end

  defp validate_days(changeset) do
    validate_change(changeset, :days, fn :days, s ->
      case parse_days(s) do
        {:ok, _} -> []
        {:error, bad} -> [days: "invalid day token(s): #{Enum.join(bad, ", ")}"]
      end
    end)
  end

  defp validate_times(changeset) do
    validate_change(changeset, :times, fn :times, s ->
      case parse_times(s) do
        {:ok, _} -> []
        {:error, bad} -> [times: "invalid time(s) — expected HH:MM:SS: #{Enum.join(bad, ", ")}"]
      end
    end)
  end

  @doc """
  Converts the row to the `{cadence, mfa}` tuple Chain.Cron expects.

  Inactive rows return `:skip` — callers should filter those out.
  """
  def to_cron_entry(%__MODULE__{active: false}), do: :skip

  def to_cron_entry(%__MODULE__{} = s) do
    with {:ok, day_atoms} <- parse_days(s.days),
         {:ok, times} <- parse_times(s.times) do
      cadence = {:weekly, day_atoms, times}
      {:ok, {cadence, mfa(s)}}
    end
  end

  defp mfa(%__MODULE__{chain: chain_str, kind: "discover_categories"}) do
    chain = String.to_existing_atom(chain_str)

    {SuperBarato.Crawler.Chain.Queue, :push,
     [chain, {:discover_categories, %{chain: chain, parent: nil}}]}
  end

  # Per-chain dispatch: Cencosud-owned chains (Jumbo, Santa Isabel)
  # discover products from the sitemap rather than iterating leaf
  # categories, so they need a different producer. Lider/Unimarc keep
  # the original DB-leaf-categories iteration.
  defp mfa(%__MODULE__{chain: chain_str, kind: "discover_products"}) do
    chain = String.to_existing_atom(chain_str)
    {producer_for(chain), :run, [[chain: chain]]}
  end

  defp producer_for(:jumbo), do: SuperBarato.Crawler.Cencosud.SitemapProducer
  defp producer_for(:santa_isabel), do: SuperBarato.Crawler.Cencosud.SitemapProducer
  defp producer_for(_), do: SuperBarato.Crawler.Chain.ProductProducer

  ## Parsing helpers — also used by the context for validation.

  @doc false
  def parse_days(s) when is_binary(s) do
    tokens = s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    bad = Enum.reject(tokens, &(&1 in @days))

    case {tokens, bad} do
      {[], _} -> {:error, ["(empty)"]}
      {_, []} -> {:ok, Enum.map(tokens, &String.to_atom/1)}
      {_, bad} -> {:error, bad}
    end
  end

  @doc false
  def parse_times(s) when is_binary(s) do
    tokens = s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    {ok, bad} =
      Enum.reduce(tokens, {[], []}, fn t, {good, bad} ->
        case parse_time_token(t) do
          {:ok, time} -> {[time | good], bad}
          :error -> {good, [t | bad]}
        end
      end)

    cond do
      tokens == [] -> {:error, ["(empty)"]}
      bad == [] -> {:ok, Enum.reverse(ok)}
      true -> {:error, Enum.reverse(bad)}
    end
  end

  # Accept HH:MM (what the library's <.time_picker> submits) and the
  # canonical HH:MM:SS. Auto-append seconds when missing.
  defp parse_time_token(t) do
    normalized = if String.length(t) == 5, do: t <> ":00", else: t

    case Time.from_iso8601(normalized) do
      {:ok, time} -> {:ok, time}
      {:error, _} -> :error
    end
  end

  @doc "Render `[:mon, :tue]` back to the stored `\"mon,tue\"` string."
  def days_to_string(atoms) when is_list(atoms),
    do: atoms |> Enum.map(&Atom.to_string/1) |> Enum.join(",")

  @doc "Render `[~T[04:00:00]]` back to the stored `\"04:00:00\"` string."
  def times_to_string(times) when is_list(times),
    do: times |> Enum.map(&Time.to_iso8601/1) |> Enum.join(",")
end
