defmodule SuperBaratoWeb.Admin.ScheduleHTML do
  use SuperBaratoWeb, :html
  use StupendousAdmin
  import SuperBaratoWeb.Admin.Components

  alias SuperBarato.Crawler
  alias SuperBaratoWeb.Admin.ListingHTML

  embed_templates "schedule_html/*"

  defdelegate format_datetime(dt), to: ListingHTML

  def chain_options do
    [{"Any", ""} | Enum.map(Crawler.known_chains(), fn c -> {chain_label(c), Atom.to_string(c)} end)]
  end

  def kind_options do
    [
      {"Discover categories", "discover_categories"},
      {"Discover products", "discover_products"},
      {"Refresh listings", "refresh_listings"}
    ]
  end

  def kind_filter_options, do: [{"Any", ""} | kind_options()]

  def kind_label("discover_categories"), do: "Discover categories"
  def kind_label("discover_products"), do: "Discover products"
  def kind_label("refresh_listings"), do: "Refresh listings"
  def kind_label(other), do: other

  attr :changeset, Ecto.Changeset, required: true
  attr :action, :string, required: true

  def schedule_form(assigns) do
    method = if assigns.changeset.data.id, do: "put", else: "post"

    assigns =
      assigns
      |> assign(:form, to_form(assigns.changeset, as: :schedule))
      |> assign(:method, method)

    ~H"""
    <.stupendous_form for={@form} action={@action} method={@method} width={:regular}>
      <.form_errors form={@form} />

      <.input
        field={@form[:chain]}
        type="select"
        label="Chain"
        options={Enum.reject(chain_options(), fn {_, v} -> v == "" end)}
        prompt="—"
      />
      <.input
        field={@form[:kind]}
        type="select"
        label="Kind"
        options={kind_options()}
        prompt="—"
      />
      <.input
        field={@form[:days]}
        label="Days"
        placeholder="mon,tue,wed,thu,fri,sat,sun"
        hint="Comma-separated, any subset of mon tue wed thu fri sat sun."
      />
      <%!-- Plain text input rather than <.time_picker> — the picker
           enforces an HH:MM pattern, but the DB persists HH:MM:SS.
           parse_time_token/1 in the schema accepts either, so a
           text field round-trips cleanly. Comma-separated lists for
           multi-time schedules are rare but not blocked. --%>
      <.input
        field={@form[:times]}
        label="Time (UTC)"
        placeholder="04:30:00"
        hint="HH:MM or HH:MM:SS in UTC. Comma-separated for multiple firings on the same day."
      />
      <.input field={@form[:active]} type="checkbox" label="Active (paused when off)" />
      <.input
        field={@form[:note]}
        label="Note"
        placeholder="optional context for fellow admins"
      />

      <:footer>
        <.button type="submit" variant={:primary}>Save</.button>
        <.button href={~p"/crawlers/schedules"} variant={:subtle}>Cancel</.button>
      </:footer>
    </.stupendous_form>
    """
  end
end
