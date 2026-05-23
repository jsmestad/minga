defmodule MingaSdkTest do
  use ExUnit.Case, async: true

  describe "Minga.Extension behaviour" do
    test "use Minga.Extension compiles and generates schema functions" do
      defmodule TestExtension do
        use Minga.Extension

        option(:enabled, :boolean, default: true, description: "Enable")
        command(:test_cmd, "Test command", execute: {__MODULE__, :noop})
        keybind(:normal, "SPC m t", :test_cmd, "Test")

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
    end
  end

  describe "API module types compile" do
    test "Overlay types are accessible" do
      assert is_atom(Minga.Extension.Overlay)
    end

    test "AgentAPI types are accessible" do
      assert is_atom(Minga.Extension.AgentAPI)
    end

    test "EditorAPI types are accessible" do
      assert is_atom(MingaEditor.Extension.EditorAPI)
    end

    test "Events types are accessible" do
      assert is_atom(Minga.Events)
      assert %Minga.Events.BufferChangedEvent{buffer: self(), source: :user, delta: nil, version: nil}
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
end
