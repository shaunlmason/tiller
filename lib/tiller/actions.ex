defmodule Tiller.Actions do
  @moduledoc """
  Action registry. The whitelist *is* the capability boundary: an agent can
  only call what its session's whitelist allows. Subagents get a smaller
  whitelist and never get the delegation verbs (depth limit).
  """

  # Tools every session gets. Each has an observable side effect or a
  # distinct failure mode, so mutating one branch's whitelist or result
  # changes what later turns can do.
  @base_tools [
    {:echo, 1},
    {:fail, 0},
    {:put, 2},
    {:get, 1},
    {:spend, 1},
    {:flaky, 1},
    {:sleep, 1},
    {:done, 1}
  ]

  # open-seed port verbs (`Tiller.Seed`). The split mirrors the port's own
  # rule that a sub-agent inherits its parent's claim: the root session holds
  # the worker verbs; a subagent may only read. Operator verbs (accept,
  # reject, close, ...) are on no whitelist at all: they are a human's.
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

  # Delegation is a root capability: a subagent gets neither verb, so it
  # cannot spawn and cannot wait on anything. That is the depth limit, and
  # it is also why `await/1` cannot be used to read another run's log.
  @delegation [{:spawn_subagent, 2}, {:spawn, 1}, {:await, 1}]

  @root_tools @base_tools ++ @delegation ++ @seed_read ++ @seed_worker
  @sub_tools @base_tools ++ @seed_read

  def root_whitelist, do: @root_tools
  def sub_whitelist, do: @sub_tools

  @doc "The seed verbs a subagent may call: reads only."
  def seed_read_whitelist, do: @seed_read

  @doc "The seed verbs the root session may call in addition to the reads."
  def seed_worker_whitelist, do: @seed_worker

  @doc """
  Evaluate a quoted MFA action `{:call, m, f, args}` against a whitelist.
  Returns {:ok, result} | {:error, reason} — never raises.

  A tool returns `{:ok, value}` or `{:error, reason}`, which pass through
  unchanged, or a bare value, which is wrapped as `{:ok, value}`. A tool
  that hands back arbitrary stored data (`get/1`) must use the explicit
  `{:ok, _}` form so a stored `{:error, _}` is not mistaken for a refusal.
  A crash (raise/throw/exit) is captured with its stacktrace as
  `{:error, {kind, reason, stacktrace}}`.
  """
  def eval({:call, _m, f, args}, whitelist) do
    if Enum.member?(whitelist, {f, length(args)}) do
      try do
        case apply(Tiller.Tools, f, args) do
          {:ok, _} = ok -> ok
          {:error, _} = err -> err
          value -> {:ok, value}
        end
      catch
        kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
      end
    else
      {:error, :not_whitelisted}
    end
  end

  def eval(other, _whitelist), do: {:error, {:bad_action, other}}
end
