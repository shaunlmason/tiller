defmodule TillerWeb.LabLive do
  @moduledoc """
  The butterfly lab, three panes: recorded timeline on the left (click a
  turn to pick the fork point), that turn across every branch in the
  middle, and the live race on the right with each branch's first
  divergence from the original.

  Everything on screen arrives through `Tiller.State.subscribe(:all)`;
  nothing is polled.
  """
  use Phoenix.LiveView

  alias Tiller.{Actions, Divergence, Event, FakeDriver, Session, State}

  @root "root"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: State.subscribe(:all)

    {:ok,
     socket
     |> assign(events: State.events(), selected: nil, branches: [], race_started: nil)
     |> assign(recording: false)}
  end

  # Presets: one thing different per branch. nil is the control.
  defp presets(fork_turn) do
    [
      nil,
      {:whitelist, List.delete(Actions.root_whitelist(), {:spend, 1})},
      {:driver, FakeDriver, FakeDriver.context([Tiller.Driver.action(:echo, ["elsewhere"])])},
      {:latency, 60}
    ] ++
      if fork_turn > 0, do: [{:result_override, 0, {:error, :disk_full}}], else: []
  end

  @impl true
  def handle_event("record", _params, socket) do
    Tiller.reset()
    State.subscribe(:all)
    Tiller.Demo.record()
    {:noreply, assign(socket, events: [], selected: nil, branches: [], recording: true)}
  end

  def handle_event("reset", _params, socket) do
    Tiller.reset()
    State.subscribe(:all)
    {:noreply, assign(socket, events: [], selected: nil, branches: [], recording: false)}
  end

  def handle_event("select", %{"turn" => turn}, socket) do
    {:noreply, assign(socket, selected: String.to_integer(turn))}
  end

  def handle_event("fork", _params, %{assigns: %{selected: turn}} = socket)
      when is_integer(turn) do
    branches =
      for m <- presets(turn), {:ok, pid} <- [Session.fork(@root, turn, m)] do
        %{id: Session.info(pid).id, pid: pid, mutation: m, events: [], verdict: nil, ms: nil}
      end

    started = System.monotonic_time(:millisecond)
    Enum.each(branches, &Session.run(&1.pid))

    {:noreply,
     assign(socket, branches: socket.assigns.branches ++ branches, race_started: started)}
  end

  def handle_event("fork", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:tiller_event, %Event{} = e}, socket) do
    %{branches: branches, events: events} = socket.assigns

    if Enum.any?(branches, &(&1.id == e.session_id)) do
      {:noreply, assign(socket, branches: Enum.map(branches, &absorb(&1, e, socket.assigns)))}
    else
      {:noreply, assign(socket, events: events ++ [e])}
    end
  end

  defp absorb(%{id: id} = b, %Event{session_id: id} = e, assigns) do
    b = %{b | events: b.events ++ [e]}

    if Event.halt?(e) do
      original = Enum.filter(assigns.events, &(&1.session_id == @root))
      ms = System.monotonic_time(:millisecond) - (assigns.race_started || 0)
      %{b | verdict: Divergence.first_diff(original, b.events), ms: ms}
    else
      b
    end
  end

  defp absorb(b, _e, _assigns), do: b

  # ---- view helpers -------------------------------------------------------

  defp root_events(events), do: Enum.filter(events, &(&1.session_id == @root))

  defp children(events, parent), do: Enum.filter(events, &(&1.parent_id == parent))

  defp action_text(:halt), do: "halt"

  defp action_text({:call, _m, f, args}),
    do: "#{f}(#{Enum.map_join(args, ", ", &inspect(&1, limit: 3))})"

  defp result_class({:ok, _}), do: "ok"
  defp result_class({:error, _}), do: "err"
  defp result_class({:halted, _}), do: "halt"

  defp result_text(r), do: inspect(r, limit: 6, printable_limit: 60)

  defp mutation_text(nil), do: "control"
  defp mutation_text({:whitelist, _}), do: "whitelist: no spend"
  defp mutation_text({:driver, _, _}), do: "driver: other script"
  defp mutation_text({:latency, ms}), do: "latency: #{ms}ms/turn"
  defp mutation_text({:result_override, t, r}), do: "override t#{t}: #{inspect(r)}"
  defp mutation_text(other), do: inspect(other)

  defp verdict_text(nil), do: "running"
  defp verdict_text(:identical), do: "identical"
  defp verdict_text({:diverged, i, _, _}), do: "diverged at turn #{i}"

  defp verdict_class(nil), do: ""
  defp verdict_class(:identical), do: "done"
  defp verdict_class({:diverged, _, _, _}), do: "diverged"

  defp progress(b, total) when total > 0, do: min(100, div(length(b.events) * 100, total))
  defp progress(_b, _total), do: 0

  # Card class for a branch at the selected turn: dim when it matches the
  # original, highlighted when it differs, plain when there is nothing yet.
  defp compare_class(nil, _), do: ""
  defp compare_class(_, nil), do: ""
  defp compare_class(a, b), do: if(Event.key(a) == Event.key(b), do: "same", else: "diff")

  @impl true
  def render(assigns) do
    root = root_events(assigns.events)
    assigns = assign(assigns, root: root, total: length(root))

    ~H"""
    <header>
      <h1>tiller lab</h1>
      <button phx-click="record">Record run</button>
      <button phx-click="fork" disabled={is_nil(@selected) or @total == 0}>
        Fork at {if @selected, do: "turn #{@selected}", else: "…"}
      </button>
      <button phx-click="reset">Reset</button>
      <span class="tag">
        {if @total > 0, do: "#{@total} events recorded", else: "no run yet"} · {length(@branches)} branches
      </span>
    </header>
    <main>
      <section id="timeline">
        <h2>Timeline · root</h2>
        <p :if={@total == 0} class="dim">Record a run, then click a turn to fork from it.</p>
        <div
          :for={e <- @root}
          class={"row #{if @selected == e.turn, do: "selected"}"}
          phx-click="select"
          phx-value-turn={e.turn}
          id={"turn-#{e.turn}"}
        >
          <span class="t">t{e.turn}</span>
          <span>
            <div class="a">{action_text(e.action)}</div>
            <div class={result_class(e.result)}>{result_text(e.result)}</div>
            <div :for={c <- children(@events, e.session_id)} :if={e.action == :halt} class="sub dim">
              {c.session_id} t{c.turn} {action_text(c.action)} → {result_text(c.result)}
            </div>
          </span>
        </div>
      </section>

      <section id="detail">
        <h2>Turn {@selected || "…"} · across branches</h2>
        <p :if={is_nil(@selected)} class="dim">Select a turn on the left.</p>
        <%= if @selected do %>
          <% orig = Enum.at(@root, @selected) %>
          <div class="card">
            <h3><span>root</span><span class="tag">original</span></h3>
            <pre :if={orig}>{action_text(orig.action)}
    <span class={result_class(orig.result)}>{result_text(orig.result)}</span></pre>
          </div>
          <div
            :for={b <- @branches}
            class={"card #{compare_class(orig, Enum.at(b.events, @selected))}"}
          >
            <h3><span>{b.id}</span><span class="tag">{mutation_text(b.mutation)}</span></h3>
            <% ev = Enum.at(b.events, @selected) %>
            <pre :if={ev}>{action_text(ev.action)}
    <span class={result_class(ev.result)}>{result_text(ev.result)}</span></pre>
            <span :if={is_nil(ev)} class="dim">no event at this turn yet</span>
          </div>
        <% end %>
      </section>

      <section id="race">
        <h2>Race</h2>
        <p :if={@branches == []} class="dim">Fork to start a race.</p>
        <div :for={b <- @branches} class="card" id={"branch-#{b.id}"}>
          <h3>
            <span>{b.id}</span>
            <span class="tag">{mutation_text(b.mutation)}</span>
          </h3>
          <div class={"bar #{verdict_class(b.verdict)}"}>
            <i style={"width: #{progress(b, @total)}%"}></i>
          </div>
          <div>
            <span class={if match?({:diverged, _, _, _}, b.verdict), do: "err", else: "ok"}>
              {verdict_text(b.verdict)}
            </span>
            <span class="tag">· {length(b.events)}/{@total} events{if b.ms, do: " · #{b.ms}ms"}</span>
          </div>
          <pre :if={match?({:diverged, _, _, _}, b.verdict)} class="tag">{
            with {:diverged, _, l, r} <- b.verdict do
              "#{if l, do: action_text(l.action) <> " " <> result_text(l.result), else: "nothing"}\n→ #{if r, do: action_text(r.action) <> " " <> result_text(r.result), else: "nothing"}"
            end
          }</pre>
        </div>
      </section>
    </main>
    """
  end
end
