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
      assert {:ok, %Status{availability: :unknown, plan_usage: nil}} = Status.new(:unknown)
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
end
