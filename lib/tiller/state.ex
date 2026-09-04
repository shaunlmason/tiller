defmodule Tiller.State do
  @moduledoc """
  Shared action log. Every action + result is appended here in order.
  This is the audit trail, the replay log, and the source of the next
  prompt — one thing, three jobs.

  ponytail: in-memory list, newest at the tail. Move to ETS/Ecto when
  you need replay across restarts.
  """
  use GenServer

  @doc "Child spec for supervisors."
  def child_spec(_opts \\ []), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], Keyword.put(opts, :name, __MODULE__))
  end

  @impl true
  def init(_), do: {:ok, []}

  @doc "Append an action + result. Returns the new log length."
  def append(action, result), do: GenServer.call(__MODULE__, {:append, action, result})

  @doc "Return the log, newest last."
  def log, do: GenServer.call(__MODULE__, :log)

  @doc "Reset (tests)."
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def handle_call({:append, action, result}, _from, log) do
    new_log = log ++ [{action, result}]
    {:reply, length(new_log), new_log}
  end

  def handle_call(:log, _from, log), do: {:reply, log, log}
  def handle_call(:clear, _from, _log), do: {:reply, :ok, []}
end
