defmodule Tiller.Event do
  @moduledoc """
  One attributed entry in a trajectory.

  Today `Tiller.State` records bare `{action, result}` tuples in a single
  global list. Events add identity (`session_id`, `parent_id`), position
  (`seq`, `turn`), and a uniform halt record, so several branches can share
  one ordered store and still be pulled apart.

  Halt records use `action: :halt` and `result: {:halted, turn_count}`.
  """

  @enforce_keys [:seq, :session_id, :turn, :action, :result]
  defstruct [:seq, :session_id, :parent_id, :turn, :action, :result]

  @typedoc "A quoted MFA term; the grammar is the capability boundary."
  @type action :: {:call, module, atom, [term]}

  @type result :: {:ok, term} | {:error, term} | {:halted, non_neg_integer}

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
          result: result
        }

  @doc "Build the terminal record for a session that ran `turns` turns."
  @spec halt(pos_integer, binary, binary | nil, non_neg_integer) :: t
  def halt(seq, session_id, parent_id, turns) do
    %__MODULE__{
      seq: seq,
      session_id: session_id,
      parent_id: parent_id,
      turn: turns,
      action: :halt,
      result: {:halted, turns}
    }
  end

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
