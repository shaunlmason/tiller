defmodule TillerWeb.LabLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint TillerWeb.Endpoint

  setup do
    Tiller.reset()
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  test "a halt that carries a reason renders instead of crashing the lab" do
    # what a refusal, a spent budget, or a lost API leaves in the log
    {:ok, _} =
      Tiller.State.append("root", nil, 0, :halt, Tiller.Event.halted(0, {:refusal, "cyber"}))

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "refusal"
    assert render(view) =~ "halt"
  end

  test "sweep forks every mutation the run reaches, not the hand-picked few" do
    {:ok, view, _html} = live(build_conn(), "/")

    render_click(view, "record")
    wait_until(fn -> render(view) =~ "halt" and render(view) =~ "root.1" end)

    render_click(view, "select", %{"turn" => "2"})
    render_click(view, "sweep")

    # the recorded run is put, spawn_subagent, spend, fail, get. Forked at
    # turn 2: three controls, one branch per tool still to be used (spend,
    # fail, get), an override per replayed turn (0 and 1), a kill per turn
    # it could still die at (2, 3, 4), and one latency.
    assert render(view) =~ "12 branches"

    wait_until(fn -> not (render(view) =~ "running") end, 200)
    html = render(view)

    assert html =~ "control"
    assert html =~ "kill at t2"
    assert html =~ "override t0"
    assert html =~ "latency"
  end

  test "the control band is measured and shown, and quiet controls leave it at zero" do
    {:ok, view, _html} = live(build_conn(), "/")

    render_click(view, "record")
    wait_until(fn -> render(view) =~ "halt" and render(view) =~ "root.1" end)

    render_click(view, "select", %{"turn" => "2"})
    render_click(view, "fork")
    wait_until(fn -> not (render(view) =~ "running") end)
    html = render(view)

    # A scripted driver reproduces its source exactly, so the three controls
    # drift nowhere and every real difference is the mutation's doing.
    assert html =~ "control band: 3 controls changed nothing and drifted 0 turns"
    assert html =~ "a mutation must beat that to earn the star"
    refute html =~ "ended somewhere else"

    # Controls are rows too, and are never the starred branch.
    assert has_element?(view, "#grid tr.control")
    refute has_element?(view, "#grid tr.control.smallest")
    assert has_element?(view, "#grid tr.smallest")
  end

  test "record, pick a turn, fork, and watch the race resolve" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "no run yet"

    render_click(view, "record")
    wait_until(fn -> render(view) =~ "halt" and render(view) =~ "root.1" end)
    assert render(view) =~ "6 events recorded"

    render_click(view, "select", %{"turn" => "2"})
    assert render(view) =~ "Fork at turn 2"
    assert has_element?(view, "#turn-2.selected")

    render_click(view, "fork")
    # three controls plus five mutations
    assert render(view) =~ "8 branches"

    wait_until(fn -> not (render(view) =~ "running") end)
    html = render(view)

    assert html =~ "identical"
    assert html =~ "diverged at turn 2"
    assert html =~ "diverged at turn 0"
    # middle pane: the whitelist branch differs at the selected turn
    assert html =~ "not_whitelisted"

    # grid: one row per branch, one cell per turn, coloured by comparison
    assert has_element?(view, "#grid [id='branch-root@2.3'] td.cell.diff")
    assert has_element?(view, "#grid [id='branch-root@2.0'] td.cell.same")
    refute has_element?(view, "#grid [id='branch-root@2.0'] td.cell.diff")

    # ranking: the whitelist branch ended elsewhere with the fewest differing
    # turns, so it is the smallest decisive mutation and sorts first
    assert has_element?(view, "#grid tr.smallest[id='branch-root@2.3']")
    assert has_element?(view, "#grid tbody tr:first-child[id='branch-root@2.3']")
    assert html =~ "kill at t2, resume"

    # picking a branch shows its card; clicking a cell selects that turn
    render_click(view, "pick", %{"id" => "root@2.4"})
    assert has_element?(view, "#picked", "root@2.4")
    render_click(view, "select", %{"turn" => "0"})
    assert render(view) =~ "Fork at turn 0"
  end
end
