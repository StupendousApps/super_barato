defmodule SuperBaratoWeb.Router do
  use SuperBaratoWeb, :router

  import SuperBaratoWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SuperBaratoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SuperBaratoWeb do
    pipe_through [:browser, :put_home_layout]

    live "/", HomeLive, :index
  end

  defp put_home_layout(conn, _opts) do
    Phoenix.Controller.put_root_layout(conn, html: {SuperBaratoWeb.Layouts, :home_root})
  end

  # Other scopes may use custom stacks.
  # scope "/api", SuperBaratoWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:super_barato, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SuperBaratoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Admin — served from the `admin.` subdomain. Phoenix's `host:`
  ## with a trailing dot matches any subdomain starting with that
  ## prefix (admin.superbarato.cl, admin.localhost, etc.).

  scope "/", SuperBaratoWeb.Admin, host: "admin.", as: :admin do
    pipe_through [:browser, :redirect_if_admin]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", SuperBaratoWeb.Admin, host: "admin.", as: :admin do
    pipe_through [:browser, :require_admin]

    get "/", PageController, :index
    get "/listings", ListingController, :index
    get "/categories", CategoryController, :index

    get "/crawlers", ScheduleController, :index, as: :crawlers_root
    resources "/crawlers/schedules", ScheduleController, except: [:show]
    get "/crawlers/live", RuntimeController, :index
    post "/crawlers/live/:chain/:kind", RuntimeController, :trigger

    resources "/users", UserController, only: [:index, :edit, :update, :delete]

    # The library's <.top_navigation> logout slot submits POST, so we
    # accept both POST and DELETE here.
    post "/logout", SessionController, :delete
    delete "/logout", SessionController, :delete
  end
end
