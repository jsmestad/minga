defmodule MingaAgent.InferenceRouteTest do
  use ExUnit.Case, async: true

  alias MingaAgent.InferenceRoute.{ConversationRef, Model, Spec, Status}
  alias MingaAgent.Test.FixtureInferenceRoute

  @model_attrs [
    id: "fixture-model",
    display_name: "Fixture Model",
    context_window: 200_000,
    max_output: 32_000,
    reasoning_levels: ["off", "high"],
    tools?: true,
    images_in?: true,
    tool_result_images?: true,
    compaction: :unsupported,
    usage: :none,
    cost: :subscription
  ]

  describe "Spec.new/1" do
    test "accepts an extension or bundle source with a lowercase route id" do
      for source <- [{:extension, :bridge}, {:bundle, :local_runtime}] do
        assert {:ok, %Spec{source: ^source, id: "claude_sub-1", display_name: "Claude"}} =
                 Spec.new(
                   source: source,
                   id: "claude_sub-1",
                   module: FixtureInferenceRoute,
                   display_name: " Claude "
                 )
      end
    end

    test "rejects invalid sources, ids, modules, and display names" do
      valid = %{
        source: {:extension, :bridge},
        id: "bridge",
        module: FixtureInferenceRoute,
        display_name: "Bridge"
      }

      for {field, value, reason} <- [
            {:source, :config, :invalid_source},
            {:source, {:extension, nil}, :invalid_source},
            {:id, "Bridge", :invalid_id},
            {:id, "has:colon", :invalid_id},
            {:id, "", :invalid_id},
            {:id, "openai", :reserved_id},
            {:id, "apple", :reserved_id},
            {:module, nil, :invalid_module},
            {:module, "Mod", :invalid_module},
            {:display_name, "  ", :invalid_display_name}
          ] do
        assert {:error, ^reason} = Spec.new(Map.put(valid, field, value)),
               "expected #{inspect(field)} = #{inspect(value)} to fail with #{inspect(reason)}"
      end
    end
  end

  describe "Model.new/1" do
    test "keeps every declared policy field" do
      assert {:ok, model} = Model.new(@model_attrs)
      assert model.reasoning_levels == ["off", "high"]
      assert model.compaction == :unsupported
      assert model.usage == :none
      assert model.cost == :subscription
    end

    test "rejects missing or malformed fields by name" do
      for {field, value} <- [
            id: "",
            display_name: nil,
            context_window: 0,
            max_output: -1,
            reasoning_levels: [],
            reasoning_levels: ["ok", ""],
            tools?: "yes",
            images_in?: nil,
            compaction: :summary,
            usage: :bytes,
            cost: :free
          ] do
        assert {:error, {:invalid_model_field, ^field}} =
                 Model.new(Keyword.put(@model_attrs, field, value))
      end
    end

    test "tool-result images require image input" do
      attrs = Keyword.merge(@model_attrs, images_in?: false, tool_result_images?: true)
      assert {:error, {:invalid_model_field, :tool_result_images?}} = Model.new(attrs)
    end
  end

  describe "Status.new/1" do
    test "accepts unknown, ready with an account, and unavailable with a remedy" do
      assert {:ok, %Status{availability: :unknown, plan_usage: :unreported}} =
               Status.new(:unknown)

      assert {:ok, ready} = Status.new({:ready, "me@example.com"})
      assert Status.ready?(ready)
      assert Status.account_label(ready) == "me@example.com"

      assert {:ok, unavailable} = Status.new({:unavailable, :not_signed_in, "Run: login"})
      refute Status.ready?(unavailable)
      assert Status.account_label(unavailable) == nil
    end

    test "rejects malformed availability" do
      for value <- [:ready, {:ready, ""}, {:unavailable, "reason", "fix"}, {:unavailable, :x, ""}] do
        assert {:error, :invalid_status} = Status.new(value)
      end
    end
  end

  describe "ConversationRef.new/1" do
    setup do
      %{
        attrs: %{
          session_id: "session-1",
          owner: self(),
          epoch_id: "epoch-1",
          conversation_revision: 3,
          request_id: make_ref(),
          purpose: :turn
        }
      }
    end

    test "accepts each purpose with a complete identity", %{attrs: attrs} do
      for purpose <- [:turn, :summary, :title] do
        assert {:ok, %ConversationRef{purpose: ^purpose}} =
                 ConversationRef.new(%{attrs | purpose: purpose})
      end
    end

    test "only isolated purposes may omit epoch and revision", %{attrs: attrs} do
      isolated = %{attrs | epoch_id: nil, conversation_revision: nil, session_id: nil}

      for purpose <- [:summary, :title] do
        assert {:ok, %ConversationRef{epoch_id: nil, conversation_revision: nil}} =
                 ConversationRef.new(%{isolated | purpose: purpose})
      end

      assert {:error, {:invalid_conversation_ref, :turn}} =
               ConversationRef.new(%{isolated | purpose: :turn})
    end

    test "rejects malformed fields for every purpose", %{attrs: attrs} do
      for purpose <- [:turn, :summary, :title],
          {field, value} <- [
            epoch_id: :unknown,
            epoch_id: "",
            owner: :not_a_pid,
            conversation_revision: -1,
            request_id: nil,
            session_id: ""
          ] do
        assert {:error, {:invalid_conversation_ref, ^purpose}} =
                 ConversationRef.new(%{attrs | purpose: purpose} |> Map.put(field, value)),
               "#{purpose} accepted #{field} = #{inspect(value)}"
      end

      assert {:error, {:invalid_conversation_ref, :purpose}} =
               ConversationRef.new(%{attrs | purpose: :chat})
    end
  end

  describe "route stream values" do
    alias MingaAgent.InferenceRoute.{Event, ToolCall, Usage}

    test "a tool call needs decoded map arguments" do
      assert {:ok, %ToolCall{arguments: %{"a" => 1}}} =
               ToolCall.new(id: "t1", name: "read", arguments: %{"a" => 1})

      assert {:error, {:invalid_tool_call, :arguments}} =
               ToolCall.new(id: "t1", name: "read", arguments: ~s({"a":1}))

      assert {:error, {:invalid_tool_call, :fields}} =
               ToolCall.new(id: "", name: "read", arguments: %{})
    end

    test "usage defaults to zero and rejects negative or fractional counts" do
      assert {:ok, %Usage{input_tokens: 5, output_tokens: 0, cache_read_tokens: 0}} =
               Usage.new(input_tokens: 5)

      assert {:error, {:invalid_usage, :output_tokens}} = Usage.new(output_tokens: -1)
      assert {:error, {:invalid_usage, :cache_write_tokens}} = Usage.new(cache_write_tokens: 1.5)
    end

    test "every event shape is checked" do
      call = %ToolCall{id: "t1", name: "read", arguments: %{}}

      for valid <- [
            {:text, "x"},
            {:thinking, "x"},
            {:tool_call, call},
            {:usage, %Usage{}},
            {:finish, :stop},
            {:finish, :tool_calls},
            {:finish, :length},
            {:finish, :refusal},
            {:finish, {:error, :boom}}
          ] do
        assert {:ok, ^valid} = Event.validate(valid)
      end

      for invalid <- [
            {:text, 1},
            {:tool_call, %{call | arguments: "{}"}},
            {:usage, %Usage{input_tokens: -1}},
            {:finish, :done},
            {:unknown, "x"},
            "text"
          ] do
        assert {:error, {:invalid_event, ^invalid}} = Event.validate(invalid)
      end
    end
  end

  describe "plan usage and setup values" do
    alias MingaAgent.InferenceRoute.{PlanWindow, SetupAction}

    defp plan_window(attrs) do
      {:ok, window} =
        [kind: "five_hour", utilization: 0.5, resets_at: nil, status: :allowed]
        |> Keyword.merge(attrs)
        |> PlanWindow.new()

      window
    end

    test "windows validate every field and store utilization as a float" do
      assert %PlanWindow{utilization: 1.0} = plan_window(utilization: 1)

      for {field, value} <- [
            kind: nil,
            utilization: 2,
            utilization: "0.5",
            resets_at: 123,
            status: :maybe
          ] do
        assert {:error, {:invalid_plan_window, ^field}} =
                 PlanWindow.new(
                   Keyword.put(
                     [kind: "five_hour", utilization: 0.5, resets_at: nil, status: :allowed],
                     field,
                     value
                   )
                 )
      end

      assert {:ok, nil} = PlanWindow.new_list([])
      assert {:ok, nil} = PlanWindow.new_list(nil)
      assert {:error, {:invalid_plan_window, :list}} = PlanWindow.new_list(:all)
    end

    test "the busiest and the refusing windows are found for display" do
      soon = DateTime.add(DateTime.utc_now(), 3_600)
      later = DateTime.add(DateTime.utc_now(), 86_400 * 3)

      five = plan_window(kind: "five_hour", utilization: 0.9, status: :rejected, resets_at: soon)
      week = plan_window(kind: "seven_day", utilization: 1.0, status: :rejected, resets_at: later)

      assert PlanWindow.busiest([five, week]) == week
      assert PlanWindow.busiest(nil) == nil
      assert PlanWindow.rejected([five, week]) == week
      assert PlanWindow.rejected([plan_window([])]) == nil
      assert PlanWindow.kind_label("five_hour") == "5h"
      assert PlanWindow.kind_label("seven_day") == "7d"
      assert PlanWindow.kind_label("monthly") == "monthly"
      assert PlanWindow.percent(plan_window(utilization: 0.829)) == 82
    end

    test "a window stops limiting once its reset time passes; a window without one stays" do
      now = ~U[2026-11-24 12:00:00Z]

      passed =
        plan_window(utilization: 1.0, status: :rejected, resets_at: ~U[2026-11-24 11:59:59Z])

      at_reset = plan_window(utilization: 1.0, status: :rejected, resets_at: now)
      pending = plan_window(kind: "seven_day", resets_at: ~U[2026-11-24 12:00:01Z])
      unknown = plan_window(kind: "one_day", status: :rejected, resets_at: nil)

      assert PlanWindow.in_force([passed, at_reset, pending, unknown], now) == [pending, unknown]
      assert PlanWindow.in_force([passed], now) == []
      assert PlanWindow.in_force(nil, now) == nil
    end

    test "reset times read as a clock time in the caller's zone, with the weekday on other days" do
      utc = fn at -> at |> DateTime.to_naive() |> NaiveDateTime.to_erl() end
      now = ~U[2026-11-21 09:00:00Z]

      cases = [
        {nil, nil},
        {~U[2026-11-21 15:40:00Z], "3:40 PM"},
        {~U[2026-11-21 00:05:00Z], "12:05 AM"},
        {~U[2026-11-21 12:00:00Z], "12:00 PM"},
        {~U[2026-11-24 09:15:00Z], "Tue 9:15 AM"}
      ]

      for {resets_at, expected} <- cases do
        assert PlanWindow.reset_label(plan_window(resets_at: resets_at), now, utc) == expected
      end

      # A zone ahead of UTC moves the same instant onto the next local day.
      ahead = fn at -> at |> DateTime.add(16 * 3_600) |> utc.() end

      evening = ~U[2026-11-21 05:00:00Z]

      assert PlanWindow.reset_label(
               plan_window(resets_at: ~U[2026-11-21 15:40:00Z]),
               evening,
               ahead
             ) ==
               "Sun 7:40 AM"
    end

    test "a setup action needs a label and a description" do
      assert {:ok, %SetupAction{label: "Use it", description: "No secrets."}} =
               SetupAction.new(label: " Use it ", description: "No secrets.")

      for invalid <- [[label: "", description: "x"], [label: "x"], ["x"], nil] do
        assert {:error, :invalid_setup_action} = SetupAction.new(invalid)
      end

      base = %{
        source: {:extension, :bridge},
        id: "bridge",
        module: MingaAgent.Test.FixtureInferenceRoute,
        display_name: "Bridge"
      }

      assert {:ok, %Spec{setup_action: nil}} = Spec.new(base)

      assert {:ok, %Spec{setup_action: %SetupAction{}}} =
               Spec.new(Map.put(base, :setup_action, %{label: "Use", description: "Sign in."}))

      assert {:error, :invalid_setup_action} = Spec.new(Map.put(base, :setup_action, %{}))
    end

    test "sentences use the short name and fall back to the display name" do
      base = %{
        source: {:extension, :bridge},
        id: "bridge",
        module: MingaAgent.Test.FixtureInferenceRoute,
        display_name: "Claude (subscription)"
      }

      assert {:ok, %Spec{short_name: nil} = without} = Spec.new(base)
      assert Spec.short_name(without) == "Claude (subscription)"

      assert {:ok, %Spec{short_name: "Claude"} = with_short} =
               Spec.new(Map.put(base, :short_name, " Claude "))

      assert Spec.short_name(with_short) == "Claude"
      assert with_short.display_name == "Claude (subscription)"

      for invalid <- ["  ", 42] do
        assert {:error, :invalid_short_name} = Spec.new(Map.put(base, :short_name, invalid))
      end
    end
  end
end
