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
          outcome: {:halted, non_neg_integer} | {:error, :timeout},
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
    %{id: parent_id, state: state} = Session.info(pid)

    started =
      Enum.map(mutations, fn m ->
        case Session.fork(pid, turn, m, Keyword.take(opts, [:state])) do
          {:ok, bpid} -> {m, bpid}
          {:error, reason} -> {m, {:error, reason}}
        end
      end)

    # start every branch before awaiting any: they race
    for {_m, bpid} <- started, is_pid(bpid), do: :ok = Session.run(bpid)

    parent_events = state.events(parent_id)

    Enum.map(started, fn
      {m, {:error, reason}} ->
        %{mutation: m, error: reason}

      {m, bpid} ->
        outcome = Session.await(bpid, timeout)
        id = Session.id(bpid)

        %{
          mutation: m,
          pid: bpid,
          id: id,
          outcome: outcome,
          verdict: Divergence.first_diff(parent_events, state.events(id), Keyword.take(opts, [:key]))
        }
    end)
  end

  @doc "One line per branch, for a terminal."
  def format(results) do
    Enum.map_join(results, "\n", fn
      %{mutation: m, error: reason} ->
        "  #{Mutation.label(m)}: not run (#{inspect(reason)})"

      %{mutation: m, id: id, outcome: outcome, verdict: verdict} ->
        "  #{Mutation.label(m)} [#{id}] #{inspect(outcome)}: #{describe(verdict)}"
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
