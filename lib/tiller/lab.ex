defmodule Tiller.Lab do
  @moduledoc """
  The butterfly lab without the screen: fork one session at one turn into
  N branches, each under one mutation, race them concurrently under the
  supervisor, and report where each first diverged from its parent.

  This is the MVP bar of docs/designs/agent-butterfly-lab.md minus the
  LiveView (step 9), which will call exactly this and paint the events as
  they arrive on `Tiller.State.subscribe(:all)`.
  """

  alias Tiller.{Divergence, Event, Mutation, Session}

  @type branch :: %{
          mutation: Mutation.t(),
          pid: pid,
          id: term,
          lineage: [term],
          outcome: {:halted, non_neg_integer} | {:error, :timeout | :dead},
          verdict: Divergence.verdict()
        }

  @doc """
  Fork `pid` at `turn` once per mutation, run every branch, await them
  all, and compare each to the parent. Options: `timeout:` per branch
  (default 5_000), `key:` for `Tiller.Divergence.first_diff/3`.
  Unsupported or invalid mutations come back as
  `%{mutation: m, error: reason}` entries instead of branches.
  """
  @spec race(pid, non_neg_integer, [Mutation.t()], keyword) :: [branch | %{mutation: Mutation.t(), error: term}]
  def race(pid, turn, mutations, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    %{id: parent_id} = Session.info(pid)

    started =
      Enum.map(mutations, fn m ->
        case Session.fork(pid, turn, m) do
          {:ok, bpid} -> {m, bpid, Session.id(bpid)}
          {:error, reason} -> {m, {:error, reason}, nil}
        end
      end)

    # start every branch before awaiting any: they race
    for {_m, bpid, _} <- started, is_pid(bpid), do: :ok = Session.run(bpid)

    parent_events = Tiller.State.events(parent_id)

    Enum.map(started, fn
      {m, {:error, reason}, _} ->
        %{mutation: m, error: reason}

      {m, bpid, id} ->
        # await by id: a killed branch's pid dies, its resume carries on
        outcome = Session.await(id, timeout)
        final = Session.final(id)

        %{
          mutation: m,
          pid: bpid,
          id: final,
          lineage: Session.lineage(id),
          outcome: outcome,
          verdict: Divergence.first_diff(parent_events, Tiller.State.events(final), Keyword.take(opts, [:key]))
        }
    end)
  end

  @doc "Stop every session under the supervisor and clear the store: a fresh lab."
  def reset do
    sup = Tiller.Supervisor

    for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid),
        do: DynamicSupervisor.terminate_child(sup, pid)

    Tiller.State.clear()
  end

  @doc "One line per branch, for a terminal."
  def format(results) do
    Enum.map_join(results, "\n", fn
      %{mutation: m, error: reason} ->
        "  #{Mutation.label(m)}: not run (#{inspect(reason)})"

      %{mutation: m, lineage: lineage, outcome: outcome, verdict: verdict} ->
        "  #{Mutation.label(m)} [#{Enum.join(lineage, " -> ")}] #{inspect(outcome)}: #{describe(verdict)}"
    end)
  end

  defp describe(:identical), do: "identical"

  defp describe({:diverged, turn, l, r}),
    do: "diverged at turn #{turn}: #{side(l)} vs #{side(r)}"

  defp side(nil), do: "(ended)"
  defp side(%Event{action: :halt}), do: "halt"
  defp side(%Event{action: {:call, _, f, args}, result: res}), do: "#{f}/#{length(args)} -> #{inspect(res, limit: 4)}"
  defp side({:halt, _}), do: "halt"
  defp side({{:call, _, f, args}, res}), do: "#{f}/#{length(args)} -> #{inspect(res, limit: 4)}"
end
