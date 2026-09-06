defmodule Tiller.Actions do
  @moduledoc """
  Action registry. The whitelist *is* the capability boundary: an agent can
  only call what its session's whitelist allows. Subagents get a smaller
  whitelist and never get `spawn_subagent` (depth limit).

  The open-seed split mirrors the port's own rule that a sub-agent inherits
  its parent's claim: the root session holds the worker verbs (claim,
  renew, release, transition, evidence, comment); a subagent may only read
  (`seed_ready`, `seed_get`). Operator verbs (accept, reject, close, ...)
  are on no whitelist at all: they are a human's, and the engine checks
  its roster regardless.
  """

  @seed_read [
    {:seed_ready, 0},
    {:seed_get, 1}
  ]

  @seed_worker [
    {:seed_claim, 1},
    {:seed_claim, 2},
    {:seed_lease_renew, 2},
    {:seed_release, 2},
    {:seed_transition, 3},
    {:seed_transition, 4},
    {:seed_attach_evidence, 4},
    {:seed_comment, 3}
  ]

  @root_tools [
    {:echo, 1},
    {:fail, 0},
    {:spawn_subagent, 2}
  ] ++ @seed_read ++ @seed_worker

  @sub_tools [
    {:echo, 1},
    {:fail, 0}
  ] ++ @seed_read

  def root_whitelist, do: @root_tools
  def sub_whitelist, do: @sub_tools

  @doc "The seed verbs a subagent may call: reads only."
  def seed_read_whitelist, do: @seed_read

  @doc "The seed verbs the root session may call in addition to the reads."
  def seed_worker_whitelist, do: @seed_worker

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
