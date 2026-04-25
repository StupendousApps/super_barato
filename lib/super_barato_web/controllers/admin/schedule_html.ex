defmodule SuperBaratoWeb.Admin.ScheduleHTML do
  use SuperBaratoWeb, :html

  alias SuperBarato.Crawler
  alias SuperBaratoWeb.Admin.ListingHTML

  embed_templates "schedule_html/*"

  defdelegate chain_label(chain), to: ListingHTML
  defdelegate format_datetime(dt), to: ListingHTML

  @doc "Known chain options for the <select>."
  def chain_options do
    Crawler.known_chains()
    |> Enum.map(fn chain -> {ListingHTML.chain_label(chain), Atom.to_string(chain)} end)
  end

  @doc "Known kind options for the <select>."
  def kind_options do
    [
      {"Discover categories", "discover_categories"},
      {"Discover products", "discover_products"}
    ]
  end

  def kind_label("discover_categories"), do: "Discover categories"
  def kind_label("discover_products"), do: "Discover products"
  def kind_label(other), do: other

  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true

  def schedule_form(assigns) do
    assigns = assign(assigns, :form, to_form(assigns.changeset, as: :schedule))

    ~H"""
    <.form for={@form} action={@action} class="form">
      <div :if={!@form.source.valid? && @form.source.action} class="form-errors">
        <p class="form-errors-title">Fix the errors below.</p>
      </div>

      <div class="fieldset">
        <label class="label">
          <span class="label-text">Chain</span>
          <select name={@form[:chain].name} class="input">
            <option value="">—</option>
            <option
              :for={{label, value} <- chain_options()}
              value={value}
              selected={@form[:chain].value == value}
            >
              {label}
            </option>
          </select>
        </label>
        <p :for={msg <- error_messages(@form[:chain])} class="input-error">{msg}</p>
      </div>

      <div class="fieldset">
        <label class="label">
          <span class="label-text">Kind</span>
          <select name={@form[:kind].name} class="input">
            <option value="">—</option>
            <option
              :for={{label, value} <- kind_options()}
              value={value}
              selected={@form[:kind].value == value}
            >
              {label}
            </option>
          </select>
        </label>
        <p :for={msg <- error_messages(@form[:kind])} class="input-error">{msg}</p>
      </div>

      <div class="fieldset">
        <label class="label">
          <span class="label-text">Days</span>
          <input
            type="text"
            name={@form[:days].name}
            value={@form[:days].value}
            class="input"
            placeholder="mon,tue,wed,thu,fri,sat,sun"
          />
          <p class="input-hint">Comma-separated, any subset of mon tue wed thu fri sat sun.</p>
        </label>
        <p :for={msg <- error_messages(@form[:days])} class="input-error">{msg}</p>
      </div>

      <div class="fieldset">
        <label class="label">
          <span class="label-text">Times (UTC)</span>
          <input
            type="text"
            name={@form[:times].name}
            value={@form[:times].value}
            class="input"
            placeholder="04:00:00,14:30:00"
          />
          <p class="input-hint">Comma-separated <code>HH:MM:SS</code>. UTC.</p>
        </label>
        <p :for={msg <- error_messages(@form[:times])} class="input-error">{msg}</p>
      </div>

      <div class="fieldset">
        <label>
          <input type="hidden" name={@form[:active].name} value="false" />
          <input
            type="checkbox"
            name={@form[:active].name}
            value="true"
            checked={@form[:active].value in [true, "true"]}
          /> Active (paused when off)
        </label>
      </div>

      <div class="fieldset">
        <label class="label">
          <span class="label-text">Note</span>
          <input
            type="text"
            name={@form[:note].name}
            value={@form[:note].value}
            class="input"
            placeholder="optional context for fellow admins"
          />
        </label>
      </div>

      <button type="submit" class="btn btn-primary">Save</button>
      <.link href={~p"/admin/crawlers/schedules"} class="btn btn-subtle">Cancel</.link>
    </.form>
    """
  end

  defp error_messages(field) do
    Enum.map(field.errors, &SuperBaratoWeb.CoreComponents.translate_error/1)
  end
end
