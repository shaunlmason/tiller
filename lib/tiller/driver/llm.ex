defmodule Tiller.Driver.LLM do
  @moduledoc """
  A real driver: the model decides the next action.

  Built to `docs/designs/llm-driver.md`. One turn is one
  `POST /v1/messages` carrying the session's whitelist as the tool
  surface; the `tool_use` block that comes back becomes the quoted MFA
  term the session already evaluates. Nothing else in the harness
  changes, which was the point of reserving `Tiller.Driver`.

  Two properties the lab depends on:

    * **The grammar is the tool list.** The `tools` array is derived per
      request from the session's live whitelist
      (`Tiller.Session.current_whitelist/0`), so a `{:whitelist, list}`
      mutation is literally a different array: the branch's model plans
      without the tool rather than being refused after choosing it. The
      capability boundary and the prompt are the same object. A name the
      model invents still becomes an action the session refuses at
      `eval`, so the boundary never depends on the model behaving.
    * **The conversation is the context.** Driver context is the message
      list, so a fork at turn N is a truncation of it, taken from the
      snapshot the session parks before every turn. Nothing has to
      rebuild a conversation from events.

  The request asks for summarized thinking, so each event can carry why
  the model chose it. A context restored from a durable log may be older
  than that field, so it is read and written through `Map`: an upgrade
  must not kill the runs it inherits. The raw chain of thought is never returned by the
  API; the summary is, and only when asked (`display` defaults to
  `omitted`, whose thinking blocks arrive with empty text). Blocks are
  echoed back unchanged with the rest of the assistant turn, which is
  what the API requires of a conversation continuing on the same model.

  A run ends by calling `done/1`, so the final answer is an action
  `Tiller.Race` can compare two runs on. A reply with no tool call is
  treated as `done(text)`. Refusals, exhausted caps and API failures end
  the run through `{:halt, reason}`, which the log records as
  `{:halted, turns, reason}`.

  No SDK: `:httpc` and the built-in `JSON`, so `lib/tiller` gains no
  dependency. `api.base_url` is the seam the tests point at
  `Tiller.FakeMessages` instead of the network.
  """
  @behaviour Tiller.Driver

  alias Tiller.Driver.LLM.Wire

  @default_model "claude-opus-5"
  @default_display :summarized
  @default_max_turns 12
  @default_max_input_tokens 200_000
  @max_tokens 4_096
  @retry_status [429, 500, 502, 503, 529]
  @retries 2

  @default_system """
  You drive a tiller session. The tools you are given are the only way you can act.
  Call exactly one tool per turn. Every tool result comes back as an Elixir term: a
  result that reads {:error, ...} means the call failed or was refused, and you should
  adapt rather than repeat it. When the goal is met, or when no tool can advance it,
  call done with a one-sentence summary.
  """

  @subagent_system """
  You are a subagent in a tiller session. You were given one goal by the agent that
  spawned you, and the tools you are given are the only way you can act. Call exactly
  one tool per turn. Every tool result comes back as an Elixir term: a result that
  reads {:error, ...} means the call failed or was refused, and you should adapt rather
  than repeat it. You cannot spawn agents of your own. When the goal is met, or when no
  tool can advance it, call done with a one-sentence summary: that summary is what the
  agent waiting on you receives.
  """

  @type t :: %{
          model: String.t(),
          system: String.t(),
          whitelist: [{atom, arity}],
          messages: [map],
          effort: atom | nil,
          display: :summarized | :omitted,
          rationale: String.t() | nil,
          max_turns: pos_integer,
          max_input_tokens: pos_integer,
          turn: non_neg_integer,
          usage: %{input: non_neg_integer, output: non_neg_integer},
          api: map,
          pending: String.t() | nil,
          status: :running | :finished
        }

  @doc """
  A context for `goal`.

  Options: `:whitelist` (what to offer, default the root whitelist),
  `:model`, `:system`, `:effort` (default `:low`), `:display`
  (`:summarized` by default, `:omitted` to stop asking for the
  reasoning), `:max_turns`, `:max_input_tokens`, `:base_url` (default the
  public API), `:api_key` (default `ANTHROPIC_API_KEY`), `:timeout`.
  """
  @spec context(String.t(), keyword) :: t
  def context(goal, opts \\ []) do
    whitelist = Keyword.get(opts, :whitelist, Tiller.Actions.root_whitelist())

    %{
      model: Keyword.get(opts, :model, @default_model),
      system: Keyword.get(opts, :system, @default_system),
      # The fallback when there is no session around it (unit tests); a
      # session's own whitelist wins, so a fork's mutation takes effect.
      whitelist: whitelist,
      messages: [%{"role" => "user", "content" => goal}],
      effort: Keyword.get(opts, :effort, :low),
      display: Keyword.get(opts, :display, @default_display),
      # the reasoning behind the action last returned, for the log
      rationale: nil,
      max_turns: Keyword.get(opts, :max_turns, @default_max_turns),
      max_input_tokens: Keyword.get(opts, :max_input_tokens, @default_max_input_tokens),
      turn: 0,
      usage: %{input: 0, output: 0},
      api: %{
        base_url: Keyword.get(opts, :base_url, "https://api.anthropic.com"),
        api_key: Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY"),
        timeout: Keyword.get(opts, :timeout, 120_000)
      },
      pending: nil,
      status: :running
    }
  end

  ## Tiller.Driver

  @impl true
  def next_action(%{status: :finished}), do: :halt

  def next_action(%{turn: turn, max_turns: max}) when turn >= max, do: {:halt, :max_turns}

  def next_action(%{usage: %{input: used}, max_input_tokens: cap}) when used >= cap,
    do: {:halt, :budget}

  def next_action(ctx) do
    case post(ctx) do
      {:ok, body} -> decide(ctx, body)
      {:error, reason} -> {:halt, {:api, reason}}
    end
  end

  @doc "What this run has spent so far, input and output tokens."
  @impl true
  def usage(%{usage: usage}), do: usage

  @doc """
  A child that pursues `goal`, on the same model and endpoint as this
  run and with none of its conversation.

  What the child costs is billed to the child: it reports its own usage,
  and the parent's tally is untouched by it. The whitelist it is offered
  comes from the session the child runs in, which is the subagent one, so
  the depth limit holds without this having to say so.
  """
  @impl true
  def subagent(ctx, goal) when is_binary(goal) do
    {__MODULE__,
     context(goal,
       whitelist: Tiller.Actions.sub_whitelist(),
       system: @subagent_system,
       model: ctx.model,
       effort: ctx.effort,
       display: Map.get(ctx, :display, @default_display),
       max_turns: ctx.max_turns,
       max_input_tokens: ctx.max_input_tokens,
       base_url: ctx.api.base_url,
       api_key: ctx.api.api_key,
       timeout: ctx.api.timeout
     )}
  end

  @doc """
  The summarized thinking behind the action just decided.

  `nil` when the model returned none: a response can carry no thinking
  block at all, and one asked for with `display: :omitted` carries a
  block with no text.
  """
  @impl true
  def rationale(ctx), do: Map.get(ctx, :rationale)

  @doc """
  How a result reaches the model: the answer to the call it just made.

  The assistant turn was appended when the action was decided, so this
  appends only the matching `tool_result`. With no call outstanding (the
  synthesized `done` of a text-only reply) there is nothing to answer.
  """
  @impl true
  def observe(%{pending: nil} = ctx, _action, _result), do: ctx

  def observe(%{pending: id} = ctx, _action, result) do
    %{
      ctx
      | messages:
          ctx.messages ++ [%{"role" => "user", "content" => [Wire.tool_result(id, result)]}],
        pending: nil,
        turn: ctx.turn + 1
    }
  end

  @doc """
  A `{:result_override, turn, result}` fork: the branch remembers a
  different answer at `turn`.

  History is append-only on the API, and editing a turn invalidates every
  later `thinking` block, so those are stripped from the assistant turns
  after the edit. The branch continues without the reasoning they
  carried, which is the documented cost of this axis.
  """
  @impl true
  def override(ctx, turn, result) do
    case tool_result_index(ctx.messages, turn) do
      nil ->
        ctx

      i ->
        messages =
          ctx.messages
          |> List.update_at(i, &rewrite_result(&1, result))
          |> strip_thinking_after(i)

        %{ctx | messages: messages}
    end
  end

  # messages are [goal, assistant(0), result(0), assistant(1), result(1), ...],
  # so turn N's result sits at 2N + 2 when it is there at all.
  defp tool_result_index(messages, turn) do
    i = 2 * turn + 2

    case Enum.at(messages, i) do
      %{"role" => "user", "content" => [%{"type" => "tool_result"} | _]} -> i
      _ -> nil
    end
  end

  defp rewrite_result(%{"content" => [%{"tool_use_id" => id} | _]} = message, result) do
    %{message | "content" => [Wire.tool_result(id, result)]}
  end

  defp strip_thinking_after(messages, i) do
    Enum.with_index(messages, fn message, j ->
      if j > i, do: strip_thinking(message), else: message
    end)
  end

  defp strip_thinking(%{"role" => "assistant", "content" => content} = message)
       when is_list(content) do
    %{
      message
      | "content" => Enum.reject(content, &(&1["type"] in ["thinking", "redacted_thinking"]))
    }
  end

  defp strip_thinking(message), do: message

  ## deciding

  defp decide(ctx, body) do
    ctx = count(ctx, body)
    content = Map.get(body, "content") || []
    # Read before the branch below, so a halt does not carry the last
    # turn's reasoning forward as if it explained this one. Put, not a
    # struct update: a context read back from a durable log can predate
    # the field, and a resumed run must not die on the key.
    ctx = Map.put(ctx, :rationale, Wire.thinking(content))

    case Wire.decode(body) do
      {:tool_use, id, action} ->
        ctx = %{ctx | messages: ctx.messages ++ [assistant(content)], pending: id}
        {:action, action, finish_if_done(ctx, action)}

      # No tool call: the model's answer is the run's last action, so two
      # runs can be compared on where they ended rather than on the last
      # incidental call.
      {:text, text} ->
        ctx = %{ctx | messages: ctx.messages ++ [assistant(content)], pending: nil}
        {:action, Tiller.Driver.action(:done, [text]), %{ctx | status: :finished}}

      {:refusal, category} ->
        {:halt, {:refusal, category}}

      {:stop, reason} ->
        {:halt, reason}
    end
  end

  defp finish_if_done(ctx, {:call, _m, :done, _args}), do: %{ctx | status: :finished}
  defp finish_if_done(ctx, _action), do: ctx

  defp assistant(content), do: %{"role" => "assistant", "content" => content}

  defp count(ctx, body) do
    usage = Map.get(body, "usage") || %{}

    %{
      ctx
      | usage: %{
          input: ctx.usage.input + (usage["input_tokens"] || 0),
          output: ctx.usage.output + (usage["output_tokens"] || 0)
        }
    }
  end

  ## the wire

  @doc false
  def request(ctx) do
    base = %{
      "model" => ctx.model,
      "max_tokens" => @max_tokens,
      "system" => ctx.system,
      "tools" => Wire.tools(Tiller.Session.current_whitelist() || ctx.whitelist),
      # one action per turn is what the session's loop expects
      "tool_choice" => %{"type" => "auto", "disable_parallel_tool_use" => true},
      # Adaptive is the only mode this model takes, and `display` is what
      # decides whether the thinking blocks it returns carry any text. A
      # context older than the field asks for the current default, like a
      # run started today.
      "thinking" => %{"type" => "adaptive", "display" => display(ctx)},
      "messages" => ctx.messages
    }

    if ctx.effort,
      do: Map.put(base, "output_config", %{"effort" => to_string(ctx.effort)}),
      else: base
  end

  defp display(ctx) do
    to_string(Map.get(ctx, :display, @default_display) || :omitted)
  end

  defp post(ctx), do: post(ctx, 0)

  defp post(ctx, attempt) do
    :ok = ensure_started()
    url = String.to_charlist(ctx.api.base_url <> "/v1/messages")
    body = JSON.encode!(request(ctx))

    headers = [
      {~c"x-api-key", String.to_charlist(ctx.api.api_key || "")},
      {~c"anthropic-version", ~c"2023-06-01"}
    ]

    http_opts = [timeout: ctx.api.timeout] ++ ssl_opts(ctx.api.base_url)

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, http_opts,
           body_format: :binary
         ) do
      {:ok, {{_v, 200, _r}, _headers, response}} ->
        decode_body(response)

      {:ok, {{_v, status, _r}, _headers, response}} when status in @retry_status ->
        retry(ctx, attempt, {:status, status, brief(response)})

      {:ok, {{_v, status, _r}, _headers, response}} ->
        {:error, {:status, status, brief(response)}}

      {:error, reason} ->
        retry(ctx, attempt, reason)
    end
  end

  defp retry(_ctx, attempt, reason) when attempt >= @retries, do: {:error, reason}

  defp retry(ctx, attempt, _reason) do
    Process.sleep(100 * (attempt + 1))
    post(ctx, attempt + 1)
  end

  defp decode_body(response) do
    case JSON.decode(response) do
      {:ok, body} when is_map(body) -> {:ok, body}
      _ -> {:error, {:bad_body, brief(response)}}
    end
  end

  defp brief(response) when is_binary(response), do: String.slice(response, 0, 200)
  defp brief(other), do: inspect(other)

  # Loopback (the fake API) is plain http; the public API is https and, in
  # a sandbox, may be reached through a proxy.
  defp ssl_opts("https" <> _) do
    [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3]]
  end

  defp ssl_opts(_), do: []

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end
end
