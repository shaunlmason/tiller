defmodule Tiller do
  @moduledoc """
  Application start: State, tool state, registry, the lab endpoint, the
  session supervisor, plus the open-seed client when one is configured.
  See README.md for the design.

  Configure the client with `config :tiller, :seed, cd: "/path/to/repo",
  actor: "tiller-1"` (options in `Tiller.Seed`), or start it yourself with
  `Tiller.Seed.start_link/1`. Without either, the `seed_*` tools fail as
  data (`{:error, _}` in the log) and nothing else changes.
  """

  use Application

  @doc """
  Sessions the store knows that are not running and have not halted.

  After a restart with a durable store (`Tiller.State.Log`) that is every
  run the restart interrupted.
  """
  @spec dead() :: [binary]
  def dead do
    # From profiles as well as events: a run killed before its first
    # action recorded nothing but is still a run to pick up.
    Tiller.State.sessions()
    |> Enum.filter(&(Tiller.Session.whereis(&1) == nil))
    |> Enum.reject(&halted?/1)
  end

  @doc "Resume every session in `dead/0`: `[{id, result}]`."
  @spec resume_dead() :: [{binary, {:ok, pid} | {:error, term}}]
  def resume_dead, do: for(id <- dead(), do: {id, Tiller.Session.resume(id)})

  defp halted?(id) do
    case List.last(Tiller.State.events(id)) do
      %Tiller.Event{action: :halt} -> true
      _ -> false
    end
  end

  @doc """
  Stop every supervised session and tool state, keeping the store.

  What a restart does to the running side of the system, without the
  restart: `reset/0` builds on it, and the persistence tests use it to
  reach the state a fresh VM would start in.
  """
  @spec reset_processes() :: :ok
  def reset_processes do
    for sup <- [Tiller.Supervisor, Tiller.ToolStates],
        {_, pid, _, _} <- DynamicSupervisor.which_children(sup),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(sup, pid)
    end

    :ok
  end

  @doc """
  Back to a blank slate: stop every supervised session (subagents, forks),
  drop all events, reset the global tool state. Tests and the demo call this.
  """
  def reset do
    reset_processes()
    Tiller.State.clear()
    Tiller.ToolState.reset()
    :ok
  end

  @impl true
  def start(_type, _args) do
    children = [
      Tiller.State,
      Tiller.ToolState,
      {Registry, keys: :unique, name: Tiller.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Tiller.ToolStates},
      TillerWeb.Endpoint,
      # Every kill_at branch is a deliberate restart, and a race can hold
      # dozens of them, so the default 3-in-5s intensity would take down the
      # whole race after four kills.
      %{
        id: Tiller.Supervisor,
        start:
          {DynamicSupervisor, :start_link,
           [
             [
               strategy: :one_for_one,
               name: Tiller.Supervisor,
               max_restarts: 1_000,
               max_seconds: 1
             ]
           ]}
      }
    ]

    children = children ++ seed_child(Application.get_env(:tiller, :seed))

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, pid} ->
        Application.put_env(:tiller, :supervisor, Tiller.Supervisor)
        {:ok, pid}
    end
  end

  defp seed_child(nil), do: []
  defp seed_child(opts) when is_list(opts), do: [{Tiller.Seed, opts}]
end
