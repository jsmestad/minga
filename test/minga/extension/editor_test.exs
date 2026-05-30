defmodule Minga.Extension.EditorTest do
  use ExUnit.Case, async: true

  describe "option/3 DSL macro" do
    defmodule OptionExtension do
      use Minga.Extension.Editor

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
      def name, do: :editor_opt_ext

      @impl true
      def description, do: "Option test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __option_schema__/0 with all declared options" do
      schema = OptionExtension.__option_schema__()

      assert schema == [
               {:conceal, :boolean, true, "Hide markup delimiters"},
               {:bullets, :string_list, ["◉", "○"], "Unicode bullets for headings"},
               {:format, {:enum, [:html, :pdf]}, :html, "Default export format"}
             ]
    end

    test "options are in declaration order" do
      names = OptionExtension.__option_schema__() |> Enum.map(&elem(&1, 0))
      assert names == [:conceal, :bullets, :format]
    end

    test "descriptions are preserved" do
      descs = OptionExtension.__option_schema__() |> Enum.map(&elem(&1, 3))

      assert descs == [
               "Hide markup delimiters",
               "Unicode bullets for headings",
               "Default export format"
             ]
    end
  end

  describe "command/3 DSL macro" do
    defmodule CommandExtension do
      use Minga.Extension.Editor

      command(:test_cmd_one, "First command",
        execute: {Minga.Extension.EditorTest, :noop},
        requires_buffer: true
      )

      command(:test_cmd_two, "Second command", execute: {Minga.Extension.EditorTest, :noop})

      @impl true
      def name, do: :editor_cmd_ext

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
      assert Keyword.fetch!(opts1, :execute) == {Minga.Extension.EditorTest, :noop}
      assert Keyword.fetch!(opts1, :requires_buffer) == true

      {name2, desc2, opts2} = Enum.at(schema, 1)
      assert name2 == :test_cmd_two
      assert desc2 == "Second command"
      assert Keyword.fetch!(opts2, :execute) == {Minga.Extension.EditorTest, :noop}
      refute Keyword.has_key?(opts2, :requires_buffer)
    end

    test "commands are in declaration order" do
      names = CommandExtension.__command_schema__() |> Enum.map(&elem(&1, 0))
      assert names == [:test_cmd_one, :test_cmd_two]
    end
  end

  describe "keybind/4 and keybind/5 DSL macros" do
    defmodule KeybindExtension do
      use Minga.Extension.Editor

      keybind(:normal, "SPC m t", :test_cmd, "Test command")
      keybind(:normal, "M-h", :promote, "Promote heading", filetype: :org)
      keybind(:insert, "C-j", :next_line, "Next line")

      @impl true
      def name, do: :editor_kb_ext

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

  describe "modeline_segment/2 and modeline_segment/3 DSL macros" do
    defmodule ModelineExtension do
      use Minga.Extension.Editor

      modeline_segment :word_count, side: :right, priority: 50 do
        {" #{ctx.word_count} ", :white, :black, [], nil}
      end

      modeline_segment :simple_status do
        _ctx = ctx
        {" OK ", :green, :black, [], nil}
      end

      @impl true
      def name, do: :editor_modeline_ext

      @impl true
      def description, do: "Modeline test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __modeline_segment_schema__/0 with all declared segments" do
      schema = ModelineExtension.__modeline_segment_schema__()
      assert length(schema) == 2

      {name1, opts1, {mod1, fun1}} = Enum.at(schema, 0)
      assert name1 == :word_count
      assert opts1 == [side: :right, priority: 50]
      assert mod1 == ModelineExtension
      assert fun1 == :__modeline_segment_word_count__

      {name2, opts2, {mod2, fun2}} = Enum.at(schema, 1)
      assert name2 == :simple_status
      assert opts2 == []
      assert mod2 == ModelineExtension
      assert fun2 == :__modeline_segment_simple_status__
    end

    test "segment render functions are callable" do
      ctx = %{word_count: 42}
      assert ModelineExtension.__modeline_segment_word_count__(ctx) == {" 42 ", :white, :black, [], nil}
      assert ModelineExtension.__modeline_segment_simple_status__(%{}) == {" OK ", :green, :black, [], nil}
    end

    test "segments are in declaration order" do
      names = ModelineExtension.__modeline_segment_schema__() |> Enum.map(&elem(&1, 0))
      assert names == [:word_count, :simple_status]
    end
  end

  describe "capability/2 DSL macro" do
    defmodule CapabilityExtension do
      use Minga.Extension.Editor

      capability :filetype, :org
      capability :filetype, :markdown
      capability :ui, :overlay

      @impl true
      def name, do: :editor_cap_ext

      @impl true
      def description, do: "Capability test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __capability_schema__/0 with all declared capabilities" do
      schema = CapabilityExtension.__capability_schema__()

      assert schema == [
               {:filetype, :org},
               {:filetype, :markdown},
               {:ui, :overlay}
             ]
    end

    test "capabilities are in declaration order" do
      families = CapabilityExtension.__capability_schema__() |> Enum.map(&elem(&1, 0))
      assert families == [:filetype, :filetype, :ui]
    end
  end

  describe "extension without any declarations" do
    defmodule BareExtension do
      use Minga.Extension.Editor

      @impl true
      def name, do: :editor_bare

      @impl true
      def description, do: "No declarations"

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

    test "generates empty __modeline_segment_schema__/0" do
      assert BareExtension.__modeline_segment_schema__() == []
    end

    test "generates empty __capability_schema__/0" do
      assert BareExtension.__capability_schema__() == []
    end
  end

  describe "default child_spec/1" do
    defmodule ChildSpecExtension do
      use Minga.Extension.Editor

      @impl true
      def name, do: :editor_childspec_ext

      @impl true
      def description, do: "Child spec test"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "returns a valid supervisor child spec" do
      spec = ChildSpecExtension.child_spec(foo: :bar)
      assert spec.id == ChildSpecExtension
      assert spec.restart == :permanent
      assert spec.type == :worker
      assert {Agent, :start_link, [fun]} = spec.start
      assert is_function(fun, 0)
      assert fun.() == [foo: :bar]
    end
  end

  describe "mixed DSL extension" do
    defmodule FullExtension do
      use Minga.Extension.Editor

      option(:enabled, :boolean,
        default: true,
        description: "Enable the extension"
      )

      command(:full_cmd, "A command",
        execute: {Minga.Extension.EditorTest, :noop},
        requires_buffer: true
      )

      keybind(:normal, "SPC m f", :full_cmd, "Full command", filetype: :elixir)

      modeline_segment :status, side: :left do
        _ctx = ctx
        {" ACTIVE ", :green, :black, [], nil}
      end

      capability :filetype, :elixir

      @impl true
      def name, do: :editor_full_ext

      @impl true
      def description, do: "Full test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "all five schemas are populated" do
      assert length(FullExtension.__option_schema__()) == 1
      assert length(FullExtension.__command_schema__()) == 1
      assert length(FullExtension.__keybind_schema__()) == 1
      assert length(FullExtension.__modeline_segment_schema__()) == 1
      assert length(FullExtension.__capability_schema__()) == 1
    end
  end

  # Helper used as MFA target in command specs
  @spec noop(map()) :: map()
  def noop(state), do: state
end
