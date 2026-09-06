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

  @doc "Record something as data with no effect: a model's final text, a driver's error. Returns :ok."
  def note(_term), do: :ok

  @doc "One-line descriptions, offered to a model as tool descriptions."
  def description({:echo, 1}), do: "Echo one value back. args: [value]"
  def description({:fail, 0}), do: "Crash on purpose (a test tool). args: []"
  def description({:note, 1}), do: "Record a remark as data; no effect. args: [text]"
  def description({:spawn_subagent, 2}), do: "Not callable by a model: takes a driver module and context."
  def description({:seed_ready, 0}), do: "List the open-seed cards this actor may claim. args: []"
  def description({:seed_get, 1}), do: "Fetch one open-seed card. args: [task_id]"
  def description({:seed_claim, 1}), do: "Claim a ready card; the envelope carries claim_token. args: [task_id]"
  def description({:seed_claim, 2}), do: "Claim with a lease such as \"45m\". args: [task_id, lease]"
  def description({:seed_lease_renew, 2}), do: "Extend a live claim. args: [task_id, claim_token]"
  def description({:seed_release, 2}), do: "Give a claim back without closing. args: [task_id, claim_token]"
  def description({:seed_transition, 3}), do: "Move a card, e.g. to \"review\". args: [task_id, to_state, claim_token]"
  def description({:seed_transition, 4}), do: "Move a card to blocked with a reason (plan:<pr> | dep:<id> | manual:<op>). args: [task_id, \"blocked\", claim_token, blocked_on]"
  def description({:seed_attach_evidence, 4}), do: "Append evidence. args: [task_id, kind (log|commit|pr|file), ref, claim_token]"
  def description({:seed_comment, 3}), do: "Append a comment to a card. args: [task_id, body, claim_token]"
  def description({f, a}), do: "tiller tool #{f}/#{a}"

  @doc """
  Spawn a subagent under Tiller's supervisor (crash-isolated) and start
  it. Returns `{:subagent_started, pid, session_id}` at once: the parent
  keeps taking turns while the child runs, and gets
  `{:subagent_halted, pid, turns}` when it halts. The child's events carry
  the parent's session id as `parent_id`. A start failure is contained:
  `{:subagent_failed, reason}`.
  """
  def spawn_subagent(driver, ctx) do
    sup = Application.fetch_env!(:tiller, :supervisor)
    parent = self()
    parent_id = Tiller.Session.current_id()

    spec =
      Tiller.Session.child_spec(
        driver: driver,
        ctx: ctx,
        whitelist: Tiller.Actions.sub_whitelist(),
        parent: parent,
        parent_id: parent_id
      )

    case DynamicSupervisor.start_child(sup, spec) do
      {:ok, pid} ->
        :ok = Tiller.Session.run(pid)
        {:subagent_started, pid, Tiller.Session.id(pid)}

      {:error, reason} ->
        {:subagent_failed, reason}
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
