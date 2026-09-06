defmodule Tiller.Mutation do
  @moduledoc """
  The vocabulary of one-variable changes a forked branch applies
  (docs/designs/agent-butterfly-lab.md, Types). `Tiller.Session.fork/4`
  applies one; `Tiller.Lab.race/4` applies many at once and compares.

  All five axes are live: `whitelist` and `driver` were already session
  options, `result_override` rides on the replay driver, `latency` is a
  delay before each live turn, and `kill_at` kills the branch process
  before a turn and lets the supervisor bring it back resumed from its
  own log (`Tiller.Session`, "Restart is resume").
  """

  @type t ::
          {:whitelist, [{atom, arity}]}
          | {:driver, module, ctx :: term}
          | {:result_override, turn :: non_neg_integer, term}
          | {:latency, milliseconds :: pos_integer}
          | {:kill_at, turn :: non_neg_integer}

  @doc "Which axes `Tiller.Session.fork/4` can apply."
  @spec supported?(t) :: boolean
  def supported?(m) when is_tuple(m), do: elem(m, 0) in [:whitelist, :driver, :result_override, :latency, :kill_at]

  @doc "A short label for reports."
  def label({:whitelist, wl}) do
    root = Tiller.Actions.root_whitelist()
    removed = for {f, a} <- root -- wl, do: "-#{f}/#{a}"
    added = for {f, a} <- wl -- root, do: "+#{f}/#{a}"

    case removed ++ added do
      [] -> "whitelist=root"
      diff -> "whitelist=root" <> Enum.join(diff)
    end
  end

  def label({:driver, mod, _}), do: "driver=#{inspect(mod)}"
  def label({:result_override, t, r}), do: "override@#{t}=#{inspect(r, limit: 5)}"
  def label({:latency, ms}), do: "latency=#{ms}ms"
  def label({:kill_at, t}), do: "kill@#{t}"
  def label({:resumed, t}), do: "resumed@#{t}"
end
