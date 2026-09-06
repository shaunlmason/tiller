import Config

# Local instrument, not a deployment: fixed secrets, loopback only.
config :tiller, TillerWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  check_origin: ["//localhost", "//127.0.0.1"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: String.duplicate("tiller-butterfly-lab-", 4),
  live_view: [signing_salt: "tiller-lab-lv"],
  pubsub_server: Tiller.PubSub,
  render_errors: [formats: [html: TillerWeb.ErrorHTML], layout: false],
  server: config_env() == :dev

config :logger, level: if(config_env() == :test, do: :warning, else: :info)
