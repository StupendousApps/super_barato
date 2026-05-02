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

  ## Admin — served from the `admin.` subdomain. Declared FIRST so the
  ## host-constrained routes get a chance to match before the catch-all
  ## public scope below. Phoenix's `host:` with a trailing dot matches
  ## any subdomain starting with that prefix (admin.superbarato.cl,
  ## admin.localhost, etc.).

  scope "/", SuperBaratoWeb.Admin, host: "admin.", as: :admin do
    pipe_through [:browser, :redirect_if_admin]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", SuperBaratoWeb.Admin, host: "admin.", as: :admin do
    pipe_through [:browser, :require_admin]

    get "/", DashboardController, :index
    get "/products", ProductController, :index
    get "/products/:id", ProductController, :show
    get "/products/:id/edit", ProductController, :edit
    patch "/products/:id", ProductController, :update
    put "/products/:id", ProductController, :update
    get "/products/:id/merge", ProductController, :merge_new
    post "/products/:id/merge", ProductController, :merge_create
    post "/products/:id/listings", ProductController, :link_listing
    delete "/products/:id/listings/:listing_id", ProductController, :unlink_listing
    post "/products/:id/listings/:listing_id/use-image", ProductController, :use_listing_image
    post "/products/:id/listings/:listing_id/use-name", ProductController, :use_listing_name
    get "/listings", ListingController, :index
    get "/listings/:id/link", ListingController, :link_new
    post "/listings/:id/link", ListingController, :link_create
    delete "/listings/:id/link", ListingController, :link_delete
    get "/chain-categories", ChainCategoryController, :index
    get "/chain-categories/:id/edit", ChainCategoryController, :edit
    patch "/chain-categories/:id", ChainCategoryController, :update
    put "/chain-categories/:id", ChainCategoryController, :update
    delete "/chain-categories/:id/listings", ChainCategoryController, :delete_listings
    get "/app-categories", AppCategoryController, :index
    post "/app-categories/reorder", AppCategoryController, :reorder_categories
    post "/app-categories/subcategories/reorder",
         AppCategoryController,
         :reorder_subcategories

    get "/crawlers", ScheduleController, :index, as: :crawlers_root
    resources "/crawlers/schedules", ScheduleController, except: [:show]

    live_session :crawlers_live,
      on_mount: [{SuperBaratoWeb.UserAuth, :require_admin}],
      root_layout: {SuperBaratoWeb.AdminLayouts, :root},
      layout: {SuperBaratoWeb.AdminLayouts, :admin} do
      live "/crawlers/live", CrawlerLive, :index
    end

    get "/crawlers/manual", ManualController, :index

    resources "/users", UserController, only: [:index, :edit, :update, :delete]

    # The library's <.top_navigation> logout slot submits POST, so we
    # accept both POST and DELETE here.
    post "/logout", SessionController, :delete
    delete "/logout", SessionController, :delete
  end

  ## Public — catches everything else (the apex + www hosts).

  scope "/", SuperBaratoWeb do
    pipe_through [:browser, :put_home_layout]

    live "/", HomeLive, :index
  end

  defp put_home_layout(conn, _opts) do
    Phoenix.Controller.put_root_layout(conn, html: {SuperBaratoWeb.Layouts, :home_root})
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:super_barato, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SuperBaratoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
