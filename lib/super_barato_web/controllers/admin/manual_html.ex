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
      <%!-- Headline summary --%>
      <section class="border rounded p-3">
        <div class="flex items-baseline justify-between gap-4 flex-wrap">
          <div>
            <span class={"px-2 py-0.5 rounded text-xs font-medium " <> outcome_classes(@report.outcome)}>
              {outcome_label(@report.outcome)}
            </span>
            <span class="ml-2 text-xs opacity-60">{@report.elapsed_ms} ms</span>
          </div>
          <div class="text-xs opacity-60 font-mono break-all">{@report.url}</div>
        </div>
      </section>

      <%!-- Steps --%>
      <section class="border rounded p-3">
        <h3 class="text-sm font-semibold mb-2">Pipeline</h3>
        <ol class="text-sm space-y-1">
          <%= for step <- @report.steps do %>
            <li class="flex items-baseline gap-2">
              <span class={step_dot(step.status)}>●</span>
              <span class="font-medium">{step.name}</span>
              <span class="opacity-70">— {step.detail}</span>
            </li>
          <% end %>
        </ol>
      </section>

      <%!-- Request --%>
      <section class="border rounded p-3">
        <h3 class="text-sm font-semibold mb-2">Request</h3>
        <div class="text-xs opacity-70 mb-1">profile: <code>{inspect(@report.request_profile)}</code></div>
        <table class="text-xs font-mono w-full">
          <tbody>
            <%= for {k, v} <- @report.request_headers do %>
              <tr class="align-top">
                <td class="py-0.5 pr-3 whitespace-nowrap opacity-60">{k}</td>
                <td class="py-0.5 break-all">{v}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </section>

      <%!-- Response --%>
      <section class="border rounded p-3">
        <h3 class="text-sm font-semibold mb-2">Response</h3>
        <div class="text-xs grid grid-cols-2 gap-2 mb-3">
          <div><span class="opacity-60">status:</span> <code>{inspect(@report.response_status)}</code></div>
          <div><span class="opacity-60">size:</span> <code>{format_bytes(@report.response_size)}</code></div>
          <div><span class="opacity-60">content-type:</span> <code>{@report.response_content_type || "—"}</code></div>
          <div>
            <span class="opacity-60">content-encoding:</span>
            <code>{@report.response_content_encoding || "(none — already decoded)"}</code>
          </div>
          <div class="col-span-2">
            <span class="opacity-60">body looks binary:</span>
            <span class={if(@report.body_looks_binary?, do: "text-red-700 font-medium", else: "text-green-700 font-medium")}>
              {if(@report.body_looks_binary?, do: "yes — likely encoding mismatch", else: "no — readable text")}
            </span>
          </div>
        </div>

        <details class="text-xs">
          <summary class="cursor-pointer opacity-70">Response headers</summary>
          <table class="text-xs font-mono w-full mt-2">
            <tbody>
              <%= for {k, v} <- @report.response_headers do %>
                <tr class="align-top">
                  <td class="py-0.5 pr-3 whitespace-nowrap opacity-60">{k}</td>
                  <td class="py-0.5 break-all">{v}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </details>

        <details class="text-xs mt-2" open>
          <summary class="cursor-pointer opacity-70">Body preview (first 800 bytes, escaped)</summary>
          <pre class="bg-gray-50 p-2 rounded text-xs whitespace-pre-wrap break-all mt-2">{@report.body_preview || "(empty)"}</pre>
        </details>
      </section>

      <%!-- JSON-LD blocks --%>
      <%= if @report.ld_block_count != nil do %>
        <section class="border rounded p-3">
          <h3 class="text-sm font-semibold mb-2">JSON-LD blocks: {@report.ld_block_count}</h3>

          <%= if @report.ld_blocks == [] do %>
            <p class="text-sm opacity-70">No <code>&lt;script type="application/ld+json"&gt;</code> blocks found in the body.</p>
          <% end %>

          <%= for {block, idx} <- Enum.with_index(@report.ld_blocks) do %>
            <details class="text-xs mb-2">
              <summary class="cursor-pointer">
                <span class={step_dot(block.status)}>●</span>
                <span class="font-medium">block {idx}</span>
                <span class="opacity-70 ml-1">— {block.summary}</span>
                <%= if block.types != [] do %>
                  <span class="opacity-60 ml-1">[{Enum.join(block.types, ", ")}]</span>
                <% end %>
              </summary>
              <pre class="bg-gray-50 p-2 rounded text-xs whitespace-pre-wrap break-all mt-2">{block.raw_preview}</pre>
            </details>
          <% end %>
        </section>
      <% end %>

      <%!-- Final listing --%>
      <%= if @report.listing do %>
        <section class="border border-green-300 bg-green-50 rounded p-3">
          <h3 class="text-sm font-semibold mb-2">Parsed Listing</h3>
          <table class="text-sm">
            <tbody>
              <%= for {k, v} <- listing_pairs(@report.listing) do %>
                <tr class="align-top">
                  <td class="pr-3 py-0.5 opacity-60">{k}</td>
                  <td class="py-0.5 font-mono">{v}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </section>
      <% end %>
    </div>
    """
  end

  ## Helpers

  defp outcome_label({:ok, _}), do: "OK"
  defp outcome_label({:error, :stale_pdp}), do: "stale PDP (skipped)"
  defp outcome_label({:error, :no_product_jsonld}), do: "no Product JSON-LD"
  defp outcome_label({:error, reason}), do: "error: #{inspect(reason)}"
  defp outcome_label(:blocked), do: "blocked"
  defp outcome_label(:no_parser), do: "fetched (no parser for this chain)"
  defp outcome_label(other), do: inspect(other)

  defp outcome_classes({:ok, _}), do: "bg-green-100 text-green-800"
  defp outcome_classes({:error, :stale_pdp}), do: "bg-yellow-100 text-yellow-800"
  defp outcome_classes(:blocked), do: "bg-red-100 text-red-800"
  defp outcome_classes({:error, _}), do: "bg-red-100 text-red-800"
  defp outcome_classes(_), do: "bg-gray-100 text-gray-800"

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
