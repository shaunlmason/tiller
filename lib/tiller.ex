defmodule Tiller do
  @moduledoc """
  Application start: State + DynamicSupervisor for sessions (incl. subagents).
  See README.md for the design.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Tiller.State,
      Tiller.ToolState,
      %{
        id: Tiller.Supervisor,
        start: {DynamicSupervisor, :start_link,
                [[strategy: :one_for_one, name: Tiller.Supervisor]]}
      }
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, pid} ->
        Application.put_env(:tiller, :supervisor, Tiller.Supervisor)
        {:ok, pid}
    end
  end
end
