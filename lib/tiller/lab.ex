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
          verdict: Divergence.verdict(),
          rank: pos_integer | nil
        }

  @doc """
  Fork `pid` at `turn` once per mutation, run every branch, await them
  all, and compare each to the parent. Options: `timeout:` per branch
  (default 5_000), `key:` for `Tiller.Divergence.first_diff/3`.
  Unsupported or invalid mutations come back as
  `%{mutation: m, error: reason}` entries instead of branches. Every
  branch carries its `rank` (see `rank/1`); the list itself stays in
  mutation order.
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

    started
    |> Enum.map(fn
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
    |> rank()
  end

  @doc """
  The smallest decisive mutation (open question 3).

  Axes are incommensurable, so no size is ever compared across axes.
  What every branch shares is the trajectory it perturbed, and the
  divergence turn measures how much of it survived: a branch that stays
  identical to its parent for longer before diverging is the smaller
  change to the run. So, among branches that diverged:

    1. later divergence turn ranks first (the more surgical change);
    2. on the same turn *and the same axis*, smaller `Mutation.size/1`
       ranks first;
    3. on the same turn and different axes, the branches tie: same rank.

  Branches that never diverged had no effect and get `rank: nil`; error
  entries are untouched. Returns the results in their original order
  with `:rank` set; `ranked/1` sorts them.
  """
  @spec rank([map]) :: [map]
  def rank(results) do
    ranked =
      results
      |> Enum.reject(&(Map.has_key?(&1, :error) or not diverged?(&1)))
      |> Enum.sort_by(&{-diverged_at(&1), Mutation.axis(&1.mutation), Mutation.size(&1.mutation)})
      |> dense_ranks()

    Enum.map(results, fn r ->
      if Map.has_key?(r, :error), do: r, else: Map.put(r, :rank, Map.get(ranked, r.id))
    end)
  end

  @doc "Results sorted by rank, no-effect branches last, errors after those."
  def ranked(results) do
    Enum.sort_by(results, fn
      %{error: _} -> {2, 0}
      %{rank: nil} -> {1, 0}
      %{rank: n} -> {0, n}
    end)
  end

  @doc "The top-ranked branches (several when they tie), or [] if nothing diverged."
  def smallest(results), do: for(%{rank: 1} = r <- results, do: r)

  defp diverged?(%{verdict: {:diverged, _, _, _}}), do: true
  defp diverged?(_), do: false
  defp diverged_at(%{verdict: {:diverged, t, _, _}}), do: t

  # dense ranking: same turn + different axis tie; same turn + same axis
  # + same size tie too; anything else advances
  defp dense_ranks(sorted) do
    sorted
    |> Enum.reduce({%{}, 0, nil}, fn r, {acc, n, prev} ->
      key = tie_key(r, prev)
      n = if key == prev, do: n, else: n + 1
      {Map.put(acc, r.id, n), n, key}
    end)
    |> elem(0)
  end

  defp tie_key(r, prev) do
    t = diverged_at(r)
    axis = Mutation.axis(r.mutation)
    size = Mutation.size(r.mutation)

    case prev do
      {^t, ^axis, ^size} -> prev
      {^t, other_axis, _} when other_axis != axis -> prev
      _ -> {t, axis, size}
    end
  end

  @doc "Stop every session under the supervisor and clear the store: a fresh lab."
  def reset do
    sup = Tiller.Supervisor

    for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid),
        do: DynamicSupervisor.terminate_child(sup, pid)

    Tiller.State.clear()
  end

  @doc """
  Every session the store knows that has no process and no halt: the ones
  a VM restart (or a crash) left unfinished. `resume_dead/0` brings each
  back through `Tiller.Session.resume/1`.
  """
  def dead do
    for {id, _, _} <- lineage_heads(), Session.whereis(id) == nil, not halted?(id), do: id
  end

  def resume_dead, do: for(id <- dead(), do: {id, Session.resume(id)})

  defp lineage_heads do
    Tiller.State.events()
    |> Enum.map(& &1.session_id)
    |> Enum.uniq()
    |> Enum.map(&{Session.final(&1), nil, nil})
    |> Enum.uniq()
  end

  defp halted?(id), do: Enum.any?(Tiller.State.events(id), &match?(%Event{action: :halt}, &1))

  @doc "One line per branch in rank order, for a terminal."
  def format(results) do
    results
    |> ranked()
    |> Enum.map_join("\n", fn
      %{mutation: m, error: reason} ->
        "  --  #{Mutation.label(m)}: not run (#{inspect(reason)})"

      %{mutation: m, lineage: lineage, outcome: outcome, verdict: verdict} = r ->
        "  #{rank_text(r)}  #{Mutation.label(m)} [#{Enum.join(lineage, " -> ")}] #{inspect(outcome)}: #{describe(verdict)}"
    end)
  end

  defp rank_text(%{rank: nil}), do: "--"
  defp rank_text(%{rank: n}), do: "##{n}"

  defp describe(:identical), do: "identical"

  defp describe({:diverged, turn, l, r}),
    do: "diverged at turn #{turn}: #{side(l)} vs #{side(r)}"

  defp side(nil), do: "(ended)"
  defp side(%Event{action: :halt}), do: "halt"
  defp side(%Event{action: {:call, _, f, args}, result: res}), do: "#{f}/#{length(args)} -> #{inspect(res, limit: 4)}"
  defp side({:halt, _}), do: "halt"
  defp side({{:call, _, f, args}, res}), do: "#{f}/#{length(args)} -> #{inspect(res, limit: 4)}"
end
