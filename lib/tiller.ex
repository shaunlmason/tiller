defmodule Tiller do
  @moduledoc """
  Application start: PubSub, State, the session registry, the
  DynamicSupervisor for sessions (incl. subagents and forks), the lab's
  web endpoint (serving only under `mix phx.server`), plus the open-seed
  client when one is configured. See README.md for the design.

  Configure the client with `config :tiller, :seed, cd: "/path/to/repo",
  actor: "tiller-1"` (options in `Tiller.Seed`), or start it yourself with
  `Tiller.Seed.start_link/1`. Without either, the `seed_*` tools fail as
  data (`{:error, _}` in the log) and nothing else changes.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Tiller.State.pubsub_spec(),
        Tiller.State,
        Tiller.Session.registry_spec(),
        %{
          id: Tiller.Supervisor,
          # the lab kills sessions on purpose (the kill_at axis) and relies on
          # the restart to resume them, so the crash-loop valve is set wide:
          # the default 3 restarts in 5 seconds would trip on one race
          start: {DynamicSupervisor, :start_link,
                  [[strategy: :one_for_one, name: Tiller.Supervisor, max_restarts: 100, max_seconds: 5]]}
        },
        TillerWeb.Endpoint
      ] ++ seed_child(Application.get_env(:tiller, :seed))

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, pid} ->
        Application.put_env(:tiller, :supervisor, Tiller.Supervisor)
        {:ok, pid}
    end
  end

  defp seed_child(nil), do: []
  defp seed_child(opts) when is_list(opts), do: [{Tiller.Seed, opts}]
end
