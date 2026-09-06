defmodule Tiller.Mutation do
  @moduledoc """
  The vocabulary of one-variable changes a forked branch applies
  (docs/designs/agent-butterfly-lab.md, Types). Only the type lives here
  for now; applying a mutation at a fork point is step 8.

  Two axes are already plumbed through `Tiller.Session`'s options
  (`whitelist:` and `driver:`); the other three need the replay driver
  (step 7) and the fault-injection work (open question 5).
  """

  @type t ::
          {:whitelist, [{atom, arity}]}
          | {:driver, module, ctx :: term}
          | {:result_override, turn :: non_neg_integer, term}
          | {:latency, milliseconds :: pos_integer}
          | {:kill_at, turn :: non_neg_integer}

  @doc "Which axes `Tiller.Session.child_spec/1` can already express."
  @spec plumbed?(t) :: boolean
  def plumbed?({:whitelist, _}), do: true
  def plumbed?({:driver, _, _}), do: true
  def plumbed?(_), do: false
end
