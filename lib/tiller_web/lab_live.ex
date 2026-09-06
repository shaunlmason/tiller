defmodule TillerWeb.LabLive do
  @moduledoc """
  The butterfly lab on one screen (design step 9): timeline left, turn
  detail middle, live race right.

  The page subscribes to every event (`Tiller.State.subscribe(:all)`) and
  paints each one as it lands, so N branches racing under the supervisor
  are visibly N things finishing at different times. Divergence is
  recomputed live per branch on every event; a branch that has not yet
  reached its parent's length is "identical so far", not diverged. The
  race itself is `Tiller.Lab.race/4` in a task; its final report replaces
  the live verdicts when it lands.
  """
  use Phoenix.LiveView

  alias Tiller.{Divergence, Event, Lab, Mutation, Session, State}

  @demo_script [
    Tiller.Driver.action(:echo, ["plan"]),
    Tiller.Driver.action(:fail, []),
    Tiller.Driver.action(:echo, ["recover"]),
    Tiller.Driver.action(:echo, ["done"])
  ]

  # the preset mutations offered on the page: key, label
  @presets [
    {"control", "control: same whitelist, same driver"},
    {"nofail", "whitelist without fail/0"},
    {"override", "override turn 0 with {:ok, \"a different plan\"}"},
    {"driver", "driver swap: echo plan, echo skip the crash"},
    {"latency", "latency 300ms per live turn"},
    {"kill", "kill the process before turn 2; the supervisor resumes it from its log"}
  ]

  defp mutation("control"), do: {:whitelist, Tiller.Actions.root_whitelist()}
  defp mutation("nofail"), do: {:whitelist, List.delete(Tiller.Actions.root_whitelist(), {:fail, 0})}
  defp mutation("override"), do: {:result_override, 0, {:ok, "a different plan"}}

  defp mutation("driver"),
    do:
      {:driver, Tiller.FakeDriver,
       Tiller.FakeDriver.context([Tiller.Driver.action(:echo, ["plan"]), Tiller.Driver.action(:echo, ["skip the crash"])])}

  defp mutation("latency"), do: {:latency, 300}
  defp mutation("kill"), do: {:kill_at, 2}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: State.subscribe(:all)

    {:ok,
     socket
     |> assign(events: State.events(), selected: nil, root: nil, turn: 1, chosen: ["control", "nofail", "override", "driver", "latency"], race: nil, presets: @presets)
     |> pick_root()}
  end

  @impl true
  def handle_info({:tiller_event, %Event{} = ev}, socket) do
    {:noreply, socket |> assign(events: socket.assigns.events ++ [ev]) |> pick_root()}
  end

  def handle_info({:race_done, results}, socket) do
    {:noreply, assign(socket, race: %{socket.assigns.race | results: results, done: true})}
  end

  @impl true
  def handle_event("run-demo", _params, socket) do
    id = "root-#{System.unique_integer([:positive, :monotonic])}"
    spec = Session.child_spec(driver: Tiller.FakeDriver, ctx: Tiller.FakeDriver.context(@demo_script), id: id)
    {:ok, pid} = DynamicSupervisor.start_child(Tiller.Supervisor, spec)
    :ok = Session.run(pid)
    {:noreply, assign(socket, root: id, race: nil)}
  end

  def handle_event("run-claude", %{"goal" => goal}, socket) do
    cond do
      String.trim(goal) == "" ->
        {:noreply, put_flash(socket, :error, "give the model a goal")}

      (System.get_env("ANTHROPIC_API_KEY") || "") == "" ->
        {:noreply, put_flash(socket, :error, "ANTHROPIC_API_KEY is not set; the driver has nothing to call")}

      true ->
        id = "claude-#{System.unique_integer([:positive, :monotonic])}"
        ctx = Tiller.Driver.Claude.context(goal)
        spec = Session.child_spec(driver: Tiller.Driver.Claude, ctx: ctx, id: id)
        {:ok, pid} = DynamicSupervisor.start_child(Tiller.Supervisor, spec)
        :ok = Session.run(pid)
        {:noreply, assign(socket, root: id, race: nil)}
    end
  end

  def handle_event("resume", %{"session" => id}, socket) do
    case Session.resume(id) do
      {:ok, _pid} -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "cannot resume #{id}: #{reason}")}
    end
  end

  def handle_event("clear", _params, socket) do
    Lab.reset()
    {:noreply, assign(socket, events: [], selected: nil, root: nil, race: nil)}
  end

  def handle_event("select", %{"session" => sid, "turn" => turn}, socket) do
    {:noreply, assign(socket, selected: {sid, String.to_integer(turn)})}
  end

  def handle_event("configure", params, socket) do
    {:noreply,
     assign(socket,
       root: Map.get(params, "root", socket.assigns.root),
       turn: params |> Map.get("turn", "1") |> parse_int(socket.assigns.turn),
       chosen: Map.get(params, "mutations", [])
     )}
  end

  def handle_event("race", params, socket) do
    socket = handle_event("configure", params, socket) |> elem(1)
    %{root: root, turn: turn, chosen: chosen} = socket.assigns

    case root && Session.whereis(root) do
      nil ->
        {:noreply, put_flash(socket, :error, "no root session to fork; run the demo first")}

      pid ->
        mutations = for {key, _label} <- @presets, key in chosen, do: mutation(key)
        lv = self()
        Task.start(fn -> send(lv, {:race_done, Lab.race(pid, turn, mutations, timeout: 30_000)}) end)
        {:noreply, assign(socket, race: %{parent: root, turn: turn, mutations: mutations, results: nil, done: false, started_seq: last_seq(socket.assigns.events)})}
    end
  end

  ## derived views

  # sessions in order of first appearance: [{id, parent_id, events}]
  defp sessions(events) do
    events
    |> Enum.group_by(& &1.session_id)
    |> Enum.map(fn {id, evs} -> {id, hd(evs).parent_id, evs} end)
    |> Enum.sort_by(fn {_id, _p, evs} -> hd(evs).seq end)
  end

  defp events_of(events, id), do: Enum.filter(events, &(&1.session_id == id))

  defp halted?(evs), do: Enum.any?(evs, &match?(%Event{action: :halt}, &1))

  # halted, running, or dead (no halt and no process: killed)
  defp status(id, evs) do
    cond do
      halted?(evs) -> "halted"
      Session.whereis(id) -> "running"
      true -> "dead"
    end
  end

  # a branch's verdict against its parent from the events seen so far
  defp live_verdict(_events, _id, nil), do: nil

  defp live_verdict(events, id, parent_id) do
    branch = events_of(events, id)

    case Divergence.first_diff(events_of(events, parent_id), branch) do
      {:diverged, t, _, nil} = v ->
        cond do
          halted?(branch) -> v
          Session.whereis(id) -> :identical_so_far
          true -> {:killed, t}
        end

      v ->
        v
    end
  end

  defp diverge_turn({:diverged, t, _, _}), do: t
  defp diverge_turn(_), do: nil

  defp pick_root(socket) do
    roots = for {id, nil, _} <- sessions(socket.assigns.events), do: id

    cond do
      socket.assigns.root in roots -> socket
      roots == [] -> assign(socket, root: nil)
      true -> assign(socket, root: List.last(roots))
    end
  end

  defp last_seq([]), do: 0
  defp last_seq(events), do: List.last(events).seq

  defp parse_int(s, default) do
    case Integer.parse(to_string(s)) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  # the session's packet: live info when it runs, the stored packet when it does not
  defp meta(id) do
    case Session.whereis(id) do
      nil -> State.get_session(id) || %{}
      pid -> Session.info(pid)
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # what a session should be compared against: a resumed session inherits
  # the comparison target of the session it resumed, not the dead session
  defp compare_parent(id) do
    case meta(id) do
      %{resumed_from: from} when not is_nil(from) -> compare_parent(from)
      %{parent_id: p} -> p
      _ -> nil
    end
  end

  defp lineage_text(id) do
    case meta(id) do
      %{resumed_from: from} when not is_nil(from) -> "resumed from #{from}"
      %{parent_id: p} when not is_nil(p) -> "forked from #{p}"
      _ -> ""
    end
  end

  defp kind(%Event{action: :halt}), do: "halt"
  defp kind(%Event{origin: :replay}), do: "replay"
  defp kind(%Event{result: {:error, _}}), do: "err"
  defp kind(_), do: "ok"

  defp short_action(:halt), do: "halt"
  defp short_action({:call, _, f, args}), do: "#{f}/#{length(args)}"

  defp verdict_text(nil), do: ""
  defp verdict_text(:identical), do: "identical"
  defp verdict_text(:identical_so_far), do: "identical so far"
  defp verdict_text({:killed, t}), do: "killed before turn #{t}"
  defp verdict_text({:diverged, t, l, r}), do: "diverged at turn #{t}: #{side(l)} vs #{side(r)}"

  defp side(nil), do: "(ended)"
  defp side(%Event{action: :halt}), do: "halt"
  defp side(%Event{action: a, result: r}), do: "#{short_action(a)} -> #{inspect(r, limit: 4, printable_limit: 40)}"

  defp verdict_class(:identical), do: "identical"
  defp verdict_class(:identical_so_far), do: "pending"
  defp verdict_class({:diverged, _, _, _}), do: "diverged"
  defp verdict_class({:killed, _}), do: "error"
  defp verdict_class(_), do: "pending"

  ## render

  @impl true
  def render(assigns) do
    sessions = sessions(assigns.events)

    race_branches =
      case assigns.race do
        %{parent: parent, started_seq: seq} ->
          for {id, parent_id, evs} <- sessions, parent_id == parent, hd(evs).seq > seq do
            final = Session.final(id)
            {id, final, if(final == id, do: evs, else: events_of(assigns.events, final))}
          end

        nil ->
          []
      end

    assigns = assign(assigns, sessions: sessions, race_branches: race_branches)

    ~H"""
    <header>
      <h1>tiller butterfly lab</h1>
      <button phx-click="run-demo">run demo root</button>
      <form phx-submit="run-claude" style="display:inline-flex;gap:6px;align-items:center;margin:0">
        <input type="text" name="goal" placeholder="a goal for Claude" style="width:22em;background:var(--panel);color:var(--fg);border:1px solid var(--line);border-radius:4px;padding:3px 6px;font:inherit" />
        <button type="submit">run claude root</button>
      </form>
      <button phx-click="clear">clear</button>
      <span class="legend">
        <span style="background:var(--ok)"></span>ok
        <span style="background:var(--err)"></span>error
        <span style="background:var(--replay)"></span>replayed
        <span style="background:var(--halt)"></span>halt
        <span style="box-shadow:0 0 0 2px var(--div)"></span>first divergence
      </span>
      <span :if={Phoenix.Flash.get(@flash, :error)} style="color:var(--err)">{Phoenix.Flash.get(@flash, :error)}</span>
    </header>
    <main>
      <section id="timeline">
        <h2>timeline</h2>
        <p :if={@sessions == []} class="kv">no sessions yet: run the demo root, then fork it on the right.</p>
        <div :for={{id, parent_id, evs} <- @sessions} class="session" id={"session-#{id}"}>
          <div class="name">
            <span><b>{id}</b> <span :if={parent_id} class="meta">{lineage_text(id)}</span></span>
            <span class={status(id, evs)}>{status(id, evs)}
              <button :if={status(id, evs) == "dead" and Session.final(id) == id} phx-click="resume" phx-value-session={id} style="margin-left:6px;padding:1px 6px">resume</button></span>
          </div>
          <div :if={parent_id} class="meta">
            {case meta(id) do
              %{mutation: m, fork_turn: t} when not is_nil(m) -> "fork@#{t} #{Mutation.label(m)}"
              _ -> ""
            end}
            <span class={"verdict #{verdict_class(live_verdict(@events, id, compare_parent(id)))}"}>{verdict_text(live_verdict(@events, id, compare_parent(id)))}</span>
          </div>
          <div class="turns">
            <span
              :for={ev <- evs}
              class={"turn #{kind(ev)} #{if @selected == {id, ev.turn}, do: "selected"} #{if diverge_turn(live_verdict(@events, id, compare_parent(id))) == ev.turn, do: "diverge"}"}
              phx-click="select"
              phx-value-session={id}
              phx-value-turn={ev.turn}
              title={short_action(ev.action)}
            >{ev.turn}</span>
          </div>
        </div>
      </section>

      <section id="detail">
        <h2>turn</h2>
        <p :if={is_nil(@selected)} class="kv">click a turn.</p>
        <%= if @selected do %>
          <% {sid, turn} = @selected %>
          <% ev = Enum.find(@events, &(&1.session_id == sid and &1.turn == turn)) %>
          <%= if ev do %>
            <p class="kv">session <b>{sid}</b> · turn <b>{turn}</b> · seq <b>{ev.seq}</b> · <b>{ev.origin}</b>
              <span :if={ev.parent_id}>· forked from <b>{ev.parent_id}</b></span></p>
            <div class="kv">action</div>
            <pre>{inspect(ev.action, pretty: true, width: 60)}</pre>
            <div class="kv">result</div>
            <pre>{inspect(ev.result, pretty: true, width: 60, limit: 40, printable_limit: 200)}</pre>
            <%= if ev.parent_id do %>
              <div class="kv">vs parent at this turn</div>
              <pre>{case Enum.find(@events, &(&1.session_id == ev.parent_id and &1.turn == turn)) do
                nil -> "(parent has no turn #{turn})"
                pev -> inspect({pev.action, pev.result}, pretty: true, width: 60, limit: 40, printable_limit: 200)
              end}</pre>
            <% end %>
          <% end %>
        <% end %>
      </section>

      <section id="race">
        <h2>race</h2>
        <form id="race-form" phx-change="configure" phx-submit="race">
          <p class="kv">
            root
            <select name="root">
              <option :for={{id, nil, _} <- @sessions} value={id} selected={id == @root}>{id}</option>
            </select>
            fork at turn <input type="number" name="turn" min="0" value={@turn} />
          </p>
          <label :for={{key, label} <- @presets} class="m">
            <input type="checkbox" name="mutations[]" value={key} checked={key in @chosen} /> {label}
          </label>
          <p><button type="submit">fork and race</button></p>
        </form>

        <%= if @race do %>
          <p class="kv">forked <b>{@race.parent}</b> at turn <b>{@race.turn}</b>: {if @race.done, do: "done", else: "racing"}</p>
          <p :if={@race.results && Lab.smallest(@race.results) != []} class="kv">
            smallest decisive mutation: <b>{@race.results |> Lab.smallest() |> Enum.map_join(", ", &Mutation.label(&1.mutation))}</b>
            (latest divergence, turn {@race.results |> Lab.smallest() |> hd() |> then(fn %{verdict: {:diverged, t, _, _}} -> t end)})
          </p>
          <table>
            <tr><th>#</th><th>mutation</th><th>branch</th><th>state</th><th>verdict</th></tr>
            <%= if @race.results do %>
              <tr :for={r <- Lab.ranked(@race.results)}>
                <td>{case r do %{rank: n} when is_integer(n) -> "##{n}"; _ -> "--" end}</td>
                <td>{Mutation.label(r.mutation)}</td>
                <%= if Map.has_key?(r, :error) do %>
                  <td></td><td class="verdict error">not run</td><td class="verdict error">{inspect(r.error)}</td>
                <% else %>
                  <td>{Enum.join(r.lineage, " -> ")}</td>
                  <td>{inspect(r.outcome)}</td>
                  <td class={"verdict #{verdict_class(r.verdict)}"}>{verdict_text(r.verdict)}</td>
                <% end %>
              </tr>
            <% else %>
              <tr :for={{id, final, evs} <- @race_branches}>
                <td></td>
                <td>{case meta(id) do %{mutation: m} when not is_nil(m) -> Mutation.label(m); _ -> "" end}</td>
                <td>{Enum.join(Session.lineage(id), " -> ")}</td>
                <td class={status(final, evs)}>{case status(final, evs) do
                  "halted" -> "halted after #{length(evs) - 1}"
                  "running" -> "running (#{length(evs)})"
                  "dead" -> "dead at #{length(evs)}"
                end}</td>
                <td class={"verdict #{verdict_class(live_verdict(@events, final, @race.parent))}"}>{verdict_text(live_verdict(@events, final, @race.parent))}</td>
              </tr>
            <% end %>
          </table>
        <% end %>
      </section>
    </main>
    """
  end
end
