defmodule TillerWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {TillerWeb.Layouts, :root})
  end

  scope "/", TillerWeb do
    pipe_through(:browser)
    live("/", LabLive)
  end
end
