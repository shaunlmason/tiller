defmodule Tiller.Driver.LLM.WireTest do
  @moduledoc """
  The Assignment from `docs/designs/llm-driver.md`: hand-written JSON in,
  quoted terms out. No processes, no HTTP.
  """
  use ExUnit.Case, async: true

  alias Tiller.Driver.LLM.Wire
  alias Tiller.Tools

  describe "tools/1" do
    test "one strict definition per whitelisted entry that has a schema, name-sorted" do
      defs = Wire.tools([{:spend, 1}, {:echo, 1}, {:put, 2}, {:spawn_subagent, 2}, {:fail, 0}])

      assert Enum.map(defs, & &1["name"]) == ["echo", "put", "spend"]

      spend = Enum.find(defs, &(&1["name"] == "spend"))
      assert spend["strict"] == true
      assert spend["description"] =~ "budget"

      assert spend["input_schema"] == %{
               "type" => "object",
               "properties" => %{"amount" => %{"type" => "integer"}},
               "required" => ["amount"],
               "additionalProperties" => false
             }

      # two parameters keep their order in `required`
      put = Enum.find(defs, &(&1["name"] == "put"))
      assert put["input_schema"]["required"] == ["key", "value"]
    end

    test "a whitelist with nothing callable offers nothing" do
      assert Wire.tools([{:fail, 0}, {:spawn_subagent, 2}]) == []
    end
  end

  describe "decode/1" do
    test "a tool_use decodes to a quoted term with args in schema order" do
      body = %{
        "stop_reason" => "tool_use",
        "content" => [
          %{"type" => "text", "text" => "I will spend four."},
          %{
            "type" => "tool_use",
            "id" => "toolu_01",
            "name" => "spend",
            "input" => %{"amount" => 4}
          }
        ]
      }

      assert {:tool_use, "toolu_01", {:call, Tools, :spend, [4]}} = Wire.decode(body)
    end

    test "input order in the JSON does not decide argument order" do
      body = %{
        "stop_reason" => "tool_use",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_02",
            "name" => "put",
            # value first: JSON objects are unordered, the schema is not
            "input" => %{"value" => "hello", "key" => "greeting"}
          }
        ]
      }

      assert {:tool_use, "toolu_02", {:call, Tools, :put, ["greeting", "hello"]}} =
               Wire.decode(body)
    end

    test "an end_turn with text decodes to the model's answer" do
      body = %{
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => "The greeting is stored."}]
      }

      assert {:text, "The greeting is stored."} = Wire.decode(body)
    end

    test "a refusal decodes from stop_reason without touching content" do
      body = %{
        "stop_reason" => "refusal",
        "stop_details" => %{"category" => "cyber"},
        "content" => []
      }

      assert {:refusal, "cyber"} = Wire.decode(body)
    end

    test "any other stop reason is a stop" do
      assert {:stop, :max_tokens} = Wire.decode(%{"stop_reason" => "max_tokens", "content" => []})
    end

    test "a tool name the model invented is still an action, for the whitelist to refuse" do
      body = %{
        "stop_reason" => "tool_use",
        "content" => [
          %{"type" => "tool_use", "id" => "t", "name" => "rm_rf", "input" => %{"path" => "/"}}
        ]
      }

      assert {:tool_use, "t", {:call, Tools, :rm_rf, ["/"]}} = Wire.decode(body)
    end
  end

  describe "tool_result/2" do
    test "an ok result is not an error" do
      assert %{
               "type" => "tool_result",
               "tool_use_id" => "t",
               "content" => "6",
               "is_error" => false
             } =
               Wire.tool_result("t", {:ok, 6})
    end

    test "an error result says so, which is how the model learns it was refused" do
      assert %{"content" => ":not_found", "is_error" => true} =
               Wire.tool_result("t", {:error, :not_found})
    end

    test "a binary result is passed through unquoted" do
      assert %{"content" => "echo: 1"} = Wire.tool_result("t", {:ok, "echo: 1"})
    end
  end
end
