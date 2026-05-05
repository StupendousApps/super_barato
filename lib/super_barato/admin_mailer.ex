defmodule SuperBarato.AdminMailer do
  @moduledoc """
  Glue between `StupendousAdmin.Notifications` and `SuperBarato.Mailer`
  (Swoosh + SendGrid in prod, the local in-memory adapter in dev/test).

  Two entry points:

    * `send_notification/2` — fires per `:critical` event the moment
      `Notifications.notify/5` accepts it. Wired via the library's
      `:notification_mailer` MFA config.

    * `send_digest/2` — sends a single email summarizing every
      `:warning` / `:error` notification not yet rolled into a
      digest. The caller is responsible for picking the timing
      (cron, oban, mix task, etc.) and calling
      `Notifications.mark_digest_delivered/1` once the send returns
      `{:ok, _}`.

  Both functions accept the recipient list as their second argument
  so the library doesn't have to know about super_barato's mailer
  configuration.
  """

  import Swoosh.Email

  alias StupendousAdmin.Notifications.AdminNotification
  alias SuperBarato.Mailer

  @doc """
  Send a single critical-severity notification. Returns the result
  of `Mailer.deliver/1` directly; the library's wrapper logs and
  swallows failures so the calling site never crashes on a flaky
  SendGrid round-trip.
  """
  @spec send_notification(AdminNotification.t(), [String.t()]) ::
          {:ok, term()} | {:error, term()}
  def send_notification(%AdminNotification{} = notification, recipients)
      when is_list(recipients) and recipients != [] do
    body = critical_body(notification)

    new()
    |> from(mail_from())
    |> to(Enum.map(recipients, &{nil, &1}))
    |> subject("[super_barato · CRITICAL] #{notification.title}")
    |> text_body(body)
    |> Mailer.deliver()
  end

  def send_notification(_, []), do: {:ok, :no_recipients}

  @doc """
  Send a digest email summarizing `notifications`. Caller marks
  them as delivered (`Notifications.mark_digest_delivered/1`) on
  `{:ok, _}`.
  """
  @spec send_digest([AdminNotification.t()], [String.t()]) ::
          {:ok, term()} | {:error, term()}
  def send_digest([], _recipients), do: {:ok, :nothing_to_send}
  def send_digest(_notifications, []), do: {:ok, :no_recipients}

  def send_digest(notifications, recipients) do
    body = digest_body(notifications)
    count = length(notifications)

    new()
    |> from(mail_from())
    |> to(Enum.map(recipients, &{nil, &1}))
    |> subject("[super_barato] Daily digest · #{count} #{pluralize("issue", count)}")
    |> text_body(body)
    |> Mailer.deliver()
  end

  ## ── Internals ───────────────────────────────────────────────

  defp mail_from do
    Application.get_env(:super_barato, :mail_from, {"Super Barato", "hola@superbarato.cl"})
  end

  defp critical_body(%AdminNotification{} = n) do
    """
    #{n.title}

    Source:    #{n.source}
    Severity:  #{n.severity}
    Posted at: #{n.inserted_at}

    #{n.body || "(no body)"}

    #{format_context(n.context)}

    Open the admin notifications inbox to mark this read.
    """
  end

  defp digest_body(notifications) do
    by_severity = Enum.group_by(notifications, & &1.severity)

    sections =
      [:error, :warning]
      |> Enum.map(fn severity ->
        rows = Map.get(by_severity, severity, [])

        case rows do
          [] ->
            nil

          _ ->
            header = "## #{String.upcase(to_string(severity))} (#{length(rows)})"
            entries = Enum.map_join(rows, "\n", &"  - [#{&1.source}] #{&1.title}")
            header <> "\n" <> entries
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    sections <> "\n\nOpen the admin notifications inbox for details.\n"
  end

  defp format_context(ctx) when is_map(ctx) and map_size(ctx) > 0 do
    "Context:\n" <>
      (ctx
       |> Enum.map_join("\n", fn {k, v} -> "  #{k}: #{inspect(v)}" end))
  end

  defp format_context(_), do: ""

  defp pluralize(word, 1), do: word
  defp pluralize(word, _), do: word <> "s"
end
