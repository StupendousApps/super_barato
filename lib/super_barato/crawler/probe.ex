defmodule SuperBarato.Crawler.Probe do
  @moduledoc """
  Synchronous, no-GenServer pipeline that runs one crawl step end-to-
  end and returns a structured report. Drives the admin "Manual" page;
  nothing else uses it.

  Inputs are a chain (`:jumbo`, `:santa_isabel`, ...), a `kind`
  (`:categories` or `:product_pdp`), and — for `:product_pdp` — a
  category to scope the URL pick. The URL itself isn't a form input:
  the probe figures it out (categories endpoint for `:categories`;
  the `pdp_url` of an existing `chain_listings` row in that category
  for `:product_pdp`). That way the operator picks intent, the system
  picks the actual URL, and the report shows both.

  Designed for human inspection in HTML, not for consumption by other
  code: every step records its inputs, outputs, and a compact preview
  of any binary so you can tell encoding garbage from missing markup
  at a glance.
  """

  import Ecto.Query

  alias SuperBarato.Catalog.{Category, ChainListing}
  alias SuperBarato.Crawler.{Cencosud, Http, Listing}
  alias SuperBarato.Repo

  defmodule Step do
    @moduledoc false
    defstruct [:name, :status, :detail]
    @type t :: %__MODULE__{name: String.t(), status: :ok | :warn | :error, detail: any()}
  end

  defmodule Report do
    @moduledoc false
    defstruct [
      :chain,
      :kind,
      :category_slug,
      :url,
      :elapsed_ms,
      :request_headers,
      :request_profile,
      :response_status,
      :response_headers,
      :response_size,
      :response_content_type,
      :response_content_encoding,
      :body_preview,
      :body_looks_binary?,
      :ld_block_count,
      :ld_blocks,
      :categories,
      :listing,
      :outcome,
      :steps
    ]
  end

  @cencosud_chains [:jumbo, :santa_isabel]

  @kinds [:categories, :product_pdp]

  def kinds, do: @kinds

  @doc """
  Lists leaf categories for `chain` formatted for a `<select>` —
  `[{label, slug}, ...]` ordered by name. Returns `[]` when the chain
  has no categories yet (e.g. categories.json hasn't been crawled).
  """
  def category_options(chain) when is_atom(chain) do
    Category
    |> where([c], c.chain == ^to_string(chain) and c.active == true)
    |> order_by([c], asc: c.name)
    |> select([c], {c.name, c.slug})
    |> Repo.all()
  end

  @doc """
  Resolves the URL the probe will hit for the given inputs. Returns
  `{:ok, url}` or `{:error, reason}`. Used by the controller to show
  the URL on the report when no actual probe runs (e.g. on validation
  errors), and internally by `run/1`.
  """
  def resolve_url(%{chain: chain, kind: :categories}) when is_atom(chain) do
    case config_for(chain) do
      %Cencosud.Config{categories_url: url} when is_binary(url) -> {:ok, url}
      _ -> {:error, :no_categories_endpoint}
    end
  end

  def resolve_url(%{chain: chain, kind: :product_pdp, category_slug: slug}) when is_binary(slug) do
    sample_pdp_url_for_category(chain, slug)
    |> with_sitemap_fallback(chain)
    |> case do
      nil -> {:error, :no_pdp_resolvable}
      url -> {:ok, url}
    end
  end

  def resolve_url(%{chain: chain, kind: :product_pdp}) when is_atom(chain) do
    sample_pdp_url_for_chain(chain)
    |> with_sitemap_fallback(chain)
    |> case do
      nil -> {:error, :no_pdp_resolvable}
      url -> {:ok, url}
    end
  end

  def resolve_url(_), do: {:error, :bad_inputs}

  @doc """
  Runs the probe end-to-end. `inputs` is a map with `:chain`, `:kind`,
  and optionally `:category_slug`. Always returns a `%Report{}`; the
  `:outcome` field tells the caller whether the run succeeded.
  """
  def run(inputs) when is_map(inputs) do
    started = System.monotonic_time(:millisecond)
    chain = inputs[:chain]
    kind = inputs[:kind]
    category_slug = inputs[:category_slug]

    case resolve_url(inputs) do
      {:ok, url} ->
        do_run(chain, kind, category_slug, url, started)

      {:error, reason} ->
        empty_report(chain, kind, category_slug, started, {:error, reason})
    end
  end

  defp do_run(chain, kind, category_slug, url, started) do
    cfg = config_for(chain)
    headers = headers_for(cfg, kind)
    profile = profile_for(cfg, chain)

    {fetch_result, fetch_step} = step_fetch(url, chain, headers, profile)

    {parse_results, post_steps} = run_parse_steps(chain, kind, cfg, fetch_result, url)

    elapsed = System.monotonic_time(:millisecond) - started

    %Report{
      chain: chain,
      kind: kind,
      category_slug: category_slug,
      url: url,
      elapsed_ms: elapsed,
      request_headers: headers,
      request_profile: profile,
      response_status: response_field(fetch_result, :status),
      response_headers: response_field(fetch_result, :headers) || [],
      response_size: response_size(fetch_result),
      response_content_type: header_value(fetch_result, "content-type"),
      response_content_encoding: header_value(fetch_result, "content-encoding"),
      body_preview: body_preview(fetch_result),
      body_looks_binary?: body_looks_binary?(fetch_result),
      ld_block_count: parse_results[:ld_block_count],
      ld_blocks: parse_results[:ld_blocks] || [],
      categories: parse_results[:categories],
      listing: parse_results[:listing],
      outcome: parse_results[:outcome] || outcome_from_fetch(fetch_result),
      steps: [fetch_step | post_steps]
    }
  end

  defp empty_report(chain, kind, category_slug, started, outcome) do
    %Report{
      chain: chain,
      kind: kind,
      category_slug: category_slug,
      url: nil,
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      request_headers: [],
      request_profile: nil,
      response_status: nil,
      response_headers: [],
      response_size: nil,
      ld_blocks: [],
      outcome: outcome,
      steps: [
        %Step{
          name: "Resolve URL",
          status: :error,
          detail: outcome_label(outcome)
        }
      ]
    }
  end

  ## Fetch step

  defp step_fetch(url, chain, headers, profile) do
    case Http.get(url, chain: chain, headers: headers, profile: profile) do
      {:ok, %Http.Response{status: status} = resp} = ok ->
        kind = if status >= 200 and status < 400, do: :ok, else: :warn

        {ok,
         %Step{
           name: "HTTP fetch",
           status: kind,
           detail: "HTTP #{status} (#{byte_size(resp.body)} bytes)"
         }}

      {:error, reason} = err ->
        {err, %Step{name: "HTTP fetch", status: :error, detail: inspect(reason)}}
    end
  end

  ## Parse stages — chain + kind specific

  # Cencosud :categories — parse the category sitemap (XML) into
  # Category structs. (categories.json retired; sitemap is the source.)
  defp run_parse_steps(chain, :categories, %Cencosud.Config{} = _cfg, {:ok, %Http.Response{status: 200, body: body}}, _url)
       when chain in @cencosud_chains do
    cats = Cencosud.parse_categories_xml(chain, body)

    {%{
       categories: cats,
       outcome: {:ok, {:categories, length(cats)}}
     },
     [
       %Step{
         name: "Cencosud.parse_categories_xml/2",
         status: :ok,
         detail: "#{length(cats)} categories (#{Enum.count(cats, & &1.is_leaf)} leaves)"
       }
     ]}
  end

  # Cencosud :product_pdp — extract JSON-LD blocks, parse Product node.
  defp run_parse_steps(chain, :product_pdp, %Cencosud.Config{} = cfg, {:ok, %Http.Response{status: 200, body: body}}, url)
       when chain in @cencosud_chains do
    blocks = extract_ld_blocks(body)

    extract_step = %Step{
      name: "Extract <script type=\"application/ld+json\">",
      status: if(blocks == [], do: :error, else: :ok),
      detail: "#{length(blocks)} block(s)"
    }

    decoded = decode_blocks(blocks)

    decode_step = %Step{
      name: "Decode JSON-LD",
      status: status_for_decoded(decoded),
      detail:
        "#{Enum.count(decoded, &match?({:ok, _, _}, &1))} OK / #{Enum.count(decoded, &match?({:error, _, _}, &1))} failed"
    }

    parse_outcome = Cencosud.parse_pdp(cfg, body, url)

    parse_step = %Step{
      name: "Cencosud.parse_pdp/3",
      status: parse_status(parse_outcome),
      detail: parse_detail(parse_outcome)
    }

    listing =
      case parse_outcome do
        {:ok, %Listing{} = l} -> l
        _ -> nil
      end

    {
      %{
        ld_block_count: length(blocks),
        ld_blocks: format_blocks_for_view(decoded),
        listing: listing,
        outcome: parse_outcome
      },
      [extract_step, decode_step, parse_step]
    }
  end

  # Non-200 response or transport error: nothing to parse.
  defp run_parse_steps(_chain, _kind, _cfg, {:ok, %Http.Response{status: status}}, _url)
       when status != 200 do
    {%{outcome: {:error, {:http_status, status}}}, []}
  end

  defp run_parse_steps(_chain, _kind, _cfg, {:error, reason}, _url) do
    {%{outcome: {:error, reason}}, []}
  end

  defp run_parse_steps(_chain, _kind, _cfg, _resp, _url) do
    {%{outcome: :no_parser},
     [
       %Step{
         name: "Adapter parser",
         status: :warn,
         detail: "no chain-specific parser wired into the probe yet — showing raw response only"
       }
     ]}
  end

  ## JSON-LD helpers (mirror Cencosud.parse_pdp internals)

  defp extract_ld_blocks(html) when is_binary(html) do
    Regex.scan(
      ~r{<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>}s,
      html,
      capture: :all_but_first
    )
    |> Enum.map(fn [b] -> b end)
  end

  defp extract_ld_blocks(_), do: []

  defp decode_blocks(blocks) do
    Enum.map(blocks, fn raw ->
      trimmed = String.trim(raw)

      case Jason.decode(trimmed) do
        {:ok, decoded} -> {:ok, trimmed, decoded}
        {:error, %Jason.DecodeError{} = err} -> {:error, trimmed, Exception.message(err)}
        {:error, other} -> {:error, trimmed, inspect(other)}
      end
    end)
  end

  defp status_for_decoded([]), do: :error

  defp status_for_decoded(decoded) do
    if Enum.all?(decoded, &match?({:ok, _, _}, &1)), do: :ok, else: :warn
  end

  defp format_blocks_for_view(decoded) do
    Enum.map(decoded, fn
      {:ok, _raw, decoded} ->
        %{
          status: :ok,
          pretty: Jason.encode!(decoded, pretty: true),
          summary: ld_block_summary(decoded),
          types: ld_block_types(decoded)
        }

      {:error, raw, msg} ->
        %{
          status: :error,
          pretty: String.slice(raw, 0, 800),
          summary: msg,
          types: []
        }
    end)
  end

  defp ld_block_summary(%{"@graph" => graph}) when is_list(graph),
    do: "@graph with #{length(graph)} entries"

  defp ld_block_summary(%{"@type" => t}) when is_binary(t), do: "single node @type=#{t}"
  defp ld_block_summary(%{} = m), do: "object with keys: #{m |> Map.keys() |> Enum.join(", ")}"
  defp ld_block_summary(list) when is_list(list), do: "top-level array of #{length(list)}"
  defp ld_block_summary(_), do: "(unrecognized shape)"

  defp ld_block_types(%{"@graph" => graph}) when is_list(graph) do
    graph
    |> List.flatten()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.get(&1, "@type"))
    |> Enum.reject(&is_nil/1)
  end

  defp ld_block_types(%{"@type" => t}) when is_binary(t), do: [t]
  defp ld_block_types(_), do: []

  defp parse_status({:ok, _}), do: :ok
  defp parse_status({:error, :stale_pdp}), do: :warn
  defp parse_status({:error, _}), do: :error
  defp parse_status(_), do: :error

  defp parse_detail({:ok, %Listing{name: name, regular_price: price}}),
    do: "OK — #{name || "(no name)"} @ #{price || "?"} CLP"

  defp parse_detail({:error, reason}), do: "error: #{inspect(reason)}"
  defp parse_detail(other), do: inspect(other)

  ## Body inspection helpers

  defp body_preview({:ok, %Http.Response{body: body}}), do: hex_ascii_preview(body, 800)
  defp body_preview(_), do: nil

  defp body_looks_binary?({:ok, %Http.Response{body: body}}) do
    sample = binary_part(body, 0, min(byte_size(body), 256))

    non_printable =
      sample
      |> :binary.bin_to_list()
      |> Enum.count(fn b -> not (b in 9..13 or b in 32..126) end)

    byte_size(sample) > 0 and non_printable / byte_size(sample) > 0.15
  end

  defp body_looks_binary?(_), do: false

  defp hex_ascii_preview(<<>>, _), do: ""

  defp hex_ascii_preview(body, max) when is_binary(body) do
    body
    |> binary_part(0, min(byte_size(body), max))
    |> :binary.bin_to_list()
    |> Enum.map(fn
      b when b in 32..126 -> <<b>>
      9 -> "\\t"
      10 -> "\\n"
      13 -> "\\r"
      b -> "\\x#{Integer.to_string(b, 16) |> String.pad_leading(2, "0")}"
    end)
    |> IO.iodata_to_binary()
  end

  ## URL resolution: pick a real PDP from the DB for a given category.
  #
  # `chain_listings.category_path` stores the breadcrumb trail as a
  # stringified " > "-joined name path (e.g. "Carnes y Pescados >
  # Vacuno > Carnes de Uso Diario"), while `categories.slug` is the
  # URL-style id we offer in the dropdown. We bridge them by looking
  # up the selected category's name and matching listings whose path
  # contains it. Fuzzy by design — it's a debugging helper, not a
  # query system.
  defp sample_pdp_url_for_category(chain, slug) do
    chain_str = to_string(chain)

    name =
      Category
      |> where([c], c.chain == ^chain_str and c.slug == ^slug)
      |> select([c], c.name)
      |> Repo.one()

    case name do
      nil ->
        sample_pdp_url_for_chain(chain)

      n ->
        # SQLite doesn't support ilike; LIKE is case-insensitive for
        # ASCII out of the box, which is fine for this fuzzy match.
        pattern = "%" <> n <> "%"

        ChainListing
        |> where(
          [l],
          l.chain == ^chain_str and l.active == true and not is_nil(l.pdp_url) and
            like(l.category_path, ^pattern)
        )
        |> order_by([l], asc: l.id)
        |> limit(1)
        |> select([l], l.pdp_url)
        |> Repo.one() || sample_pdp_url_for_chain(chain)
    end
  end

  defp sample_pdp_url_for_chain(chain) do
    ChainListing
    |> where([l], l.chain == ^to_string(chain) and l.active == true and not is_nil(l.pdp_url))
    |> order_by([l], asc: l.id)
    |> limit(1)
    |> select([l], l.pdp_url)
    |> Repo.one()
  end

  # When the DB has no chain_listings yet, fall back to the first
  # canonical PDP URL from the sitemap. Filter to URLs ending in `/p`
  # — Cencosud's sitemap also lists brand and category landing pages,
  # which don't carry Product JSON-LD and would mislead the probe.
  defp with_sitemap_fallback(nil, chain) do
    case config_for(chain) do
      %Cencosud.Config{} = cfg -> first_pdp_from_sitemap(cfg)
      _ -> nil
    end
  end

  defp with_sitemap_fallback(url, _chain), do: url

  defp first_pdp_from_sitemap(%Cencosud.Config{} = cfg) do
    case Cencosud.list_sitemap_urls(cfg) do
      {:ok, urls} -> Enum.find(urls, &String.ends_with?(&1, "/p"))
      _ -> nil
    end
  end

  ## Adapter config / lookup

  defp config_for(:jumbo), do: SuperBarato.Crawler.Jumbo.cencosud_config()
  defp config_for(:santa_isabel), do: SuperBarato.Crawler.SantaIsabel.cencosud_config()
  defp config_for(_), do: nil

  defp headers_for(%Cencosud.Config{} = cfg, :categories) do
    [
      {"accept", "application/json,*/*;q=0.8"},
      {"accept-language", "es-CL,es;q=0.9,en;q=0.8"},
      {"accept-encoding", "gzip, deflate, br"},
      {"referer", cfg.site_url <> "/"}
    ]
  end

  defp headers_for(%Cencosud.Config{} = cfg, :product_pdp), do: Cencosud.pdp_headers(cfg)
  defp headers_for(_, _), do: []

  defp profile_for(%Cencosud.Config{} = cfg, chain) do
    SuperBarato.Crawler.Session.get(chain, :profile) || cfg.profile || :chrome116
  end

  defp profile_for(_, _), do: :chrome116

  ## Response field extraction

  defp response_field({:ok, %Http.Response{} = r}, :status), do: r.status
  defp response_field({:ok, %Http.Response{} = r}, :headers), do: r.headers
  defp response_field(_, _), do: nil

  defp response_size({:ok, %Http.Response{body: body}}), do: byte_size(body)
  defp response_size(_), do: nil

  defp header_value({:ok, %Http.Response{headers: headers}}, key) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == key, do: v
    end)
  end

  defp header_value(_, _), do: nil

  defp outcome_from_fetch({:ok, _}), do: :no_parser
  defp outcome_from_fetch({:error, reason}), do: {:error, reason}

  defp outcome_label({:error, :no_categories_endpoint}),
    do: "this chain doesn't have a categories endpoint configured"

  defp outcome_label({:error, :no_pdp_resolvable}),
    do: "couldn't resolve a PDP URL — no DB listings and sitemap fetch failed"

  defp outcome_label({:error, reason}), do: "error: #{inspect(reason)}"
  defp outcome_label(other), do: inspect(other)
end
