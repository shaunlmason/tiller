defmodule Tiller.Seed do
  @moduledoc """
  MCP stdio client for the open-seed engine (`seed mcp serve`).

  One GenServer owns one engine process. The engine exposes one MCP tool
  per task-port verb (task_ready, task_claim, task_transition, ...) and
  routes every call through the same service path as its CLI: same
  fencing, same transition table, same envelopes. This client speaks the
  four JSON-RPC methods the engine implements (initialize,
  notifications/initialized, tools/list, tools/call), newline-delimited,
  with no SDK dependency on either side.

  The port stays the only thing that touches a coordination store; tiller
  only ever calls it. Refusals (claim contention, invalid transition,
  fenced-out token, ...) are data: `call/4` returns `{:refused, envelope}`
  with the engine's `error` and `exit` fields intact. Only transport
  faults raise, so a session logs them as `{:error, _}` like any other
  tool crash.

  Options:

    * `:command` - argv for the engine, default `["scripts/seed", "mcp", "serve"]`.
      The first element is resolved with `System.find_executable/1` when it
      is not a path.
    * `:cd`      - directory to run it in (the instantiated open-seed repo).
    * `:actor`   - the identity tools assert on every call.
    * `:name`    - registered name, default `Tiller.Seed`.
    * `:timeout` - per-call timeout in ms, default 30_000.
  """
  use GenServer

  defmodule TransportError do
    defexception [:reason]
    @impl true
    def message(%{reason: r}), do: "seed transport: #{inspect(r)}"
  end

  @default_command ["scripts/seed", "mcp", "serve"]
  @max_line 1_048_576
  @handshake_timeout 10_000

  ## Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The actor this client asserts."
  def actor(client \\ __MODULE__), do: GenServer.call(client, :actor)

  @doc "tools/list: the verb surface the engine advertises."
  def tools(client \\ __MODULE__), do: GenServer.call(client, :tools)

  @doc """
  tools/call. Returns `{:ok, envelope}` when the port accepted the verb,
  `{:refused, envelope}` when it refused (envelope carries `"error"` and
  `"exit"`). Raises `TransportError` on a JSON-RPC error, a dead engine,
  or a timeout.
  """
  def call(client, tool, args, timeout \\ nil) do
    case GenServer.call(client, {:call, tool, args, timeout}, :infinity) do
      {:ok, env} -> {:ok, env}
      {:refused, env} -> {:refused, env}
      {:error, reason} -> raise TransportError, reason: reason
    end
  end

  ## Server

  @impl true
  def init(opts) do
    argv = Keyword.get(opts, :command, @default_command)
    dir = Keyword.get(opts, :cd, File.cwd!())
    actor = Keyword.get(opts, :actor, "tiller")
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, exe} <- resolve(hd(argv), dir),
         port <- open_port(exe, tl(argv), dir),
         {:ok, _} <- handshake(port) do
      {:ok, %{port: port, actor: actor, timeout: timeout, next_id: 1, pending: %{}, buf: ""}}
    else
      {:error, reason} -> {:stop, {:seed_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:actor, _from, s), do: {:reply, s.actor, s}

  def handle_call(:tools, from, s) do
    send_request(s, "tools/list", %{}, from, fn
      %{"result" => %{"tools" => tools}} -> {:ok, tools}
      other -> {:error, {:bad_reply, other}}
    end)
  end

  def handle_call({:call, tool, args, timeout}, from, s) do
    params = %{
      name: to_string(tool),
      arguments: Map.new(args, fn {k, v} -> {to_string(k), v} end)
    }

    send_request(s, "tools/call", params, from, &decode_tool_result/1, timeout || s.timeout)
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = s) do
    {:noreply, %{s | buf: s.buf <> chunk}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = s) do
    line = s.buf <> chunk
    {:noreply, dispatch_line(%{s | buf: ""}, line)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
    for {_id, {from, _decode, timer}} <- s.pending do
      cancel(timer)
      GenServer.reply(from, {:error, {:engine_exited, status}})
    end

    {:stop, {:shutdown, {:engine_exited, status}}, %{s | pending: %{}}}
  end

  def handle_info({:timeout, id}, s) do
    case Map.pop(s.pending, id) do
      {nil, _} ->
        {:noreply, s}

      {{from, _decode, _timer}, pending} ->
        GenServer.reply(from, {:error, {:timeout, id}})
        {:noreply, %{s | pending: pending}}
    end
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    if port in Port.list(), do: Port.close(port)
    :ok
  end

  ## Internals

  defp send_request(s, method, params, from, decode, timeout \\ nil) do
    id = s.next_id
    Port.command(s.port, encode(%{jsonrpc: "2.0", id: id, method: method, params: params}))
    timer = Process.send_after(self(), {:timeout, id}, timeout || s.timeout)
    pending = Map.put(s.pending, id, {from, decode, timer})
    {:noreply, %{s | next_id: id + 1, pending: pending}}
  end

  defp dispatch_line(s, ""), do: s

  defp dispatch_line(s, line) do
    case JSON.decode(line) do
      {:ok, %{"id" => id} = msg} when is_integer(id) ->
        case Map.pop(s.pending, id) do
          {nil, _} ->
            s

          {{from, decode, timer}, pending} ->
            cancel(timer)
            GenServer.reply(from, reply_for(msg, decode))
            %{s | pending: pending}
        end

      _ ->
        # A notification, an id-less error, or a line that is not JSON:
        # nothing is waiting on it.
        s
    end
  end

  defp reply_for(%{"error" => %{"code" => code, "message" => m}}, _decode),
    do: {:error, {:rpc, code, m}}

  defp reply_for(msg, decode), do: decode.(msg)

  # tools/call results wrap one text content item holding the port
  # envelope as JSON; isError mirrors the envelope's ok=false.
  defp decode_tool_result(%{"result" => %{"content" => [%{"text" => text} | _]} = result}) do
    env =
      case JSON.decode(text) do
        {:ok, map} when is_map(map) -> map
        _ -> %{"raw" => text}
      end

    if Map.get(result, "isError", false) or Map.get(env, "ok") == false,
      do: {:refused, env},
      else: {:ok, env}
  end

  defp decode_tool_result(other), do: {:error, {:bad_reply, other}}

  defp handshake(port) do
    Port.command(port, encode(%{jsonrpc: "2.0", id: 0, method: "initialize", params: %{}}))

    case read_line(port, "", @handshake_timeout) do
      {:ok, line} ->
        case JSON.decode(line) do
          {:ok, %{"id" => 0, "result" => info}} ->
            Port.command(port, encode(%{jsonrpc: "2.0", method: "notifications/initialized"}))
            {:ok, info}

          {:ok, other} ->
            {:error, {:bad_initialize, other}}

          _ ->
            {:error, {:bad_initialize, line}}
        end

      {:error, _} = e ->
        e
    end
  end

  defp read_line(port, acc, timeout) do
    receive do
      {^port, {:data, {:noeol, c}}} -> read_line(port, acc <> c, timeout)
      {^port, {:data, {:eol, c}}} -> {:ok, acc <> c}
      {^port, {:exit_status, st}} -> {:error, {:engine_exited, st}}
    after
      timeout -> {:error, :handshake_timeout}
    end
  end

  defp open_port(exe, args, dir) do
    Port.open({:spawn_executable, exe}, [
      :binary,
      :exit_status,
      :use_stdio,
      {:line, @max_line},
      {:args, args},
      {:cd, dir}
    ])
  end

  defp resolve(cmd, dir) do
    cond do
      String.contains?(cmd, "/") ->
        path = Path.expand(cmd, dir)
        if File.exists?(path), do: {:ok, path}, else: {:error, {:not_found, path}}

      exe = System.find_executable(cmd) ->
        {:ok, exe}

      true ->
        {:error, {:not_found, cmd}}
    end
  end

  defp encode(msg), do: JSON.encode!(msg) <> "\n"

  defp cancel(timer), do: Process.cancel_timer(timer)
end
