defmodule Tiller.Tools.Schema do
  @moduledoc """
  What makes a tool callable by a model: an ordered parameter list and a
  JSON type per `{name, arity}`, plus the sentence the model reads.

  This is the single table `Tiller.Driver.LLM.Wire` turns into tool
  definitions and back into positional args. A whitelisted entry with no
  schema is simply not offered (`spawn_subagent/2` takes a module and a
  context no model can supply, which is what `spawn/1` exists for;
  `fail/0` exists to crash). The session
  still refuses anything off the whitelist at `Tiller.Actions.eval/2`, so
  the boundary does not depend on this table being complete.
  """

  @schemas %{
    {:echo, 1} => {[value: :any], "Echo a value back. No side effect, never fails."},
    {:put, 2} =>
      {[key: :string, value: :any],
       "Store a value under a key. Later turns can read it with get."},
    {:get, 1} =>
      {[key: :string], "Read a stored value. Refuses with not_found when the key was never put."},
    {:spend, 1} =>
      {[amount: :integer],
       "Spend from a fixed budget and return what is left. Refuses without spending when the budget cannot cover it."},
    {:flaky, 1} =>
      {[value: :any], "Return the value, except that every third call in a run crashes."},
    {:sleep, 1} => {[ms: :integer], "Sleep for some milliseconds and return how long it slept."},
    {:done, 1} =>
      {[summary: :string],
       "Finish the run: record the final answer. Call this when the goal is met."},
    {:spawn, 1} =>
      {[goal: :string],
       "Delegate a goal to a subagent that runs on its own and returns a handle to wait on. Use it for work that is separable from what you are doing; the subagent cannot delegate further."},
    {:await, 1} =>
      {[turn: :integer],
       "Wait for the subagent spawned at a turn and return what it finished with. The turn is the number spawn gave you."}
  }

  @doc "Every `{name, arity}` a model may be offered."
  @spec callable() :: [{atom, arity}]
  def callable, do: Map.keys(@schemas)

  @doc "Is there a schema for this entry?"
  @spec callable?({atom, arity}) :: boolean
  def callable?(fa), do: Map.has_key?(@schemas, fa)

  @doc "Ordered parameters for an entry: `[{name, json_type}]`."
  @spec params({atom, arity}) :: {:ok, keyword(atom)} | :error
  def params(fa) do
    case Map.fetch(@schemas, fa) do
      {:ok, {params, _doc}} -> {:ok, params}
      :error -> :error
    end
  end

  @doc "The sentence the model reads for an entry."
  @spec description({atom, arity}) :: {:ok, String.t()} | :error
  def description(fa) do
    case Map.fetch(@schemas, fa) do
      {:ok, {_params, doc}} -> {:ok, doc}
      :error -> :error
    end
  end

  @doc "The JSON Schema type for one parameter type."
  @spec json_type(atom) :: map
  def json_type(:string), do: %{"type" => "string"}
  def json_type(:integer), do: %{"type" => "integer"}
  # :any still has to be a concrete JSON Schema under strict tool use, and
  # every value these tools store round-trips as a string.
  def json_type(:any), do: %{"type" => "string"}
end
