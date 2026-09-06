defmodule Tiller.SeedIntegrationTest do
  # The same contract against the real engine. Excluded by default; see
  # test/test_helper.exs and test/support/seed_fixture.sh.
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Tiller.{Seed, Tools}

  setup_all do
    cmd =
      System.get_env("TILLER_SEED_CMD") ||
        raise "set TILLER_SEED_CMD (e.g. \"scripts/seed mcp serve\")"

    dir =
      System.get_env("TILLER_SEED_DIR") ||
        raise "set TILLER_SEED_DIR (an instantiated open-seed repo)"

    {:ok, pid} = Seed.start_link(command: String.split(cmd), cd: dir, actor: "tiller")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok
  end

  setup do
    Tiller.reset()
  end

  test "claim / renew / fence / release against seed mcp serve" do
    {:ok, tools} = Seed.tools(Seed)
    assert "task_claim" in Enum.map(tools, & &1["name"])

    {:ok, %{"task" => id}} =
      Seed.call(Seed, "task_create", %{title: "tiller integration", actor: "tiller"})

    # promote is an operator verb: the fixture puts "tiller" on the roster,
    # and it is deliberately not a Tiller.Tools function.
    {:ok, %{"state" => "ready"}} = Seed.call(Seed, "task_promote", %{task: id, actor: "tiller"})

    assert {:ok, %{"tasks" => tasks}} = Tools.seed_ready()
    assert id in Enum.map(tasks, & &1["task"])

    assert {:ok, %{"claim_token" => tok}} = Tools.seed_claim(id, "30m")
    assert {:refused, %{"exit" => exit}} = Tools.seed_claim(id)
    assert exit in [2, 3]
    assert {:refused, %{"exit" => 6}} = Tools.seed_lease_renew(id, "not-the-token")
    assert {:ok, _} = Tools.seed_lease_renew(id, tok)
    assert {:ok, _} = Tools.seed_comment(id, "hello from tiller", tok)
    assert {:ok, _} = Tools.seed_release(id, tok)
    assert {:ok, %{"state" => "ready", "card" => %{"id" => ^id}}} = Tools.seed_get(id)
  end
end
