import Config

# Local instrument, not a deployment: fixed secrets, loopback only.
config :tiller, TillerWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  check_origin: ["//localhost", "//127.0.0.1"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: String.duplicate("tiller-butterfly-lab-", 4),
  live_view: [signing_salt: "tiller-lab-lv"],
  render_errors: [formats: [html: TillerWeb.ErrorHTML], layout: false],
  server: config_env() == :dev

config :logger, level: if(config_env() == :test, do: :warning, else: :info)

# A durable store for the lab: every event, snapshot and profile is
# appended here and read back at start (Tiller.State.Log), so `mix
# phx.server` keeps its trajectories across a restart and
# `Tiller.resume_dead/0` can pick up the runs it interrupted. Tests stay
# in memory; TILLER_STATE_LOG overrides either.
if config_env() == :dev do
  config :tiller, state_log: "tmp/tiller-state.log"
end
