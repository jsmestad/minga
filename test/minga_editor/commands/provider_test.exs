defmodule MingaEditor.Commands.ProviderTest do
  use ExUnit.Case, async: true

  alias Minga.Command

  defp compile_provider(source) do
    suffix = System.unique_integer([:positive])
    module = Module.concat([__MODULE__, "Generated#{suffix}"])
    source = String.replace(source, "__MODULE_UNDER_TEST__", inspect(module))
    Code.compile_string(source)
    module
  end

  test "generates metadata and callbacks for every declaration form" do
    module =
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider

        command :toggle_wrap, "Toggle word wrap",
          requires_buffer: true,
          scope: :editor,
          option_toggle: :wrap

        numbered_commands :workspace_goto, 1..2, "Workspace",
          requires_buffer: false,
          argument: :number,
          execute: &workspace_goto/2

        @command_specs [{:move_left, "Move left", true}]
        commands @command_specs

        command :open_palette, "Open palette",
          requires_buffer: false,
          execute: &open_palette/1

        def execute(state, name), do: Map.put(state, :command, name)
        def workspace_goto(state, n), do: Map.put(state, :workspace, n)
        def open_palette(state), do: Map.put(state, :palette, true)
      end
      """)

    [toggle_wrap, workspace_one, workspace_two, move_left, open_palette] = module.__commands__()

    assert %Command{
             name: :toggle_wrap,
             description: "Toggle word wrap",
             requires_buffer: true,
             scope: :editor,
             option_toggle: :wrap
           } = toggle_wrap

    assert toggle_wrap.execute.(%{}) == %{command: :toggle_wrap}
    assert %Command{name: :workspace_goto_1, description: "Workspace 1"} = workspace_one
    assert %Command{name: :workspace_goto_2, description: "Workspace 2"} = workspace_two
    assert workspace_two.execute.(%{}) == %{workspace: 2}
    assert %Command{name: :move_left, description: "Move left", requires_buffer: true} = move_left
    assert move_left.execute.(%{}) == %{command: :move_left}
    assert %Command{name: :open_palette, requires_buffer: false} = open_palette
    assert open_palette.execute.(%{}) == %{palette: true}
  end

  test "rejects an invalid numbered command declaration" do
    assert_raise CompileError, fn ->
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider
        numbered_commands :bad_range, [1, 2], "Bad", execute: &workspace_goto/2
        def workspace_goto(state, _n), do: state
      end
      """)
    end
  end

  test "rejects invalid command options" do
    assert_raise CompileError, ~r/invalid option_toggle/, fn ->
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider
        command :bad_toggle, "Bad toggle", option_toggle: 123
        def execute(state, _name), do: state
      end
      """)
    end
  end

  test "rejects an invalid command spec list" do
    assert_raise CompileError, fn ->
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider
        @command_specs [{"bad", "Bad command", true}]
        commands @command_specs
        def execute(state, _name), do: state
      end
      """)
    end
  end

  test "rejects duplicate command names within one provider" do
    assert_raise CompileError, ~r/duplicate command names/, fn ->
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider
        command :same, "First"
        command :same, "Second"
        def execute(state, :same), do: state
      end
      """)
    end
  end
end
