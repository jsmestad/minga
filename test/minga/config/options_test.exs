defmodule Minga.Config.OptionsTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Options

  @schema [
    {:conceal, :boolean, true, "Hide markup delimiters"},
    {:pretty_bullets, :boolean, true, "Replace heading stars with Unicode bullets"},
    {:heading_bullets, :string_list, ["◉", "○", "◈", "◇"], "Unicode bullets for heading levels"}
  ]

  setup do
    {:ok, pid} = Options.start_link(name: :"options_#{System.unique_integer([:positive])}")
    %{server: pid}
  end

  defp defaults_from_specs do
    Map.new(Options.option_specs(), fn {name, _type, default, _description} -> {name, default} end)
  end

  defp assert_set_get(server, name, value) do
    assert {:ok, ^value} = Options.set(server, name, value)
    assert Options.get(server, name) == value
  end

  describe "defaults" do
    test "returns seeded default values and all defaults", %{server: s} do
      assert Options.get(s, :tab_width) == 2
      assert Options.get(s, :line_numbers) == :hybrid
      assert Options.get(s, :autopair) == true
      assert Options.get(s, :autopair_block) == true
      assert Options.get(s, :scroll_margin) == 5
      assert Options.get(s, :agent_tool_approval) == :destructive

      assert Options.all(s) == defaults_from_specs()
    end
  end

  describe "set/3 and get/2" do
    test "sets and gets representative built-in options", %{server: s} do
      cases = [
        {:tab_width, 4},
        {:line_numbers, :relative},
        {:autopair, false},
        {:autopair_block, false},
        {:scroll_margin, 10},
        {:scroll_margin, 0},
        {:auto_save_delay_ms, 0},
        {:auto_save_delay_ms, 250},
        {:lsp_auto_start, false},
        {:startup_view, :editor},
        {:modeline_left_segments, [:mode, :filename]},
        {:modeline_right_segments, []},
        {:agent_auto_context, false},
        {:font_family, "Fira Code"},
        {:font_size, 16},
        {:font_ligatures, false},
        {:agent_mcp_servers, [%{"name" => "local", "command" => "node"}]}
      ]

      for {name, value} <- cases do
        assert_set_get(s, name, value)
      end
    end
  end

  describe "type validation" do
    test "rejects invalid built-in option values", %{server: s} do
      cases = [
        {:tab_width, 0, "positive integer"},
        {:tab_width, -1, nil},
        {:tab_width, "4", nil},
        {:line_numbers, :fancy, "must be one of"},
        {:line_numbers, "hybrid", nil},
        {:autopair, 1, "boolean"},
        {:autopair_block, 1, "boolean"},
        {:scroll_margin, -1, nil},
        {:auto_save_delay_ms, -1, nil},
        {:modeline_left_segments, [:mode, "filename"], "list of atoms"},
        {:modeline_separator, :triangle, "must be one of"},
        {:font_family, :menlo, nil},
        {:font_size, 0, nil},
        {:font_size, 13.5, nil},
        {:font_weight, :extra_bold, "must be one of"},
        {:font_weight, 5, nil},
        {:font_ligatures, "yes", nil},
        {:startup_view, :hybrid, "must be one of"},
        {:startup_view, "agent", nil},
        {:agent_auto_context, :yes, nil},
        {:agent_mcp_servers, %{"name" => "local"}, "list of maps"},
        {:agent_destructive_tools, "shell", nil},
        {:agent_destructive_tools, [:shell, :write_file], nil}
      ]

      for {name, value, message} <- cases do
        assert {:error, error} = Options.set(s, name, value)
        if message, do: assert(error =~ message)
      end

      assert {:error, msg} = Options.set(s, :nonexistent, 42)
      assert msg =~ "unknown option"
    end

    test "accepts enum and list variants", %{server: s} do
      for weight <- [:thin, :light, :regular, :medium, :semibold, :bold, :heavy, :black] do
        assert_set_get(s, :font_weight, weight)
      end

      assert {:ok, :auto} = Options.set(s, :agent_provider, :auto)
      assert {:ok, :native} = Options.set(s, :agent_provider, :native)
      assert {:ok, :editor} = Options.set(s, :startup_view, :editor)
      assert {:ok, :agent} = Options.set(s, :startup_view, :agent)
      assert {:ok, false} = Options.set(s, :agent_auto_context, false)
      assert {:ok, true} = Options.set(s, :agent_auto_context, true)
    end

    test "agent_provider rejects removed pi_rpc with migration guidance", %{server: s} do
      assert {:error, msg} = Options.set(s, :agent_provider, :pi_rpc)
      assert msg =~ "agent_provider no longer supports :pi_rpc"
      assert msg =~ "Use :native instead"
    end
  end

  describe "reset/1" do
    test "restores globals and clears filetype/extension overrides", %{server: s} do
      Options.set(s, :tab_width, 8)
      Options.set(s, :autopair, false)
      Options.set(s, :autopair_block, false)
      Options.set_for_filetype(s, :go, :tab_width, 8)
      Options.register_extension_schema(s, :minga_org, @schema, [])

      Options.reset(s)

      assert Options.get(s, :tab_width) == 2
      assert Options.get(s, :autopair) == true
      assert Options.get(s, :autopair_block) == true
      assert Options.get_for_filetype(s, :tab_width, :go) == 2
      assert Options.extension_schema(s, :minga_org) == nil
      assert Options.get_extension_option(s, :minga_org, :conceal) == nil
    end

    test "publishes cursor animation default when reset re-enables it" do
      registry = :"#{__MODULE__}.reset_events.#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})
      server = start_supervised!({Options, name: nil, events_registry: registry})
      Minga.Events.subscribe(:option_changed, registry)

      assert {:ok, false} = Options.set(server, :cursor_animate, false)
      Options.reset(server)

      assert_receive {:minga_event, :option_changed,
                      %Minga.Events.OptionChangedEvent{
                        source: ^server,
                        name: :cursor_animate,
                        value: true
                      }}
    end
  end

  describe "built-in option introspection" do
    test "defaults, valid_names, type_for, option_specs, and describe stay consistent" do
      assert Options.default(:tab_width) == 2
      assert Options.default(:line_numbers) == :hybrid
      assert Options.type_for(:tab_width) == :pos_integer
      assert Options.type_for(:autopair) == :boolean
      assert Options.type_for(:autopair_block) == :boolean
      assert Options.type_for(:line_numbers) == {:enum, [:hybrid, :absolute, :relative, :none]}
      assert Options.type_for(:theme) == :theme_atom
      assert Options.type_for(:font_family) == :string
      assert Options.type_for(:nonexistent) == nil

      names = Options.valid_names()

      for name <- [:tab_width, :line_numbers, :autopair, :autopair_block, :scroll_margin],
          do: assert(name in names)

      specs = Options.option_specs()
      assert is_list(specs)
      assert length(specs) == length(names)

      for {name, _type, default, description} <- specs do
        assert is_atom(name)
        assert name in names
        assert Options.default(name) == default
        assert is_binary(description)
        assert description != ""
      end

      assert %{name: :tab_width, type: :pos_integer, default: 2, description: description} =
               Options.describe(:tab_width)

      assert description =~ "tab"
      assert Options.describe(:does_not_exist) == nil
    end

    test "reports default, global, and filetype config sources", %{server: s} do
      assert Options.provenance(s, :tab_width, :go) == ["default"]

      Options.set(s, :tab_width, 4)
      assert Options.provenance(s, :tab_width, :go) == ["default", "config.exs"]

      Options.set_for_filetype(s, :go, :tab_width, 8)
      assert Options.provenance(s, :tab_width, :go) == ["default", "config.exs", "filetype :go"]
    end
  end

  describe "per-filetype options" do
    test "filetype overrides shadow globals and reset clears them", %{server: s} do
      Options.set(s, :tab_width, 2)
      Options.set_for_filetype(s, :go, :tab_width, 8)
      Options.set_for_filetype(s, :python, :tab_width, 4)

      assert Options.get_for_filetype(s, :tab_width, :go) == 8
      assert Options.get_for_filetype(s, :tab_width, :python) == 4
      assert Options.get_for_filetype(s, :tab_width, :elixir) == 2
      assert Options.get_for_filetype(s, :tab_width, nil) == 2
      assert Options.get(s, :tab_width) == 2

      assert {:error, _} = Options.set_for_filetype(s, :go, :tab_width, -1)

      Options.reset(s)
      assert Options.get_for_filetype(s, :tab_width, :go) == 2
    end

    test "built-in prose filetypes default to wrap enabled", %{server: s} do
      for filetype <- [:markdown, :gitcommit, :text],
          do: assert(Options.get_for_filetype(s, :wrap, filetype) == true)

      assert Options.get_for_filetype(s, :wrap, :elixir) == false
    end
  end

  describe "agent approval options" do
    test "validates approval mode and destructive tool list", %{server: s} do
      assert Options.get(s, :agent_tool_approval) == :destructive

      for mode <- [:all, :none] do
        assert_set_get(s, :agent_tool_approval, mode)
      end

      assert {:error, _} = Options.set(s, :agent_tool_approval, :always)

      default_tools = [
        "write_file",
        "edit_file",
        "multi_edit_file",
        "shell",
        "git_stage",
        "git_commit",
        "rename"
      ]

      assert Options.get(s, :agent_destructive_tools) == default_tools

      for custom <- [["shell", "write_file"], []] do
        assert_set_get(s, :agent_destructive_tools, custom)
      end
    end
  end

  describe "extension option schema" do
    test "registers schema, seeds defaults, accepts user overrides, and validates registration",
         %{server: s} do
      assert :ok = Options.register_extension_schema(s, :minga_org, @schema, [])
      assert Options.get_extension_option(s, :minga_org, :conceal) == true
      assert Options.get_extension_option(s, :minga_org, :pretty_bullets) == true
      assert Options.get_extension_option(s, :minga_org, :heading_bullets) == ["◉", "○", "◈", "◇"]

      assert :ok =
               Options.register_extension_schema(s, :minga_org, @schema,
                 conceal: false,
                 heading_bullets: ["•", "◦"]
               )

      assert Options.get_extension_option(s, :minga_org, :conceal) == false
      assert Options.get_extension_option(s, :minga_org, :heading_bullets) == ["•", "◦"]
      assert Options.get_extension_option(s, :minga_org, :pretty_bullets) == true

      assert {:error, msg} =
               Options.register_extension_schema(s, :bad_org, @schema, conceal: "yes")

      assert msg =~ "boolean"

      assert :ok =
               Options.register_extension_schema(s, :unknown_key_org, @schema, unknown_key: true)
    end

    test "sets extension options with schema validation", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])

      assert {:ok, false} = Options.set_extension_option(s, :minga_org, :conceal, false)
      assert Options.get_extension_option(s, :minga_org, :conceal) == false

      assert {:error, msg} = Options.set_extension_option(s, :minga_org, :conceal, "nope")
      assert msg =~ "boolean"

      assert {:error, msg} = Options.set_extension_option(s, :minga_org, :nonexistent, true)
      assert msg =~ "unknown option"
    end

    test "supports enum descriptors and same option names across extensions", %{server: s} do
      schema = [{:format, {:enum, [:html, :pdf, :md]}, :html, "Default export format"}]
      Options.register_extension_schema(s, :exporter, schema, [])

      assert Options.get_extension_option(s, :exporter, :format) == :html
      assert {:ok, :pdf} = Options.set_extension_option(s, :exporter, :format, :pdf)
      assert {:error, _} = Options.set_extension_option(s, :exporter, :format, :docx)

      Options.register_extension_schema(
        s,
        :ext_a,
        [{:conceal, :boolean, true, "Ext A conceal"}],
        []
      )

      Options.register_extension_schema(
        s,
        :ext_b,
        [{:conceal, :boolean, false, "Ext B conceal"}],
        []
      )

      Options.set_extension_option(s, :ext_a, :conceal, false)
      Options.set_extension_option(s, :ext_b, :conceal, true)

      assert Options.get_extension_option(s, :ext_a, :conceal) == false
      assert Options.get_extension_option(s, :ext_b, :conceal) == true
    end

    test "supports per-filetype extension overrides with global fallback", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, conceal: false)

      assert Options.get_extension_option_for_filetype(s, :minga_org, :conceal, :org) == false
      assert Options.get_extension_option_for_filetype(s, :minga_org, :conceal, nil) == false

      assert {:ok, true} =
               Options.set_extension_option_for_filetype(s, :minga_org, :org, :conceal, true)

      assert Options.get_extension_option_for_filetype(s, :minga_org, :conceal, :org) == true
      assert Options.get_extension_option(s, :minga_org, :conceal) == false

      assert Options.get_extension_option_for_filetype(s, :minga_org, :conceal, :markdown) ==
               false

      assert {:error, msg} =
               Options.set_extension_option_for_filetype(s, :minga_org, :org, :conceal, "nope")

      assert msg =~ "boolean"
    end

    test "exposes extension schema and option descriptions", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])

      assert Options.extension_schema(s, :minga_org) == @schema
      assert Options.extension_schema(s, :unknown) == nil

      assert Options.extension_option_description(s, :minga_org, :conceal) ==
               "Hide markup delimiters"

      assert Options.extension_option_description(s, :minga_org, :pretty_bullets) ==
               "Replace heading stars with Unicode bullets"

      assert Options.extension_option_description(s, :minga_org, :nonexistent) == nil
      assert Options.extension_option_description(s, :unknown, :conceal) == nil
    end

    test "re-registration preserves user-set values", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])
      Options.set_extension_option(s, :minga_org, :conceal, false)

      Options.register_extension_schema(s, :minga_org, @schema, [])
      assert Options.get_extension_option(s, :minga_org, :conceal) == false
    end
  end

  describe "extension option introspection" do
    test "lists, describes, and reports provenance for registered extension options", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, conceal: false)
      Options.set_extension_option_for_filetype(s, :minga_org, :org, :conceal, true)

      assert %{extension: :minga_org, name: :conceal, default: true} =
               Options.describe_extension_option(s, :minga_org, :conceal)

      assert Enum.any?(Options.extension_option_specs(s), &(&1.extension == :minga_org))

      assert Options.extension_provenance(s, :minga_org, :conceal, :org) == [
               "default",
               "config.exs",
               "filetype :org"
             ]
    end
  end
end
