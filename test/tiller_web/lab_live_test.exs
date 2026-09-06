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

  test "record, pick a turn, fork, and watch the race resolve" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "no run yet"

    render_click(view, "record")
    wait_until(fn -> render(view) =~ "halt" and render(view) =~ "root.0" end)
    assert render(view) =~ "6 events recorded"

    render_click(view, "select", %{"turn" => "2"})
    assert render(view) =~ "Fork at turn 2"
    assert has_element?(view, "#turn-2.selected")

    render_click(view, "fork")
    assert render(view) =~ "6 branches"

    wait_until(fn -> not (render(view) =~ "running") end)
    html = render(view)

    assert html =~ "identical"
    assert html =~ "diverged at turn 2"
    assert html =~ "diverged at turn 0"
    # middle pane: the whitelist branch differs at the selected turn
    assert html =~ "not_whitelisted"

    # grid: one row per branch, one cell per turn, coloured by comparison
    assert has_element?(view, "#grid [id='branch-root@2.1'] td.cell.diff")
    assert has_element?(view, "#grid [id='branch-root@2.0'] td.cell.same")
    refute has_element?(view, "#grid [id='branch-root@2.0'] td.cell.diff")

    # ranking: the whitelist branch ended elsewhere with the fewest differing
    # turns, so it is the smallest decisive mutation and sorts first
    assert has_element?(view, "#grid tr.smallest[id='branch-root@2.1']")
    assert has_element?(view, "#grid tbody tr:first-child[id='branch-root@2.1']")
    assert html =~ "kill at t2, resume"

    # picking a branch shows its card; clicking a cell selects that turn
    render_click(view, "pick", %{"id" => "root@2.4"})
    assert has_element?(view, "#picked", "root@2.4")
    render_click(view, "select", %{"turn" => "0"})
    assert render(view) =~ "Fork at turn 0"
  end
end
