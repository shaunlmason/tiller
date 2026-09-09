defmodule Tiller.Event do
  @moduledoc """
  One attributed entry in a trajectory.

  Today `Tiller.State` records bare `{action, result}` tuples in a single
  global list. Events add identity (`session_id`, `parent_id`), position
  (`seq`, `turn`), and a uniform halt record, so several branches can share
  one ordered store and still be pulled apart.

  Halt records use `action: :halt` and `result: {:halted, turn_count}`, or
  `{:halted, turn_count, reason}` when a driver ended the run abnormally
  (a refusal, a budget, an API failure). Both match `halt?/1`, and the
  two forms differ under `Tiller.Divergence`, so a branch that gave up
  diverges from one that finished.

  `rationale` is why the action was chosen, when the driver knows: the
  model's summarized thinking for that turn. It is deliberately outside
  `key/1`, so two branches that reasoned differently and acted the same
  are still the same trajectory. An event recorded before this field
  existed (a durable log written by an older build) has no key for it at
  all, which is why `rationale/1` reads it rather than the struct field.
  """

  @enforce_keys [:seq, :session_id, :turn, :action, :result]
  defstruct [:seq, :session_id, :parent_id, :turn, :action, :result, :rationale]

  @typedoc "A quoted MFA term; the grammar is the capability boundary."
  @type action :: {:call, module, atom, [term]}

  @type result ::
          {:ok, term}
          | {:error, term}
          | {:halted, non_neg_integer}
          | {:halted, non_neg_integer, term}

  @type t :: %__MODULE__{
          # monotonic, globally ordered across all sessions
          seq: pos_integer,
          # this branch
          session_id: binary,
          # branch ancestry; nil for root
          parent_id: binary | nil,
          # turn index within this session
          turn: non_neg_integer,
          action: action | :halt,
          result: result,
          # why the driver chose this action, when it can say
          rationale: binary | nil
        }

  @doc "Build the terminal record for a session that ran `turns` turns."
  @spec halt(pos_integer, binary, binary | nil, non_neg_integer, term) :: t
  def halt(seq, session_id, parent_id, turns, reason \\ nil) do
    %__MODULE__{
      seq: seq,
      session_id: session_id,
      parent_id: parent_id,
      turn: turns,
      action: :halt,
      result: halted(turns, reason)
    }
  end

  @doc "The terminal result: with a reason when a driver gave one."
  @spec halted(non_neg_integer, term) :: result
  def halted(turns, nil), do: {:halted, turns}
  def halted(turns, reason), do: {:halted, turns, reason}

  @doc """
  How many turns a terminal result counts, whichever form it takes.

  Everything that asks "did this session finish, and after how many
  turns" goes through here, so the optional reason never has to be
  matched at a call site.
  """
  @spec halted_turns(result) :: non_neg_integer | nil
  def halted_turns({:halted, n}), do: n
  def halted_turns({:halted, n, _reason}), do: n
  def halted_turns(_other), do: nil

  @doc "Why a session ended, when a driver said: `nil` for a normal halt."
  @spec halt_reason(result) :: term
  def halt_reason({:halted, _n, reason}), do: reason
  def halt_reason(_other), do: nil

  @doc """
  Why the driver chose this action, or `nil`.

  Read through here rather than off the struct: an event from a log
  written before the field existed comes back as a map without the key,
  and a trajectory that outlives a build is the whole point of the log.
  """
  @spec rationale(t | map) :: binary | nil
  def rationale(event), do: Map.get(event, :rationale)

  @doc "Is this the terminal record?"
  @spec halt?(t | tuple) :: boolean
  def halt?(%__MODULE__{action: :halt}), do: true
  def halt?({:halt, _}), do: true
  def halt?(_), do: false

  @doc """
  What two branches are compared on: the action and its result.

  `seq`, `session_id` and `parent_id` differ between branches by
  construction, so they must not take part in divergence. Bare
  `{action, result}` tuples from the current `Tiller.State` log are
  accepted as-is, so the same comparison works before and after the
  event store lands.
  """
  @spec key(t | tuple) :: {term, term}
  def key(%__MODULE__{action: a, result: r}), do: {a, r}
  def key({a, r}), do: {a, r}
end
