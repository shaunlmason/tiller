defmodule Tiller.Event do
  @moduledoc """
  One attributed log entry (docs/designs/agent-butterfly-lab.md, Types).

  Today `Tiller.State.log/0` returns bare `{action, result}` tuples with a
  `{:halt, turns}` record at the end. This struct is the shape those
  entries take once sessions are attributed: identity, ancestry, ordering.
  Nothing writes it yet; `from_log/2` lifts a plain log into events so the
  divergence analysis is written once, against the future shape, and works
  on both.

  Halt records: `action` is `:halt`, `result` is `{:halted, turn_count}`.
  """

  @enforce_keys [:turn, :action, :result]
  defstruct [:seq, :session_id, :parent_id, :turn, :action, :result]

  @type action :: {:call, module, atom, [term]} | :halt
  @type result :: {:ok, term} | {:error, term} | {:halted, non_neg_integer}

  @type t :: %__MODULE__{
          seq: pos_integer | nil,
          session_id: term,
          parent_id: term,
          turn: non_neg_integer,
          action: action,
          result: result
        }

  @doc """
  Lift a `Tiller.State.log/0` list into events for `session_id`. The halt
  record `{:halt, n}` becomes `action: :halt, result: {:halted, n}`.
  """
  @spec from_log([{term, term}], term, keyword) :: [t]
  def from_log(log, session_id, opts \\ []) do
    parent = Keyword.get(opts, :parent_id)

    log
    |> Enum.with_index()
    |> Enum.map(fn
      {{:halt, n}, i} ->
        %__MODULE__{seq: i + 1, session_id: session_id, parent_id: parent, turn: i, action: :halt, result: {:halted, n}}

      {{action, result}, i} ->
        %__MODULE__{seq: i + 1, session_id: session_id, parent_id: parent, turn: i, action: action, result: result}
    end)
  end
end
