defmodule TillerWeb.Endpoint do
  @moduledoc "HTTP + LiveView socket for the lab. Loopback only, see config."
  use Phoenix.Endpoint, otp_app: :tiller

  @session_options [
    store: :cookie,
    key: "_tiller_key",
    signing_salt: "tiller-lab-session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Prebuilt client bundles straight from the deps: no node, no esbuild.
  plug(Plug.Static, at: "/vendor/phoenix", from: {:phoenix, "priv/static"}, gzip: false)

  plug(Plug.Static,
    at: "/vendor/live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false
  )

  plug(Plug.Session, @session_options)
  plug(TillerWeb.Router)
end

defmodule TillerWeb.ErrorHTML do
  @moduledoc false
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
