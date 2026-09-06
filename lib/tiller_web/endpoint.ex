defmodule TillerWeb.Endpoint do
  @moduledoc """
  The lab's HTTP endpoint. The LiveView client JS is served straight from
  the phoenix and phoenix_live_view packages' `priv/static`, so the
  project has no asset pipeline and no node.
  """
  use Phoenix.Endpoint, otp_app: :tiller

  @session_options [store: :cookie, key: "_tiller_key", signing_salt: "tiller-lab-session", same_site: "Lax"]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Static, at: "/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  plug Plug.Session, @session_options
  plug TillerWeb.Router
end

defmodule TillerWeb.ErrorHTML do
  @moduledoc false
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
