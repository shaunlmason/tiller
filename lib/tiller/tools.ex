defmodule Tiller.Tools do
  @moduledoc """
  The actual tools. Every function here is callable only if `{name, arity}`
  is in the running session's whitelist (`Tiller.Actions`).

  The `seed_*` family talks to the open-seed engine through `Tiller.Seed`
  (option 1 in docs/designs/open-seed-integration.md). Each returns
  `{:ok, envelope}` or `{:refused, envelope}`: a refused verb is a result,
  not a crash, so the log records exactly which exit class the port
  returned (2 contention, 3 invalid transition, 6 fenced out, ...). The
  actor is the client's; the claim token is explicit, because keeping it is
  the driver's job (the port fences every later worker verb on it).
  """

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

  ## open-seed port verbs (read)

  @doc "Claimable cards for this actor."
  def seed_ready(), do: seed("task_ready", %{actor: actor()})

  @doc "One card."
  def seed_get(task), do: seed("task_get", %{task: task})

  ## open-seed port verbs (worker: fenced by the claim token)

  @doc "Claim a ready card with the engine's default lease. The envelope carries `claim_token`."
  def seed_claim(task), do: seed("task_claim", %{task: task, actor: actor()})

  @doc "Claim with an explicit lease, e.g. \"45m\"."
  def seed_claim(task, lease), do: seed("task_claim", %{task: task, actor: actor(), lease: lease})

  @doc "Extend a live claim's lease."
  def seed_lease_renew(task, token),
    do: seed("task_lease_renew", %{task: task, actor: actor(), token: token})

  @doc "Give the claim back without closing the card."
  def seed_release(task, token),
    do: seed("task_release", %{task: task, actor: actor(), token: token})

  @doc "Move a card (e.g. to \"review\")."
  def seed_transition(task, to, token),
    do: seed("task_transition", %{task: task, to: to, actor: actor(), token: token})

  @doc "Move a card to blocked with a blocked_on entry (plan:<pr> | dep:<id> | manual:<op>)."
  def seed_transition(task, to, token, blocked_on),
    do:
      seed("task_transition", %{
        task: task,
        to: to,
        actor: actor(),
        token: token,
        blocked_on: blocked_on
      })

  @doc "Append evidence (kind: log | commit | pr | file)."
  def seed_attach_evidence(task, kind, ref, token),
    do: seed("task_attach_evidence", %{task: task, actor: actor(), kind: kind, ref: ref, token: token})

  @doc "Append a comment to a card."
  def seed_comment(task, body, token),
    do: seed("task_comment", %{task: task, actor: actor(), body: body, token: token})

  defp seed(tool, args), do: Tiller.Seed.call(client(), tool, args)
  defp actor(), do: Tiller.Seed.actor(client())

  defp client() do
    Process.whereis(Tiller.Seed) ||
      raise Tiller.Seed.TransportError, reason: :not_started
  end
end
