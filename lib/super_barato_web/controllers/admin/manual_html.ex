defmodule SuperBaratoWeb.Admin.ManualHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin

  alias SuperBaratoWeb.Admin.ListingHTML

  embed_templates "manual_html/*"

  defdelegate chain_label(chain), to: ListingHTML

  attr :report, :any, required: true

  def report_view(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- Outcome --%>
      <.key_value>
        <:row label="Outcome" color={outcome_color(@report.outcome)}>
          {outcome_label(@report.outcome)}
        </:row>
        <:row label="Elapsed">{@report.elapsed_ms} ms</:row>
        <:row label="URL">
          <%= if @report.url do %>
            <code class="break-all">{@report.url}</code>
          <% else %>
            <span class="opacity-60">(unresolved)</span>
          <% end %>
        </:row>
      </.key_value>

      <%!-- Pipeline steps --%>
      <h3 class="text-sm font-semibold mt-4">Pipeline</h3>
      <.key_value>
        <:row :for={s <- @report.steps} label={s.name} color={step_color(s.status)}>
          {s.detail}
        </:row>
      </.key_value>

      <%!-- Request / response only render when a fetch actually happened. --%>
      <%= if @report.response_status do %>
        <h3 class="text-sm font-semibold mt-4">Request</h3>
        <.key_value>
          <:row label="profile">{inspect(@report.request_profile)}</:row>
          <:row :for={{k, v} <- @report.request_headers} label={k}>
            <code class="break-all">{v}</code>
          </:row>
        </.key_value>

        <h3 class="text-sm font-semibold mt-4">Response</h3>
        <.key_value>
          <:row label="status">
            <code>{inspect(@report.response_status)}</code>
          </:row>
          <:row label="size">{format_bytes(@report.response_size)}</:row>
          <:row label="content-type">
            <code>{@report.response_content_type || "—"}</code>
          </:row>
          <:row label="content-encoding">
            <code>{@report.response_content_encoding || "(none — already decoded)"}</code>
          </:row>
          <:row label="body looks binary?" color={if @report.body_looks_binary?, do: :red, else: :green}>
            {if @report.body_looks_binary?, do: "yes — likely encoding mismatch", else: "no — readable text"}
          </:row>
        </.key_value>

        <details class="mt-2">
          <summary class="text-xs cursor-pointer opacity-70">Response headers ({length(@report.response_headers)})</summary>
          <.key_value>
            <:row :for={{k, v} <- @report.response_headers} label={k}>
              <code class="break-all">{v}</code>
            </:row>
          </.key_value>
        </details>

        <details class="mt-2" open>
          <summary class="text-xs cursor-pointer opacity-70">Body preview (first 800 bytes, non-printables escaped)</summary>
          <pre class="bg-gray-50 dark:bg-gray-900 p-2 rounded text-xs whitespace-pre-wrap break-all mt-2">{@report.body_preview || "(empty)"}</pre>
        </details>
      <% end %>

      <%!-- JSON-LD blocks --%>
      <%= if @report.ld_block_count != nil do %>
        <h3 class="text-sm font-semibold mt-4">JSON-LD blocks ({@report.ld_block_count})</h3>

        <%= if @report.ld_blocks == [] do %>
          <p class="text-sm opacity-70">
            No <code>&lt;script type="application/ld+json"&gt;</code> blocks found in the body.
          </p>
        <% end %>

        <%= for {block, idx} <- Enum.with_index(@report.ld_blocks) do %>
          <details class="mb-2" open={block.status == :ok and idx < 2}>
            <summary class="cursor-pointer text-sm">
              <span class={step_dot(block.status)}>●</span>
              <span class="font-medium">block {idx}</span>
              <span class="opacity-70 ml-1">— {block.summary}</span>
              <%= if block.types != [] do %>
                <span class="opacity-60 ml-1">[{Enum.join(block.types, ", ")}]</span>
              <% end %>
            </summary>
            <pre class="bg-gray-50 dark:bg-gray-900 p-2 rounded text-xs whitespace-pre-wrap break-all mt-2">{block.pretty}</pre>
          </details>
        <% end %>
      <% end %>

      <%!-- Final listing --%>
      <%= if @report.listing do %>
        <h3 class="text-sm font-semibold mt-4">Parsed Listing</h3>
        <.key_value>
          <:row :for={{k, v} <- listing_pairs(@report.listing)} label={k}>
            <code class="break-all">{v}</code>
          </:row>
        </.key_value>
      <% end %>

      <%!-- Categories list (when kind=:categories) --%>
      <%= if @report.categories do %>
        <h3 class="text-sm font-semibold mt-4">
          Categories parsed ({length(@report.categories)})
        </h3>
        <.table rows={@report.categories} empty="No categories.">
          <:col :let={c} label="Name">{c.name}</:col>
          <:col :let={c} label="Slug">
            <code class="break-all">{c.slug}</code>
          </:col>
          <:col :let={c} label="Parent">
            <code class="break-all opacity-70">{c.parent_slug || "—"}</code>
          </:col>
          <:col :let={c} label="Level" align={:right}>{c.level}</:col>
          <:col :let={c} label="Leaf?" align={:center}>{c.is_leaf && "✓"}</:col>
        </.table>
      <% end %>
    </div>
    """
  end

  ## Helpers

  defp outcome_label({:ok, {:categories, n}}), do: "OK — #{n} categories"
  defp outcome_label({:ok, _}), do: "OK"
  defp outcome_label({:error, :stale_pdp}), do: "stale PDP (skipped)"
  defp outcome_label({:error, :no_product_jsonld}), do: "no Product JSON-LD"
  defp outcome_label({:error, {:no_product_jsonld, _diag}}), do: "no Product JSON-LD"
  defp outcome_label({:error, reason}), do: "error: #{inspect(reason)}"
  defp outcome_label(:blocked), do: "blocked"
  defp outcome_label(:no_parser), do: "fetched (no parser for this chain)"
  defp outcome_label(other), do: inspect(other)

  defp outcome_color({:ok, _}), do: :green
  defp outcome_color({:error, :stale_pdp}), do: :yellow
  defp outcome_color(:blocked), do: :red
  defp outcome_color({:error, _}), do: :red
  defp outcome_color(_), do: :regular

  defp step_color(:ok), do: :green
  defp step_color(:warn), do: :yellow
  defp step_color(:error), do: :red
  defp step_color(_), do: :regular

  defp step_dot(:ok), do: "text-green-600"
  defp step_dot(:warn), do: "text-yellow-600"
  defp step_dot(:error), do: "text-red-600"
  defp step_dot(_), do: "text-gray-400"

  defp format_bytes(nil), do: "—"

  defp format_bytes(n) when is_integer(n) do
    cond do
      n < 1024 -> "#{n} B"
      n < 1024 * 1024 -> "#{Float.round(n / 1024, 1)} KB"
      true -> "#{Float.round(n / 1024 / 1024, 2)} MB"
    end
  end

  defp listing_pairs(%SuperBarato.Crawler.Listing{} = l) do
    [
      {"chain", inspect(l.chain)},
      {"name", l.name || "—"},
      {"chain_sku", l.chain_sku || "—"},
      {"chain_product_id", l.chain_product_id || "—"},
      {"ean", l.ean || "—"},
      {"brand", l.brand || "—"},
      {"regular_price", l.regular_price || "—"},
      {"promo_price", l.promo_price || "—"},
      {"category_path", l.category_path || "—"},
      {"image_url", l.image_url || "—"},
      {"pdp_url", l.pdp_url || "—"}
    ]
  end
end
