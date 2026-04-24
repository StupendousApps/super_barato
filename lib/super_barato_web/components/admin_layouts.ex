defmodule SuperBaratoWeb.AdminLayouts do
  @moduledoc """
  Layouts for the /admin section. Distinct from `SuperBaratoWeb.Layouts`
  (which serves the public site) — this module's markup is paired with
  the hand-written CSS under `priv/static/assets/css/admin/`.
  """
  use SuperBaratoWeb, :html

  embed_templates "admin_layouts/*"

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="flash-group">
      <div :if={msg = Phoenix.Flash.get(@flash, :info)} class="flash flash-info">
        <p>{msg}</p>
      </div>
      <div :if={msg = Phoenix.Flash.get(@flash, :error)} class="flash flash-error">
        <p>{msg}</p>
      </div>
    </div>
    """
  end
end
