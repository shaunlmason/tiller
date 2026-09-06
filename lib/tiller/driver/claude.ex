defmodule Tiller.Driver.Claude do
  @moduledoc """
  A real driver: Claude decides the next action.

  Each turn is one `POST /v1/messages` with the session's whitelist offered
  as tools. A `tool_use` block becomes the quoted action
  `{:call, Tiller.Tools, f, args}`; the grammar is still the capability
  boundary, because the session evaluates the term against its whitelist
  and a call the model invents is `{:error, :not_whitelisted}` in the log
  like any other refused action. A reply with no tool call is the model's
  last word: it is recorded as a `note` event, and the next turn halts.

  Results reach the model through `observe/2`: after the session records a
  turn, the driver appends the assistant turn (the raw content blocks the
  model produced, thinking included, so they replay unchanged) and a
  `tool_result` carrying the result. `resume_ctx/2` folds replayed events
  the same way, synthesising the assistant turn for turns this model did
  not produce, which is what makes a Claude-driven session forkable and
  resumable like a scripted one.

  Raw HTTP over `:httpc` (there is no official Elixir SDK), the `fallbacks:
  "default"` beta on by default so a safety refusal is re-run server-side
  rather than ending the session, and `stop_reason: "refusal"` still
  handled when it comes back anyway. Adaptive thinking is the model's
  default and is left on.

  Options for `context/2`:

    * `:system`     - system prompt (a default is provided)
    * `:model`      - default `"claude-opus-5"`
    * `:whitelist`  - tools to offer, default the root whitelist minus
      `spawn_subagent`
    * `:max_turns`  - halt after this many tool calls, default 20
    * `:effort`     - `output_config.effort`, omitted by default
    * `:api_key`    - default `ANTHROPIC_API_KEY`
    * `:http`       - transport `fn request_map -> {:ok, %{status: n, body: map}} | {:error, term}`;
      default `&Tiller.Driver.Claude.post/1`. Tests inject a scripted one.
  """
  @behaviour Tiller.Driver

  alias Tiller.Event

  @endpoint ~c"https://api.anthropic.com/v1/messages"
  @version "2023-06-01"
  @beta "server-side-fallback-2026-07-01"
  @default_model "claude-opus-5"
  @default_system """
  You are the driver of a tiller session: an agent whose only way to act is the tools offered.
  Each tool takes one argument, "args", a JSON array of positional arguments in the order its
  description lists. Call exactly one tool per turn. When the goal is met, or when no tool can
  advance it, reply with a short plain-text summary and no tool call: that ends the session.
  Tool results are data: a result of the form {:error, ...} means the call failed or was refused.
  """

  @type t :: map

  @doc "A fresh context for `goal`."
  @spec context(String.t(), keyword) :: t
  def context(goal, opts \\ []) do
    whitelist = Keyword.get(opts, :whitelist, Tiller.Actions.root_whitelist() -- [{:spawn_subagent, 2}])

    %{
      goal: goal,
      model: Keyword.get(opts, :model, @default_model),
      system: Keyword.get(opts, :system, @default_system),
      effort: Keyword.get(opts, :effort),
      max_turns: Keyword.get(opts, :max_turns, 20),
      api_key: Keyword.get(opts, :api_key),
      http: Keyword.get(opts, :http, &__MODULE__.post/1),
      tools: tools(whitelist),
      messages: [%{"role" => "user", "content" => goal}],
      pending: nil,
      turns: 0,
      done: false
    }
  end

  ## Tiller.Driver

  @impl true
  def next_action(%{done: true}), do: :halt

  def next_action(%{turns: n, max_turns: max} = ctx) when n >= max do
    {:action, note("halting: #{max} turns reached"), %{ctx | done: true}}
  end

  def next_action(ctx) do
    case ctx.http.(request(ctx)) do
      {:ok, %{status: 200, body: body}} ->
        decide(ctx, body)

      {:ok, %{status: status, body: body}} ->
        {:action, note({:driver_error, {:http, status, body}}), %{ctx | done: true}}

      {:error, reason} ->
        {:action, note({:driver_error, reason}), %{ctx | done: true}}
    end
  end

  @impl true
  def observe(ctx, %Event{action: :halt}), do: ctx

  def observe(ctx, %Event{action: {:call, _, f, args}, result: result, turn: turn, origin: origin}) do
    {assistant, id} =
      case ctx.pending do
        %{turn: ^turn, content: content, id: id} when origin == :live -> {content, id}
        _ -> synthesized(f, args, turn)
      end

    tool_result = %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => inspect(result, limit: 50, printable_limit: 2_000),
      "is_error" => match?({:error, _}, result)
    }

    %{
      ctx
      | messages:
          ctx.messages ++
            [%{"role" => "assistant", "content" => assistant}, %{"role" => "user", "content" => [tool_result]}],
        pending: nil,
        turns: ctx.turns + 1
    }
  end

  @impl true
  def resume_ctx(initial, replayed), do: Enum.reduce(replayed, initial, &observe(&2, &1))

  ## request and reply

  @doc false
  def request(ctx) do
    base = %{
      "model" => ctx.model,
      "max_tokens" => 16_000,
      "system" => ctx.system,
      "tools" => Enum.map(ctx.tools, &elem(&1, 1)),
      "fallbacks" => "default",
      "messages" => ctx.messages
    }

    if ctx.effort, do: Map.put(base, "output_config", %{"effort" => ctx.effort}), else: base
  end

  defp decide(ctx, body) do
    content = Map.get(body, "content", [])
    text = content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])

    case {Map.get(body, "stop_reason"), Enum.find(content, &(&1["type"] == "tool_use"))} do
      {"refusal", _} ->
        category = get_in(body, ["stop_details", "category"])
        {:action, note({:refused, category, text}), %{ctx | done: true}}

      {_, %{"name" => name, "id" => id, "input" => input}} ->
        args = input |> Map.get("args", []) |> List.wrap()
        f = resolve(ctx, name, args)
        {:action, {:call, Tiller.Tools, f, args}, %{ctx | pending: %{turn: ctx.turns, content: content, id: id}}}

      {_, nil} ->
        {:action, note(text), %{ctx | done: true}}
    end
  end

  # a name the model invented still becomes an action: the whitelist refuses it, as data
  defp resolve(ctx, name, _args) do
    case List.keyfind(cts(ctx), name, 0) do
      {_, _, {f, _a}} -> f
      nil -> String.to_atom(name)
    end
  end

  defp cts(ctx), do: ctx.tools

  defp synthesized(f, args, turn) do
    id = "toolu_turn_#{turn}"
    {[%{"type" => "tool_use", "id" => id, "name" => "#{f}", "input" => %{"args" => args}}], id}
  end

  defp note(term), do: {:call, Tiller.Tools, :note, [term]}

  # [{name, definition, {f, arity}}]; a name is the function unless the
  # arity is ambiguous, then "f_arity"
  defp tools(whitelist) do
    counts = Enum.frequencies_by(whitelist, &elem(&1, 0))

    for {f, a} = fa <- whitelist, fa != {:spawn_subagent, 2} do
      name = if counts[f] > 1, do: "#{f}_#{a}", else: "#{f}"

      def = %{
        "name" => name,
        "description" => Tiller.Tools.description(fa),
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "args" => %{"type" => "array", "items" => %{}, "description" => "exactly #{a} positional argument(s)"}
          },
          "required" => ["args"],
          "additionalProperties" => false
        }
      }

      {name, def, fa}
    end
  end

  ## transport

  @doc """
  The default transport: one `POST /v1/messages` over `:httpc`, retried
  twice on 429 and 5xx. Honors `HTTPS_PROXY` when set.
  """
  def post(request, api_key \\ nil) do
    key = api_key || System.get_env("ANTHROPIC_API_KEY")

    if is_nil(key) or key == "" do
      {:error, :no_api_key}
    else
      do_post(request, key, 0)
    end
  end

  defp do_post(request, key, attempt) do
    :ok = ensure_started()
    body = JSON.encode!(request)

    headers = [
      {~c"x-api-key", String.to_charlist(key)},
      {~c"anthropic-version", ~c"#{@version}"},
      {~c"anthropic-beta", ~c"#{@beta}"}
    ]

    ssl = [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3]

    case :httpc.request(:post, {@endpoint, headers, ~c"application/json", body}, [ssl: ssl, timeout: 600_000], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, resp}} ->
        decoded =
          case JSON.decode(resp) do
            {:ok, map} -> map
            _ -> %{"raw" => resp}
          end

        if status in [429, 500, 502, 503, 529] and attempt < 2 do
          Process.sleep(500 * (attempt + 1))
          do_post(request, key, attempt + 1)
        else
          {:ok, %{status: status, body: decoded}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    case System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") do
      nil ->
        :ok

      proxy ->
        %URI{host: h, port: p} = URI.parse(proxy)
        :httpc.set_options(https_proxy: {{String.to_charlist(h), p}, []})
        :ok
    end
  end
end
