defmodule Tiller.Driver.LLM.Wire do
  @moduledoc """
  The Messages API on and off the wire: pure functions over maps, no HTTP.

  This is the go/no-go spike from `docs/designs/llm-driver.md` ("The
  Assignment"): if the mapping between a whitelist and a `tools` array,
  and between a `tool_use` block and a quoted MFA term, is not obvious,
  the tool surface needs a different shape. It was obvious, and this is
  it.

  Named JSON in, positional args out. `Tiller.Tools.Schema` is the only
  place that knows a parameter's name or order, so a tool gains an
  argument in one table and the request, the decode, and the session's
  `eval` all follow.
  """

  alias Tiller.Tools.Schema

  @type decoded ::
          {:tool_use, String.t(), Tiller.Event.action()}
          | {:text, String.t()}
          | {:refusal, term}
          | {:stop, atom}

  @doc """
  One tool definition per whitelisted entry that has a schema, sorted by
  name so the array is byte-stable across requests (and so a branch's
  prefix stays cacheable).

  `strict: true` with `additionalProperties: false` and every parameter
  required is what makes `input` reliable enough to map positionally.
  """
  @spec tools([{atom, arity}]) :: [map]
  def tools(whitelist) do
    whitelist
    |> Enum.filter(&Schema.callable?/1)
    |> Enum.map(&definition/1)
    |> Enum.sort_by(& &1["name"])
  end

  defp definition({name, _arity} = fa) do
    {:ok, params} = Schema.params(fa)
    {:ok, doc} = Schema.description(fa)

    %{
      "name" => to_string(name),
      "description" => doc,
      "strict" => true,
      "input_schema" => %{
        "type" => "object",
        "properties" => Map.new(params, fn {p, t} -> {to_string(p), Schema.json_type(t)} end),
        "required" => Enum.map(params, fn {p, _t} -> to_string(p) end),
        "additionalProperties" => false
      }
    }
  end

  @doc """
  What one API response means.

  `stop_reason` is read before `content`, because a refusal is a
  successful HTTP 200 whose content may be empty or partial. A
  `tool_use` block becomes `{:call, Tiller.Tools, f, args}` with `args`
  in schema order; text with no tool call is the model's final answer;
  anything else is a stop with its reason.
  """
  @spec decode(map) :: decoded
  def decode(%{"stop_reason" => "refusal"} = body) do
    {:refusal, get_in(body, ["stop_details", "category"]) || :unknown}
  end

  def decode(body) do
    content = Map.get(body, "content") || []

    case Enum.find(content, &(&1["type"] == "tool_use")) do
      %{"id" => id, "name" => name, "input" => input} ->
        {:tool_use, id, action(name, input)}

      nil ->
        case Map.get(body, "stop_reason") do
          reason when reason in [nil, "end_turn", "tool_use", "stop_sequence"] ->
            {:text, text(content)}

          other ->
            {:stop, String.to_atom(other)}
        end
    end
  end

  @doc "Every text block, joined. The model's answer when it called no tool."
  @spec text([map]) :: String.t()
  def text(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  @doc """
  The tool result to send back for `id`.

  `{:error, _}` sets `is_error`, which is how the model learns a call was
  refused or crashed. Values are rendered with `inspect/2` rather than
  JSON: a result is an Elixir term (`{:refused, envelope}`, an exception
  struct), and the model reads them as text either way.
  """
  @spec tool_result(String.t(), Tiller.Event.result()) :: map
  def tool_result(id, result) do
    %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => render(result),
      "is_error" => match?({:error, _}, result)
    }
  end

  defp render({:ok, v}) when is_binary(v), do: v
  defp render({:ok, v}), do: inspect(v, limit: 50, printable_limit: 4_000)
  defp render({:error, r}), do: inspect(r, limit: 50, printable_limit: 4_000)
  defp render(other), do: inspect(other, limit: 50, printable_limit: 4_000)

  # A name the model invented still becomes an action; the whitelist
  # refuses it at eval and the refusal is data in the log, which is the
  # same path a removed tool takes.
  defp action(name, input) do
    f = String.to_atom(name)
    {:call, Tiller.Tools, f, args_for(f, input)}
  end

  defp args_for(f, input) when is_map(input) do
    case Enum.find(Schema.callable(), fn {n, _a} -> n == f end) do
      nil ->
        Map.values(input)

      fa ->
        {:ok, params} = Schema.params(fa)
        Enum.map(params, fn {p, _t} -> Map.get(input, to_string(p)) end)
    end
  end

  defp args_for(_f, _input), do: []
end
