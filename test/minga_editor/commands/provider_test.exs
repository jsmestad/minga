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

  test "generates command metadata with default execute/2 routing" do
    module =
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider

        command :toggle_wrap, "Toggle word wrap",
          requires_buffer: true,
          scope: :editor,
          option_toggle: :wrap

        def execute(state, :toggle_wrap), do: Map.put(state, :wrapped, true)
      end
      """)

    assert [cmd] = module.__commands__()
    assert %Command{name: :toggle_wrap} = cmd
    assert cmd.description == "Toggle word wrap"
    assert cmd.requires_buffer
    assert cmd.scope == :editor
    assert cmd.option_toggle == :wrap
    assert cmd.execute.(%{}) == %{wrapped: true}
  end

  test "generates numbered command metadata" do
    module =
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider

        numbered_commands :workspace_goto, 1..3, "Workspace",
          requires_buffer: false,
          argument: :number,
          execute: &workspace_goto/2

        def workspace_goto(state, n), do: Map.put(state, :workspace, n)
      end
      """)

    assert [one, two, three] = module.__commands__()
    assert %Command{name: :workspace_goto_1, description: "Workspace 1"} = one
    assert %Command{name: :workspace_goto_2, description: "Workspace 2"} = two
    assert %Command{name: :workspace_goto_3, description: "Workspace 3"} = three
    assert one.execute.(%{}) == %{workspace: 1}
    assert two.execute.(%{}) == %{workspace: 2}
    assert three.execute.(%{}) == %{workspace: 3}
  end

  test "generates command metadata from command spec lists" do
    module =
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider

        @command_specs [
          {:move_left, "Move left", true},
          {:move_right, "Move right", true}
        ]

        commands @command_specs

        def execute(state, name), do: Map.put(state, :command, name)
      end
      """)

    assert [move_left, move_right] = module.__commands__()
    assert %Command{name: :move_left, description: "Move left", requires_buffer: true} = move_left

    assert %Command{name: :move_right, description: "Move right", requires_buffer: true} =
             move_right

    assert move_left.execute.(%{}) == %{command: :move_left}
    assert move_right.execute.(%{}) == %{command: :move_right}
  end

  test "generates command metadata with explicit execute callbacks" do
    module =
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider

        command :open_palette, "Open palette",
          requires_buffer: false,
          execute: &open_palette/1

        command :annotate_state, "Annotate state",
          requires_buffer: false,
          execute: &Map.put(&1, :annotated, true)

        command :inline_fn, "Inline fn",
          requires_buffer: false,
          execute: fn state -> Map.put(state, :inline, true) end

        def open_palette(state), do: Map.put(state, :palette, true)
      end
      """)

    assert [open_palette, annotate_state, inline_fn] = module.__commands__()
    assert %Command{name: :open_palette, requires_buffer: false} = open_palette
    assert %Command{name: :annotate_state, requires_buffer: false} = annotate_state
    assert %Command{name: :inline_fn, requires_buffer: false} = inline_fn
    assert open_palette.execute.(%{}) == %{palette: true}
    assert annotate_state.execute.(%{}) == %{annotated: true}
    assert inline_fn.execute.(%{}) == %{inline: true}
  end

  test "rejects invalid numbered commands" do
    invalid_sources = [
      "numbered_commands \"bad\", 1..2, \"Bad\", execute: &workspace_goto/2",
      "numbered_commands :bad_range, [1, 2], \"Bad\", execute: &workspace_goto/2",
      "numbered_commands :bad_description, 1..2, \"\", execute: &workspace_goto/2",
      "numbered_commands :bad_argument, 1..2, \"Bad\", argument: :other, execute: &workspace_goto/2",
      "numbered_commands :bad_execute, 1..2, \"Bad\", execute: &workspace_goto/1"
    ]

    for source <- invalid_sources do
      assert_raise CompileError, fn ->
        compile_provider("""
        defmodule __MODULE_UNDER_TEST__ do
          use MingaEditor.Commands.Provider
          #{source}
          def workspace_goto(state, _n), do: state
          def workspace_goto(state), do: state
        end
        """)
      end
    end
  end

  test "rejects invalid option_toggle values" do
    invalid_sources = [
      "command :bad_toggle, \"Bad toggle\", option_toggle: 123",
      "command :bad_toggle_tuple, \"Bad toggle\", option_toggle: {:wrap, &execute/2}",
      "command :bad_toggle_fn, \"Bad toggle\", option_toggle: {:wrap, fn current, _extra -> current end}",
      "numbered_commands :bad_numbered_toggle, 1..2, \"Bad\", option_toggle: 123"
    ]

    for source <- invalid_sources do
      assert_raise CompileError, ~r/invalid option_toggle/, fn ->
        compile_provider("""
        defmodule __MODULE_UNDER_TEST__ do
          use MingaEditor.Commands.Provider
          #{source}
          def execute(state, _name), do: state
          def workspace_goto(state, _n), do: state
        end
        """)
      end
    end
  end

  test "rejects invalid command specs" do
    invalid_sources = [
      "@command_specs [{\"bad\", \"Bad command\", true}]",
      "@command_specs [{:missing_description, \"\", true}]",
      "@command_specs [{:bad_requires_buffer, \"Bad requires buffer\", :yes}]",
      "@command_specs [{:bad_shape, \"Bad shape\"}]"
    ]

    for source <- invalid_sources do
      assert_raise CompileError, fn ->
        compile_provider("""
        defmodule __MODULE_UNDER_TEST__ do
          use MingaEditor.Commands.Provider
          #{source}
          commands @command_specs
          def execute(state, _name), do: state
        end
        """)
      end
    end
  end

  test "rejects invalid command names" do
    assert_raise CompileError, ~r/invalid command name/, fn ->
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider
        command "bad", "Bad command", execute: &execute/1
        def execute(state), do: state
      end
      """)
    end
  end

  test "rejects missing descriptions" do
    assert_raise CompileError, ~r/invalid description for command :missing_description/, fn ->
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider
        command :missing_description, "", execute: &execute/1
        def execute(state), do: state
      end
      """)
    end
  end

  test "rejects invalid execute callback shape" do
    assert_raise CompileError, ~r/invalid execute callback for command :bad_execute/, fn ->
      compile_provider("""
      defmodule __MODULE_UNDER_TEST__ do
        use MingaEditor.Commands.Provider
        command :bad_execute, "Bad execute", execute: &execute/2
        def execute(state, _arg), do: state
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
