Code.require_file("credo/checks/command_registration_check.exs")

defmodule Minga.Credo.CommandRegistrationCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.CommandRegistrationCheck

  @moduletag :credo

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "current command registration sites are in sync" do
    "defmodule Minga.Command.Parser do end"
    |> to_source_file("lib/minga/command/parser.ex")
    |> run_check(CommandRegistrationCheck, [])
    |> refute_issues()
  end

  test "flags parser atoms missing from the parsed type" do
    root = fixture_root()

    write_parser_fixture(root, """
    defmodule Minga.Command.Parser do
      @type parsed :: {:bar, []}
      defp do_parse("foo"), do: {:foo, []}
    end
    """)

    write_commands_fixture(
      root,
      "def execute(state, {:execute_ex_command, {:foo, []}}), do: state"
    )

    write_registry_fixture(root, [])

    issues = check_fixture(root)

    assert Enum.any?(issues, fn issue ->
             issue.message =~ "missing from `@type parsed`" and issue.message =~ "foo"
           end)
  end

  test "flags parsed type atoms the parser never returns" do
    root = fixture_root()

    write_parser_fixture(root, """
    defmodule Minga.Command.Parser do
      @type parsed :: {:foo, []} | {:bar, []}
      defp do_parse("foo"), do: {:foo, []}
    end
    """)

    write_commands_fixture(
      root,
      "def execute(state, {:execute_ex_command, {:foo, []}}), do: state"
    )

    write_registry_fixture(root, [])

    issues = check_fixture(root)

    assert Enum.any?(issues, fn issue ->
             issue.message =~ "contains ex-command atoms that the parser never returns" and
               issue.message =~ "bar"
           end)
  end

  test "flags parser atoms with no direct dispatcher or registered provider command" do
    root = fixture_root()

    write_parser_fixture(root, """
    defmodule Minga.Command.Parser do
      @type parsed :: {:foo, []}
      defp do_parse("foo"), do: {:foo, []}
    end
    """)

    write_commands_fixture(root, "")
    write_registry_fixture(root, [])

    issues = check_fixture(root)

    assert Enum.any?(issues, fn issue ->
             issue.message =~ "no direct dispatcher or registered provider command" and
               issue.message =~ "foo"
           end)
  end

  test "flags registry modules that do not declare a provider" do
    root = fixture_root()

    write_parser_fixture(root, """
    defmodule Minga.Command.Parser do
      @type parsed :: {:foo, []}
      defp do_parse("foo"), do: {:foo, []}
    end
    """)

    write_commands_fixture(
      root,
      "def execute(state, {:execute_ex_command, {:foo, []}}), do: state"
    )

    write_registry_fixture(root, ["MingaEditor.Commands.Broken"])

    write_fixture(root, "lib/minga_editor/commands/broken.ex", """
    defmodule MingaEditor.Commands.Broken do
      def execute(state, :broken), do: state
    end
    """)

    issues = check_fixture(root)

    assert Enum.any?(issues, fn issue ->
             issue.message =~ "do not declare `Minga.Command.Provider`" and
               issue.message =~ "MingaEditor.Commands.Broken"
           end)
  end

  test "flags provider modules missing from the registry" do
    root = fixture_root()

    write_parser_fixture(root, """
    defmodule Minga.Command.Parser do
      @type parsed :: {:foo, []}
      defp do_parse("foo"), do: {:foo, []}
    end
    """)

    write_commands_fixture(
      root,
      "def execute(state, {:execute_ex_command, {:foo, []}}), do: state"
    )

    write_provider_source(root, "Foo", """
      use MingaEditor.Commands.Provider
      command(:foo, "Foo", requires_buffer: false)
    """)

    write_registry_fixture(root, [])

    issues = check_fixture(root)

    assert Enum.any?(issues, fn issue ->
             issue.message =~ "missing from `Minga.Command.Registry @command_modules`" and
               issue.message =~ "MingaEditor.Commands.Foo"
           end)
  end

  test "accepts command macros, command spec lists, command structs, and ignores unrelated tuples" do
    root = fixture_root()

    write_parser_fixture(root, """
    defmodule Minga.Command.Parser do
      @type parsed :: {:foo, []} | {:bar, []} | {:baz, []}
      defp do_parse("foo"), do: {:foo, []}
      defp do_parse("bar"), do: {:bar, []}
      defp do_parse("baz"), do: {:baz, []}
    end
    """)

    write_commands_fixture(
      root,
      "def execute(state, {:execute_ex_command, {:foo, []}}), do: state"
    )

    write_provider_source(
      root,
      "Mixed",
      """
      @behaviour Minga.Command.Provider

      alias Minga.Command

      command(:foo, "Foo", requires_buffer: false)

      @command_specs [
        {:bar, "Bar", true}
      ]

      commands(@command_specs)

      def __commands__ do
        [
          %Minga.Command{
            name: :baz,
            description: "Baz",
            requires_buffer: false,
            execute: fn state -> state end
          }
        ]
      end

      @status_messages [
        {:error, "No active file"}
      ]
      """
    )

    write_registry_fixture(root, ["MingaEditor.Commands.Mixed"])

    root
    |> check_fixture()
    |> refute_issues()
  end

  defp check_fixture(root) do
    "defmodule Minga.Command.Parser do end"
    |> to_source_file(Path.join(root, "lib/minga/command/parser.ex"))
    |> run_check(CommandRegistrationCheck, root_path: root)
  end

  defp fixture_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "minga-command-registration-check-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_parser_fixture(root, content) do
    write_fixture(root, "lib/minga/command/parser.ex", content)
  end

  defp write_commands_fixture(root, body) do
    write_fixture(root, "lib/minga_editor/commands.ex", """
    defmodule MingaEditor.Commands do
      @ex_tuple_dispatch_commands []
      #{body}
    end
    """)

    write_fixture(root, "lib/minga_editor/commands/buffer_management.ex", """
    defmodule MingaEditor.Commands.BufferManagement do
    end
    """)
  end

  defp write_registry_fixture(root, modules) do
    module_entries = Enum.join(modules, ",\n")

    write_fixture(root, "lib/minga/command/registry.ex", """
    defmodule Minga.Command.Registry do
      @command_modules [
        #{module_entries}
      ]
    end
    """)
  end

  defp write_provider_source(root, name, body) do
    write_fixture(root, "lib/minga_editor/commands/#{Macro.underscore(name)}.ex", """
    defmodule MingaEditor.Commands.#{name} do
    #{body}
    end
    """)
  end

  defp write_fixture(root, path, content) do
    full_path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end
end
