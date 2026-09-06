defmodule Tiller do
  @moduledoc """
  Application start: State + DynamicSupervisor for sessions (incl. subagents).
  See README.md for the design.
  """

  use Application

  @doc """
  Back to a blank slate: stop every supervised session (subagents, forks),
  drop all events, reset the global tool state. Tests and the demo call this.
  """
  def reset do
    for sup <- [Tiller.Supervisor, Tiller.ToolStates],
        {_, pid, _, _} <- DynamicSupervisor.which_children(sup),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(sup, pid)
    end

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

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, pid} ->
        Application.put_env(:tiller, :supervisor, Tiller.Supervisor)
        {:ok, pid}
    end
  end
end
