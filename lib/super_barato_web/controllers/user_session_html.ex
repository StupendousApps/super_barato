defmodule SuperBaratoWeb.UserSessionHTML do
  use SuperBaratoWeb, :html
  import SuperBaratoWeb.CoreComponents

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:super_barato, SuperBarato.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
