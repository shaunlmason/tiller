defmodule Tiller.Actions do
  @moduledoc """
  Action registry. The whitelist *is* the capability boundary: an agent can
  only call what its session's whitelist allows. Subagents get a smaller
  whitelist and never get `spawn_subagent` (depth limit).
  """

  @root_tools [
    {:echo, 1},
    {:fail, 0},
    {:spawn_subagent, 2}
  ]

  @sub_tools [
    {:echo, 1},
    {:fail, 0}
  ]

  def root_whitelist, do: @root_tools
  def sub_whitelist, do: @sub_tools

  @doc """
  Evaluate a quoted MFA action `{:call, m, f, args}` against a whitelist.
  Returns {:ok, result} | {:error, reason} — never raises.
  """
  def eval({:call, _m, f, args}, whitelist) do
    if Enum.member?(whitelist, {f, length(args)}) do
      try do
        {:ok, apply(Tiller.Tools, f, args)}
      catch
        kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
      end
    else
      {:error, :not_whitelisted}
    end
  end

  def eval(other, _whitelist), do: {:error, {:bad_action, other}}
end

defmodule Tiller.Tools do
  @moduledoc "The actual tools. Add feed-domain tools here as they exist."

  def echo(value), do: "echo: #{inspect(value)}"
  def fail(), do: raise("simulated tool crash")

  @doc """
  Spawn a subagent under Tiller's supervisor (crash-isolated), run it to
  halt, and return its turn count. A crash is contained: the caller gets
  {:subagent_failed, reason} and the supervisor reaps the process.
  """
  def spawn_subagent(driver, ctx) do
    sup = Application.fetch_env!(:tiller, :supervisor)

    case DynamicSupervisor.start_child(sup, Tiller.Session.child_spec(
           driver: driver, ctx: ctx, whitelist: Tiller.Actions.sub_whitelist()
         )) do
      {:ok, pid} ->
        Tiller.Session.run(pid)
        {:subagent_done, pid}

      {:error, reason} -> {:subagent_failed, reason}
    end
  end
end
