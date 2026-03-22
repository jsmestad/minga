defmodule Minga.ExtensionTest do
  use ExUnit.Case, async: true

  describe "option/3 DSL macro" do
    defmodule TestExtension do
      use Minga.Extension

      option(:conceal, :boolean,
        default: true,
        description: "Hide markup delimiters"
      )

      option(:bullets, :string_list,
        default: ["◉", "○"],
        description: "Unicode bullets for headings"
      )

      option(:format, {:enum, [:html, :pdf]},
        default: :html,
        description: "Default export format"
      )

      @impl true
      def name, do: :test_ext

      @impl true
      def description, do: "Test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __option_schema__/0 with all declared options" do
      schema = TestExtension.__option_schema__()

      assert schema == [
               {:conceal, :boolean, true, "Hide markup delimiters"},
               {:bullets, :string_list, ["◉", "○"], "Unicode bullets for headings"},
               {:format, {:enum, [:html, :pdf]}, :html, "Default export format"}
             ]
    end

    test "options are in declaration order" do
      names = TestExtension.__option_schema__() |> Enum.map(&elem(&1, 0))
      assert names == [:conceal, :bullets, :format]
    end

    test "descriptions are preserved" do
      descs = TestExtension.__option_schema__() |> Enum.map(&elem(&1, 3))

      assert descs == [
               "Hide markup delimiters",
               "Unicode bullets for headings",
               "Default export format"
             ]
    end
  end

  describe "command/3 DSL macro" do
    defmodule CommandExtension do
      use Minga.Extension

      command(:test_cmd_one, "First command",
        execute: {Minga.ExtensionTest, :noop},
        requires_buffer: true
      )

      command(:test_cmd_two, "Second command", execute: {Minga.ExtensionTest, :noop})

      @impl true
      def name, do: :cmd_ext

      @impl true
      def description, do: "Command test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __command_schema__/0 with all declared commands" do
      schema = CommandExtension.__command_schema__()
      assert length(schema) == 2

      {name1, desc1, opts1} = Enum.at(schema, 0)
      assert name1 == :test_cmd_one
      assert desc1 == "First command"
      assert Keyword.fetch!(opts1, :execute) == {Minga.ExtensionTest, :noop}
      assert Keyword.fetch!(opts1, :requires_buffer) == true

      {name2, desc2, opts2} = Enum.at(schema, 1)
      assert name2 == :test_cmd_two
      assert desc2 == "Second command"
      assert Keyword.fetch!(opts2, :execute) == {Minga.ExtensionTest, :noop}
      refute Keyword.has_key?(opts2, :requires_buffer)
    end

    test "commands are in declaration order" do
      names = CommandExtension.__command_schema__() |> Enum.map(&elem(&1, 0))
      assert names == [:test_cmd_one, :test_cmd_two]
    end
  end

  describe "keybind/4 and keybind/5 DSL macros" do
    defmodule KeybindExtension do
      use Minga.Extension

      keybind(:normal, "SPC m t", :test_cmd, "Test command")
      keybind(:normal, "M-h", :promote, "Promote heading", filetype: :org)
      keybind(:insert, "C-j", :next_line, "Next line")

      @impl true
      def name, do: :keybind_ext

      @impl true
      def description, do: "Keybind test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __keybind_schema__/0 with all declared keybindings" do
      schema = KeybindExtension.__keybind_schema__()
      assert length(schema) == 3

      assert Enum.at(schema, 0) == {:normal, "SPC m t", :test_cmd, "Test command", []}
      assert Enum.at(schema, 1) == {:normal, "M-h", :promote, "Promote heading", [filetype: :org]}
      assert Enum.at(schema, 2) == {:insert, "C-j", :next_line, "Next line", []}
    end

    test "keybindings are in declaration order" do
      keys =
        KeybindExtension.__keybind_schema__()
        |> Enum.map(fn {_mode, key, _cmd, _desc, _opts} -> key end)

      assert keys == ["SPC m t", "M-h", "C-j"]
    end
  end

  describe "extension without options, commands, or keybindings" do
    defmodule BareExtension do
      use Minga.Extension

      @impl true
      def name, do: :bare

      @impl true
      def description, do: "No options"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates empty __option_schema__/0" do
      assert BareExtension.__option_schema__() == []
    end

    test "generates empty __command_schema__/0" do
      assert BareExtension.__command_schema__() == []
    end

    test "generates empty __keybind_schema__/0" do
      assert BareExtension.__keybind_schema__() == []
    end
  end

  describe "mixed DSL extension" do
    defmodule FullExtension do
      use Minga.Extension

      option(:enabled, :boolean,
        default: true,
        description: "Enable the extension"
      )

      command(:full_cmd, "A command",
        execute: {Minga.ExtensionTest, :noop},
        requires_buffer: true
      )

      keybind(:normal, "SPC m f", :full_cmd, "Full command", filetype: :elixir)

      @impl true
      def name, do: :full_ext

      @impl true
      def description, do: "Full test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "all three schemas are populated" do
      assert length(FullExtension.__option_schema__()) == 1
      assert length(FullExtension.__command_schema__()) == 1
      assert length(FullExtension.__keybind_schema__()) == 1
    end
  end

  # Helper used as MFA target in command specs
  @spec noop(map()) :: map()
  def noop(state), do: state
end
