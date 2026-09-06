defmodule TillerWeb.LabLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Tiller.{Lab, Session}

  @endpoint TillerWeb.Endpoint

  setup do
    Lab.reset()
    :ok
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  test "mounts empty, runs the demo root, paints its turns live" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "no sessions yet"

    render_click(view, "run-demo")
    eventually(fn -> render(view) =~ "halted" end)

    html = render(view)
    assert [root_id] = Regex.run(~r/session-(root-\d+)/, html, capture: :all_but_first)
    assert {:halted, 4} = Session.await(Session.whereis(root_id))
    # four turns plus the halt chip; the crash at turn 1 is an error chip
    assert html =~ ~s(class="turn err)
    assert html =~ ~s(class="turn halt)
  end

  test "selecting a turn shows its action and result" do
    {:ok, view, _} = live(build_conn(), "/")
    render_click(view, "run-demo")
    eventually(fn -> render(view) =~ "halted" end)
    [root_id] = Regex.run(~r/session-(root-\d+)/, render(view), capture: :all_but_first)

    html = render_click(view, "select", %{"session" => root_id, "turn" => "1"})
    assert html =~ ":fail"
    assert html =~ "simulated tool crash"
  end

  test "fork and race: branches appear live, then the report lands with verdicts" do
    {:ok, view, _} = live(build_conn(), "/")
    render_click(view, "run-demo")
    eventually(fn -> render(view) =~ "halted" end)
    [root_id] = Regex.run(~r/session-(root-\d+)/, render(view), capture: :all_but_first)

    view
    |> form("#race-form", %{"root" => root_id, "turn" => "1", "mutations" => ["control", "nofail", "override", "kill"]})
    |> render_submit()

    eventually(fn -> render(view) =~ "forked <b>#{root_id}</b> at turn <b>1</b>: done" end)
    html = render(view)

    assert html =~ "whitelist=root</td>"
    assert html =~ "whitelist=root-fail/0"
    assert html =~ "diverged at turn 1: fail/0"
    assert html =~ "override@0"
    assert html =~ "diverged at turn 0"
    assert html =~ "kill@2"
    assert html =~ ~r/root-\d+\/f1-\d+ -&gt; root-\d+\/f1-\d+\/r\d+/
    assert html =~ "resumed from"
    assert html =~ ">dead<"
    # the resumed session is judged against the root, not the dead branch it resumed
    [resumed_block] = Regex.run(~r/<div class="session" id="session-[^"]+\/r\d+">.*?<\/div><\/div>/s, html)
    assert resumed_block =~ "verdict identical"
    # the branches are on the timeline, attributed to the root
    assert html =~ "forked from #{root_id}"
    # the first divergence is marked on a chip
    assert html =~ "diverge"
  end

  test "racing with no root is a flash, not a crash" do
    {:ok, view, _} = live(build_conn(), "/")
    html = view |> form("#race-form", %{"turn" => "1", "mutations" => ["control"]}) |> render_submit()
    assert html =~ "no root session to fork"
  end
end
