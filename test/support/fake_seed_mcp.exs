# A scripted stand-in for `seed mcp serve`: the same four JSON-RPC methods,
# the same newline framing, the same envelope-in-text-content result shape
# (mirrors open-seed-engine internal/mcptransport). Zero engine, zero repo.
#
# Behavior: os-1 is claimable once (token "tok-1"); a second claim is
# contention (exit 2); worker verbs with any other token are fenced out
# (exit 6); os-blocked cannot transition (exit 3); unknown ids are exit 4.
# Everything else is accepted and echoed back.

defmodule FakeSeedMcp do
  @tools ~w(task_ready task_get task_claim task_lease_renew task_release task_transition task_attach_evidence task_comment)

  def loop(state) do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      {:error, _} -> :ok
      line ->
        state = handle(String.trim(line), state)
        loop(state)
    end
  end

  defp handle("", state), do: state

  defp handle(line, state) do
    case JSON.decode(line) do
      {:ok, %{"method" => "initialize", "id" => id}} ->
        reply(id, %{protocolVersion: "2024-11-05", capabilities: %{tools: %{}}, serverInfo: %{name: "fake-seed", version: "1"}})
        state

      {:ok, %{"method" => "notifications/initialized"}} ->
        state

      {:ok, %{"method" => "tools/list", "id" => id}} ->
        reply(id, %{tools: for(n <- @tools, do: %{name: n, description: n, inputSchema: %{type: "object"}})})
        state

      {:ok, %{"method" => "tools/call", "id" => id, "params" => %{"name" => name, "arguments" => args}}} ->
        if name in @tools do
          {env, state} = tool(name, args, state)
          reply(id, %{content: [%{type: "text", text: JSON.encode!(env)}], isError: env.ok == false})
          state
        else
          # the engine answers an unknown tool with a JSON-RPC error, not an envelope
          IO.puts(JSON.encode!(%{jsonrpc: "2.0", id: id, error: %{code: -32602, message: "unknown tool " <> name}}))
          state
        end

      {:ok, %{"method" => m, "id" => id}} ->
        IO.puts(JSON.encode!(%{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "method not found: " <> m}}))
        state

      _ ->
        IO.puts(JSON.encode!(%{jsonrpc: "2.0", error: %{code: -32700, message: "parse error"}}))
        state
    end
  end

  defp reply(id, result), do: IO.puts(JSON.encode!(%{jsonrpc: "2.0", id: id, result: result}))

  defp ok(verb, fields), do: Map.merge(%{ok: true, schema_version: "1.0", verb: verb}, fields)
  defp refuse(verb, error, exit), do: %{ok: false, schema_version: "1.0", verb: verb, error: error, exit: exit}

  defp tool("task_ready", _args, state) do
    tasks = if state.claimed, do: [], else: [%{task: "os-1", title: "First card", state: "ready", priority: "P2"}]
    {ok("ready", %{tasks: tasks}), state}
  end

  defp tool("task_get", %{"task" => "os-1"}, state) do
    st = if state.claimed, do: "in_progress", else: "ready"
    {ok("get", %{task: "os-1", state: st, card: %{id: "os-1", state: st, title: "First card"}}), state}
  end

  defp tool("task_get", %{"task" => "os-blocked"}, state),
    do: {ok("get", %{task: "os-blocked", state: "blocked", card: %{id: "os-blocked", state: "blocked", title: "Parked"}}), state}

  defp tool("task_get", _, state), do: {refuse("get", "not_found", 4), state}

  defp tool("task_claim", %{"task" => "os-1"} = a, %{claimed: false} = state) do
    {ok("claim", %{task: "os-1", state: "in_progress", claim_token: "tok-1", actor: a["actor"], lease: a["lease"] || "60m"}), %{state | claimed: true}}
  end

  defp tool("task_claim", %{"task" => "os-1"}, state), do: {refuse("claim", "contention", 2), state}
  defp tool("task_claim", %{"task" => "os-blocked"}, state), do: {refuse("claim", "invalid_transition", 3), state}
  defp tool("task_claim", _, state), do: {refuse("claim", "not_found", 4), state}

  defp tool(verb, %{"task" => "os-blocked"}, state) when verb in ~w(task_transition task_release task_lease_renew),
    do: {refuse(String.trim_leading(verb, "task_"), "invalid_transition", 3), state}

  defp tool(verb, %{"token" => "tok-1"} = a, state) when verb in ~w(task_transition task_release task_lease_renew task_attach_evidence task_comment) do
    v = String.trim_leading(verb, "task_")
    state = if verb == "task_release", do: %{state | claimed: false}, else: state
    {ok(v, Map.new(a, fn {k, val} -> {String.to_atom(k), val} end)), state}
  end

  defp tool(verb, _a, state) when verb in ~w(task_transition task_release task_lease_renew task_attach_evidence task_comment),
    do: {refuse(String.trim_leading(verb, "task_"), "fenced_out", 6), state}

end

FakeSeedMcp.loop(%{claimed: false})
