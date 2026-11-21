defmodule MingaSdkTest do
  use ExUnit.Case, async: true

  describe "Minga.Extension behaviour" do
    test "use Minga.Extension compiles and generates schema functions" do
      defmodule TestExtension do
        use Minga.Extension

        option(:enabled, :boolean, default: true, description: "Enable")
        command(:test_cmd, "Test command", execute: {__MODULE__, :noop})
        keybind(:normal, "SPC m t", :test_cmd, "Test")
        editor_event_handler(__MODULE__, [:buffer_saved, :editor_action, :source_unload])

        @impl true
        def name, do: :test_ext

        @impl true
        def description, do: "Test extension"

        @impl true
        def version, do: "0.1.0"

        @impl true
        def init(_config), do: {:ok, %{}}

        def noop(state), do: state
      end

      assert TestExtension.name() == :test_ext
      assert [opt] = TestExtension.__option_schema__()
      assert elem(opt, 0) == :enabled
      assert [cmd] = TestExtension.__command_schema__()
      assert elem(cmd, 0) == :test_cmd
      assert [kb] = TestExtension.__keybind_schema__()
      assert elem(kb, 2) == :test_cmd

      assert TestExtension.__editor_event_handler_schema__() == [
               {TestExtension, [:buffer_saved, :editor_action, :source_unload], []}
             ]
    end
  end

  test "editor declarations and a callback compile against the standalone SDK" do
    defmodule TestEditorExtension do
      use Minga.Extension.Editor

      @behaviour MingaEditor.Extension.EventHandler

      option(:enabled, :boolean, default: true, description: "Enable")
      editor_event_handler(__MODULE__, [:buffer_saved], priority: 30)

      @impl Minga.Extension
      def name, do: :test_editor_ext

      @impl Minga.Extension
      def description, do: "Test editor extension"

      @impl Minga.Extension
      def version, do: "0.1.0"

      @impl Minga.Extension
      def init(_config), do: {:ok, %{}}

      @impl MingaEditor.Extension.EventHandler
      def handle_editor_event(state, {:buffer_saved, _buffer}), do: {:handled, state}
    end

    assert TestEditorExtension.__option_schema__() == [{:enabled, :boolean, true, "Enable"}]

    assert TestEditorExtension.__editor_event_handler_schema__() == [
             {TestEditorExtension, [:buffer_saved], [priority: 30]}
           ]
  end

  describe "agent declaration contract" do
    test "agent UI declarations compile into the SDK schema" do
      defmodule TestAgentExtension do
        use Minga.Extension.Agent

        option(:enabled, :boolean, default: false, description: "Enable")
        agent_ui(id: "status", surface: :panel, payload: %{text: "Ready"})

        @impl true
        def name, do: :test_agent_ext

        @impl true
        def description, do: "Test agent extension"

        @impl true
        def version, do: "0.1.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end

      assert TestAgentExtension.__option_schema__() == [{:enabled, :boolean, false, "Enable"}]

      assert TestAgentExtension.__agent_ui_schema__() == [
               [id: "status", surface: :panel, payload: %{text: "Ready"}]
             ]
    end
  end

  describe "runtime callback family contract" do
    test "family type contains only retained events" do
      {:ok, types} = Code.Typespec.fetch_types(Minga.Extension)

      assert {:type, {:editor_event_family, family_type, []}} =
               Enum.find(types, fn
                 {:type, {:editor_event_family, _type, []}} -> true
                 _other -> false
               end)

      assert {:editor_event_family, family_type, []}
             |> Code.Typespec.type_to_quoted()
             |> Macro.to_string() ==
               "editor_event_family() :: :buffer_saved | :editor_action | :source_unload"

      assert {:type, {:extension_status, status_type, []}} =
               Enum.find(types, fn
                 {:type, {:extension_status, _type, []}} -> true
                 _other -> false
               end)

      assert {:extension_status, status_type, []}
             |> Code.Typespec.type_to_quoted()
             |> Macro.to_string() ==
               "extension_status() :: :running | :stopped | :crashed | :load_error | :stub"
    end
  end

  describe "API module types compile" do
    test "Overlay types are accessible" do
      assert is_atom(Minga.Extension.Overlay)
    end

    test "AgentAPI types are accessible" do
      assert is_atom(Minga.Extension.AgentAPI)
    end

    test "Diagnostics types are accessible" do
      assert is_atom(Minga.Extension.Diagnostics)
    end

    test "EditorAPI types are accessible" do
      assert is_atom(MingaEditor.Extension.EditorAPI)
    end

    test "Events types are accessible" do
      assert is_atom(Minga.Events)

      assert %Minga.Events.BufferChangedEvent{
        buffer: self(),
        source: :user,
        delta: nil,
        version: nil
      }
    end

    test "Buffer types are accessible" do
      assert is_atom(Minga.Buffer)
    end

    test "EditSource type is accessible" do
      assert is_atom(Minga.Buffer.EditSource)
    end

    test "EditDelta struct is accessible" do
      delta = %Minga.Buffer.EditDelta{
        start_byte: 0,
        old_end_byte: 5,
        new_end_byte: 10,
        start_position: {0, 0},
        old_end_position: {0, 5},
        new_end_position: {0, 10},
        inserted_text: "hello"
      }

      assert delta.new_end_position == {0, 10}
    end
  end

  describe "runtime stubs raise" do
    test "Overlay.set/4 raises at runtime" do
      assert_raise RuntimeError, ~r/compile-time only/, fn ->
        Minga.Extension.Overlay.set(:test, "id", self(), position: {0, 0})
      end
    end

    test "AgentAPI.list_sessions/0 raises at runtime" do
      assert_raise RuntimeError, ~r/compile-time only/, fn ->
        Minga.Extension.AgentAPI.list_sessions()
      end
    end

    test "EditorAPI.set_status/2 raises at runtime" do
      assert_raise RuntimeError, ~r/compile-time only/, fn ->
        MingaEditor.Extension.EditorAPI.set_status(%{}, "test")
      end
    end
  end

  describe "model route contract" do
    test "a route extension compiles against the standalone SDK" do
      defmodule TestRoute do
        @behaviour MingaAgent.InferenceRoute

        alias MingaAgent.InferenceRoute.{ConversationRef, Message, Model, Request, Response}
        alias MingaAgent.InferenceRoute.{ToolCall, Usage}

        @impl true
        def models(_config) do
          [
            %Model{
              id: "test-model",
              display_name: "Test Model",
              context_window: 100_000,
              max_output: 8_000,
              reasoning_levels: ["off"],
              tools?: true,
              images_in?: false,
              tool_result_images?: false,
              compaction: :native,
              usage: :tokens,
              cost: :subscription
            }
          ]
        end

        @impl true
        def availability(_route_id, _credential), do: {:ready, "me@example.com"}

        @impl true
        def stream(%Request{conversation: %ConversationRef{purpose: purpose}} = request) do
          reply =
            case {purpose, request.messages} do
              {:turn, [%Message{role: :user, content: [{:text, _prompt} | _rest]} | _history]} ->
                [
                  {:tool_call,
                   %ToolCall{id: "t1", name: "read_file", arguments: %{"path" => "a"}}}
                ]

              _isolated ->
                [{:text, "summary"}]
            end

          events =
            reply ++ [{:usage, %Usage{input_tokens: 1}}, {:finish, :stop}]

          {:ok, %Response{events: events, cancel: fn -> :ok end}}
        end

        @impl true
        def classify_error(_reason), do: {:provider_error, "The test route failed."}
      end

      defmodule TestRouteExtension do
        use Minga.Extension

        @impl true
        def name, do: :test_route_ext

        @impl true
        def description, do: "Test route extension"

        @impl true
        def version, do: "0.1.0"

        @impl true
        def init(_config) do
          {:ok, reporter} =
            Minga.Extension.ModelRoutes.register(
              id: "test_route",
              module: MingaSdkTest.TestRoute,
              display_name: "Test Route",
              setup_action: %{label: "Use Test Route", description: "Sign in with the test CLI."}
            )

          :ok =
            Minga.Extension.ModelRoutes.report_usage(reporter, [
              %MingaAgent.InferenceRoute.PlanWindow{
                kind: "five_hour",
                utilization: 0.5,
                resets_at: nil,
                status: :allowed
              }
            ])

          {:ok, %{reporter: reporter}}
        end
      end

      assert [%MingaAgent.InferenceRoute.Model{id: "test-model"}] = TestRoute.models([])
      assert {:ready, _account} = TestRoute.availability("test_route", nil)

      request = %MingaAgent.InferenceRoute.Request{
        model: hd(TestRoute.models([])),
        messages: [%MingaAgent.InferenceRoute.Message{role: :user, content: [{:text, "hi"}]}],
        tools: [],
        options: %MingaAgent.InferenceRoute.Options{max_output_tokens: 100},
        conversation: %MingaAgent.InferenceRoute.ConversationRef{
          session_id: "s",
          owner: self(),
          epoch_id: "e",
          conversation_revision: 1,
          request_id: "r",
          purpose: :turn
        }
      }

      assert {:ok, %MingaAgent.InferenceRoute.Response{events: events}} =
               TestRoute.stream(request)

      assert {:finish, :stop} = List.last(events)

      assert_raise RuntimeError, ~r/compile-time only/, fn -> TestRouteExtension.init([]) end
    end
  end
end
