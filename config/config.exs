import Config

# The butterfly lab runs locally (`mix phx.server`, http://localhost:4000).
# No auth, no TLS, no external exposure: the design scopes those out, so the
# secrets below are fixed dev values, not secrets.
config :tiller, TillerWeb.Endpoint,
  url: [host: "localhost"],
  # local only, but reachable as either name
  check_origin: ["//localhost", "//127.0.0.1"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "tiller-butterfly-lab-dev-only-secret-key-base-0123456789abcdefghijklmnopqrstuvwxyz",
  live_view: [signing_salt: "tiller-lab-salt"],
  pubsub_server: Tiller.PubSub,
  render_errors: [formats: [html: TillerWeb.ErrorHTML], layout: false]

# `mix phx.server` serves by setting :serve_endpoints; an explicit `server:`
# key here would override that (Phoenix reads it with Keyword.get_lazy), so
# the key is set only for PHX_SERVER=1 `mix run --no-halt`. Tests never serve.
if System.get_env("PHX_SERVER") in ["1", "true"] do
  config :tiller, TillerWeb.Endpoint, server: true
end

config :phoenix, :json_library, Jason
config :logger, level: :info
