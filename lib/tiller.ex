defmodule Tiller do
  @moduledoc """
  Application start: State + DynamicSupervisor for sessions (incl. subagents),
  plus the open-seed client when one is configured. See README.md for the
  design.

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
        Tiller.State,
        %{
          id: Tiller.Supervisor,
          start: {DynamicSupervisor, :start_link,
                  [[strategy: :one_for_one, name: Tiller.Supervisor]]}
        }
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
