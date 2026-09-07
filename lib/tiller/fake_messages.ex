defmodule Tiller.FakeMessages do
  @moduledoc """
  A scripted stand-in for `POST /v1/messages`, on the Bandit dependency
  the lab already has.

  This is what lets the LLM driver be exercised end to end with no
  network and no credential (`docs/designs/llm-driver.md`): point
  `api.base_url` here instead of at the API. It answers from a script,
  records every request, and validates the request shape, so drift in
  what the driver sends fails a test rather than quietly changing what
  the model would see.

      {:ok, api} = Tiller.FakeMessages.start([
        Tiller.FakeMessages.tool_use("put", %{"key" => "g", "value" => "hi"}),
        Tiller.FakeMessages.done("stored it")
      ])

      Tiller.Driver.LLM.context("store a greeting", base_url: api.base_url)

  A script is a list of responses, taken in order, or a function of the
  request, which is how a test says "when `spend` is refused, answer with
  `get`". A list that runs out answers with a plain end-of-turn.
  """
  @behaviour Plug

  import Plug.Conn

  @doc """
  Start a fake API on a free loopback port.

  Returns `{:ok, %{pid: pid, base_url: url, agent: pid}}`. Stop it with
  `stop/1`; a test that leaves it running loses nothing but the port.
  """
  @spec start(list | function) :: {:ok, map}
  def start(script) do
    {:ok, agent} = Agent.start_link(fn -> %{script: script, requests: []} end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, agent},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{pid: server, agent: agent, base_url: "http://127.0.0.1:#{port}"}}
  end

  @doc """
  Stop a fake API. Tolerant of a server already on its way down, so a
  test's teardown never fails after the test itself passed.
  """
  def stop(%{pid: server, agent: agent}) do
    Enum.each([server, agent], &shut_down/1)
    :ok
  end

  defp shut_down(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 2_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc "Every request the driver sent, oldest first."
  @spec requests(map) :: [map]
  def requests(%{agent: agent}), do: Agent.get(agent, & &1.requests)

  ## response builders

  @doc "A response that calls one tool."
  def tool_use(name, input, opts \\ []) do
    text = Keyword.get(opts, :text)
    id = Keyword.get(opts, :id, "toolu_" <> Integer.to_string(System.unique_integer([:positive])))

    blocks =
      if(text, do: [%{"type" => "text", "text" => text}], else: []) ++
        [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]

    %{"stop_reason" => "tool_use", "content" => blocks, "usage" => usage(opts)}
  end

  @doc "A response that calls `done`, the way a run is meant to end."
  def done(summary, opts \\ []), do: tool_use("done", %{"summary" => summary}, opts)

  @doc "A response with text and no tool call: the driver treats it as `done(text)`."
  def text(text, opts \\ []) do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => usage(opts)
    }
  end

  @doc "A safety refusal: HTTP 200, no content."
  def refusal(category, opts \\ []) do
    %{
      "stop_reason" => "refusal",
      "stop_details" => %{"category" => category},
      "content" => [],
      "usage" => usage(opts)
    }
  end

  @doc "A raw HTTP status instead of a body: `{:status, 429}` for a retry test."
  def status(code), do: {:status, code}

  defp usage(opts) do
    %{
      "input_tokens" => Keyword.get(opts, :input_tokens, 10),
      "output_tokens" => Keyword.get(opts, :output_tokens, 5)
    }
  end

  @doc "The text of the last tool result in a request, for a scripted branch."
  @spec last_result(map) :: String.t() | nil
  def last_result(request) do
    request
    |> Map.get("messages", [])
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"content" => [%{"type" => "tool_result", "content" => c} | _]} -> c
      _ -> nil
    end)
  end

  ## Plug

  @impl true
  def init(agent), do: agent

  @impl true
  def call(%{method: "POST", request_path: "/v1/messages"} = conn, agent) do
    {:ok, body, conn} = read_body(conn)
    request = JSON.decode!(body)
    Agent.update(agent, &%{&1 | requests: &1.requests ++ [request]})

    case validate(request) do
      :ok ->
        case next(agent, request) do
          {:status, code} -> json(conn, code, %{"error" => %{"message" => "scripted #{code}"}})
          response -> json(conn, 200, response)
        end

      {:error, message} ->
        json(conn, 400, %{"error" => %{"type" => "invalid_request_error", "message" => message}})
    end
  end

  def call(conn, _agent), do: json(conn, 404, %{"error" => %{"message" => "not found"}})

  # Catches request drift: a change that would alter what a real model
  # sees fails here instead of passing silently.
  defp validate(request) do
    cond do
      get_in(request, ["tool_choice", "type"]) != "auto" ->
        {:error, "tool_choice must be auto; one action per turn"}

      not is_list(request["tools"]) or request["tools"] == [] ->
        {:error, "no tools offered"}

      Enum.any?(request["tools"], &(&1["strict"] != true)) ->
        {:error, "every tool must be strict"}

      unknown = Enum.find(request["tools"], &(not known?(&1["name"]))) ->
        {:error, "tool #{unknown["name"]} has no schema"}

      true ->
        :ok
    end
  end

  defp known?(name) do
    Enum.any?(Tiller.Tools.Schema.callable(), fn {f, _a} -> to_string(f) == name end)
  end

  defp next(agent, request) do
    Agent.get_and_update(agent, fn
      %{script: fun} = s when is_function(fun, 1) ->
        {fun.(request), s}

      %{script: [head | rest]} = s ->
        {head, %{s | script: rest}}

      %{script: []} = s ->
        {text("nothing scripted"), s}
    end)
  end

  defp json(conn, code, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(code, JSON.encode!(body))
  end
end
