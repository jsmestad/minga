defmodule Minga.Config.OptionsTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Options

  setup do
    {:ok, pid} = Options.start_link(name: :"options_#{System.unique_integer([:positive])}")
    %{server: pid}
  end

  describe "defaults" do
    test "tab_width defaults to 2", %{server: s} do
      assert Options.get(s, :tab_width) == 2
    end

    test "line_numbers defaults to :hybrid", %{server: s} do
      assert Options.get(s, :line_numbers) == :hybrid
    end

    test "autopair defaults to true", %{server: s} do
      assert Options.get(s, :autopair) == true
    end

    test "scroll_margin defaults to 5", %{server: s} do
      assert Options.get(s, :scroll_margin) == 5
    end

    test "all/1 returns all defaults", %{server: s} do
      assert Options.all(s) == %{
               editing_model: :vim,
               space_leader: :chord,
               tab_width: 2,
               line_numbers: :hybrid,
               show_gutter_separator: true,
               autopair: true,
               scroll_margin: 5,
               scroll_lines: 1,
               theme: :doom_one,
               indent_with: :spaces,
               trim_trailing_whitespace: false,
               insert_final_newline: false,
               format_on_save: false,
               formatter: nil,
               title_format: "{filename} {dirty}({directory}) - Minga",
               recent_files_limit: 200,
               persist_recent_files: true,
               clipboard: :unnamedplus,
               wrap: false,
               linebreak: true,
               breakindent: true,
               agent_provider: :auto,
               agent_model: nil,
               agent_tool_approval: :destructive,
               agent_destructive_tools: [
                 "write_file",
                 "edit_file",
                 "multi_edit_file",
                 "shell",
                 "git_stage",
                 "git_commit",
                 "rename"
               ],
               agent_session_retention_days: 30,
               agent_panel_split: 65,
               startup_view: :agent,
               agent_auto_context: true,
               agent_max_tokens: 16_384,
               agent_max_retries: 3,
               agent_models: [],
               agent_prompt_cache: true,
               agent_notifications: true,
               agent_notify_on: [:approval, :complete, :error],
               agent_max_turns: 100,
               agent_max_cost: nil,
               agent_flush_before_shell: true,
               agent_compaction_threshold: 0.80,
               agent_compaction_keep_recent: 6,
               agent_approval_timeout: 300_000,
               agent_subagent_timeout: 300_000,
               agent_mention_max_file_size: 262_144,
               agent_notify_debounce: 5_000,
               agent_diagnostic_feedback: true,
               agent_flush_before_shell: true,
               agent_api_base_url: "",
               agent_api_endpoints: nil,
               confirm_quit: true,
               agent_system_prompt: "",
               agent_append_system_prompt: "",
               agent_tool_permissions: nil,
               agent_diff_size_threshold: 1_048_576,
               whichkey_layout: :bottom,
               line_spacing: 1.0,
               font_family: "Menlo",
               font_size: 13,
               font_weight: :regular,
               font_ligatures: true,
               font_fallback: [],
               prettify_symbols: false,
               log_level: :info,
               log_level_render: :default,
               log_level_lsp: :default,
               log_level_agent: :default,
               log_level_editor: :default,
               cursorline: true,
               nav_flash: true,
               nav_flash_threshold: 5,
               log_level_config: :default,
               log_level_port: :default,
               parser_tree_ttl: 300,
               event_retention_days: 90,
               default_shell: :traditional
             }
    end
  end

  describe "set/3 and get/2" do
    test "set and get tab_width", %{server: s} do
      assert {:ok, 4} = Options.set(s, :tab_width, 4)
      assert Options.get(s, :tab_width) == 4
    end

    test "set and get line_numbers", %{server: s} do
      assert {:ok, :relative} = Options.set(s, :line_numbers, :relative)
      assert Options.get(s, :line_numbers) == :relative
    end

    test "set and get autopair", %{server: s} do
      assert {:ok, false} = Options.set(s, :autopair, false)
      assert Options.get(s, :autopair) == false
    end

    test "set and get scroll_margin", %{server: s} do
      assert {:ok, 10} = Options.set(s, :scroll_margin, 10)
      assert Options.get(s, :scroll_margin) == 10
    end

    test "scroll_margin accepts zero", %{server: s} do
      assert {:ok, 0} = Options.set(s, :scroll_margin, 0)
      assert Options.get(s, :scroll_margin) == 0
    end

    test "set and get startup_view", %{server: s} do
      assert Options.get(s, :startup_view) == :agent
      assert {:ok, :editor} = Options.set(s, :startup_view, :editor)
      assert Options.get(s, :startup_view) == :editor
    end

    test "set and get agent_auto_context", %{server: s} do
      assert Options.get(s, :agent_auto_context) == true
      assert {:ok, false} = Options.set(s, :agent_auto_context, false)
      assert Options.get(s, :agent_auto_context) == false
    end
  end

  describe "type validation" do
    test "tab_width rejects zero", %{server: s} do
      assert {:error, msg} = Options.set(s, :tab_width, 0)
      assert msg =~ "positive integer"
    end

    test "tab_width rejects negative", %{server: s} do
      assert {:error, _} = Options.set(s, :tab_width, -1)
    end

    test "tab_width rejects non-integer", %{server: s} do
      assert {:error, _} = Options.set(s, :tab_width, "4")
    end

    test "line_numbers rejects invalid atom", %{server: s} do
      assert {:error, msg} = Options.set(s, :line_numbers, :fancy)
      assert msg =~ "must be one of"
    end

    test "line_numbers rejects string", %{server: s} do
      assert {:error, _} = Options.set(s, :line_numbers, "hybrid")
    end

    test "autopair rejects non-boolean", %{server: s} do
      assert {:error, msg} = Options.set(s, :autopair, 1)
      assert msg =~ "boolean"
    end

    test "scroll_margin rejects negative", %{server: s} do
      assert {:error, _} = Options.set(s, :scroll_margin, -1)
    end

    test "unknown option returns error", %{server: s} do
      assert {:error, msg} = Options.set(s, :nonexistent, 42)
      assert msg =~ "unknown option"
    end

    test "font_family accepts any string", %{server: s} do
      assert {:ok, "Fira Code"} = Options.set(s, :font_family, "Fira Code")
      assert Options.get(s, :font_family) == "Fira Code"
    end

    test "font_family rejects non-string", %{server: s} do
      assert {:error, _} = Options.set(s, :font_family, :menlo)
    end

    test "font_size accepts positive integer", %{server: s} do
      assert {:ok, 16} = Options.set(s, :font_size, 16)
      assert Options.get(s, :font_size) == 16
    end

    test "font_size rejects zero", %{server: s} do
      assert {:error, _} = Options.set(s, :font_size, 0)
    end

    test "font_size rejects non-integer", %{server: s} do
      assert {:error, _} = Options.set(s, :font_size, 13.5)
    end

    test "font_weight accepts valid weight atoms", %{server: s} do
      for weight <- [:thin, :light, :regular, :medium, :semibold, :bold, :heavy, :black] do
        assert {:ok, ^weight} = Options.set(s, :font_weight, weight)
        assert Options.get(s, :font_weight) == weight
      end
    end

    test "font_weight rejects invalid atom", %{server: s} do
      assert {:error, msg} = Options.set(s, :font_weight, :extra_bold)
      assert msg =~ "must be one of"
    end

    test "font_weight rejects non-atom", %{server: s} do
      assert {:error, _} = Options.set(s, :font_weight, 5)
    end

    test "font_ligatures accepts boolean", %{server: s} do
      assert {:ok, false} = Options.set(s, :font_ligatures, false)
      assert Options.get(s, :font_ligatures) == false
    end

    test "font_ligatures rejects non-boolean", %{server: s} do
      assert {:error, _} = Options.set(s, :font_ligatures, "yes")
    end

    test "startup_view accepts :agent and :editor", %{server: s} do
      assert {:ok, :editor} = Options.set(s, :startup_view, :editor)
      assert {:ok, :agent} = Options.set(s, :startup_view, :agent)
    end

    test "startup_view rejects invalid atom", %{server: s} do
      assert {:error, msg} = Options.set(s, :startup_view, :hybrid)
      assert msg =~ "must be one of"
    end

    test "startup_view rejects non-atom", %{server: s} do
      assert {:error, _} = Options.set(s, :startup_view, "agent")
    end

    test "agent_auto_context accepts boolean", %{server: s} do
      assert {:ok, false} = Options.set(s, :agent_auto_context, false)
      assert {:ok, true} = Options.set(s, :agent_auto_context, true)
    end

    test "agent_auto_context rejects non-boolean", %{server: s} do
      assert {:error, _} = Options.set(s, :agent_auto_context, :yes)
    end
  end

  describe "reset/1" do
    test "restores all options to defaults", %{server: s} do
      Options.set(s, :tab_width, 8)
      Options.set(s, :autopair, false)
      Options.reset(s)

      assert Options.get(s, :tab_width) == 2
      assert Options.get(s, :autopair) == true
    end
  end

  describe "default/1" do
    test "returns the default for a known option" do
      assert Options.default(:tab_width) == 2
      assert Options.default(:line_numbers) == :hybrid
    end
  end

  describe "valid_names/0" do
    test "returns all option names" do
      names = Options.valid_names()
      assert :tab_width in names
      assert :line_numbers in names
      assert :autopair in names
      assert :scroll_margin in names
    end
  end

  describe "per-filetype options" do
    test "set_for_filetype overrides global for that filetype", %{server: s} do
      Options.set(s, :tab_width, 2)
      Options.set_for_filetype(s, :go, :tab_width, 8)

      assert Options.get_for_filetype(s, :tab_width, :go) == 8
      assert Options.get_for_filetype(s, :tab_width, :elixir) == 2
      assert Options.get(s, :tab_width) == 2
    end

    test "returns global value when no filetype override exists", %{server: s} do
      Options.set(s, :tab_width, 4)
      assert Options.get_for_filetype(s, :tab_width, :rust) == 4
    end

    test "returns global value when filetype is nil", %{server: s} do
      Options.set(s, :tab_width, 4)
      assert Options.get_for_filetype(s, :tab_width, nil) == 4
    end

    test "validates filetype option values", %{server: s} do
      assert {:error, _} = Options.set_for_filetype(s, :go, :tab_width, -1)
    end

    test "multiple filetypes can have different overrides", %{server: s} do
      Options.set_for_filetype(s, :go, :tab_width, 8)
      Options.set_for_filetype(s, :python, :tab_width, 4)

      assert Options.get_for_filetype(s, :tab_width, :go) == 8
      assert Options.get_for_filetype(s, :tab_width, :python) == 4
    end

    test "reset clears filetype overrides", %{server: s} do
      Options.set_for_filetype(s, :go, :tab_width, 8)
      Options.reset(s)
      assert Options.get_for_filetype(s, :tab_width, :go) == 2
    end
  end

  describe "agent_tool_approval" do
    test "defaults to :destructive", %{server: s} do
      assert Options.get(s, :agent_tool_approval) == :destructive
    end

    test "accepts :all", %{server: s} do
      assert {:ok, :all} = Options.set(s, :agent_tool_approval, :all)
      assert Options.get(s, :agent_tool_approval) == :all
    end

    test "accepts :none", %{server: s} do
      assert {:ok, :none} = Options.set(s, :agent_tool_approval, :none)
      assert Options.get(s, :agent_tool_approval) == :none
    end

    test "rejects invalid values", %{server: s} do
      assert {:error, _} = Options.set(s, :agent_tool_approval, :always)
    end
  end

  describe "agent_destructive_tools" do
    test "defaults to write_file, edit_file, shell", %{server: s} do
      assert Options.get(s, :agent_destructive_tools) == [
               "write_file",
               "edit_file",
               "multi_edit_file",
               "shell",
               "git_stage",
               "git_commit",
               "rename"
             ]
    end

    test "accepts a custom list of strings", %{server: s} do
      custom = ["shell", "write_file"]
      assert {:ok, ^custom} = Options.set(s, :agent_destructive_tools, custom)
      assert Options.get(s, :agent_destructive_tools) == custom
    end

    test "accepts an empty list", %{server: s} do
      assert {:ok, []} = Options.set(s, :agent_destructive_tools, [])
      assert Options.get(s, :agent_destructive_tools) == []
    end

    test "rejects non-list values", %{server: s} do
      assert {:error, _} = Options.set(s, :agent_destructive_tools, "shell")
    end

    test "rejects lists with non-string elements", %{server: s} do
      assert {:error, _} = Options.set(s, :agent_destructive_tools, [:shell, :write_file])
    end
  end

  describe "extension option schema" do
    @schema [
      {:conceal, :boolean, true, "Hide markup delimiters"},
      {:pretty_bullets, :boolean, true, "Replace heading stars with Unicode bullets"},
      {:heading_bullets, :string_list, ["◉", "○", "◈", "◇"], "Unicode bullets for heading levels"}
    ]

    test "registers schema and seeds defaults", %{server: s} do
      assert :ok = Options.register_extension_schema(s, :minga_org, @schema, [])
      assert Options.get_extension_option(s, :minga_org, :conceal) == true
      assert Options.get_extension_option(s, :minga_org, :pretty_bullets) == true
      assert Options.get_extension_option(s, :minga_org, :heading_bullets) == ["◉", "○", "◈", "◇"]
    end

    test "user config overrides defaults", %{server: s} do
      user_config = [conceal: false, heading_bullets: ["•", "◦"]]
      assert :ok = Options.register_extension_schema(s, :minga_org, @schema, user_config)

      assert Options.get_extension_option(s, :minga_org, :conceal) == false
      assert Options.get_extension_option(s, :minga_org, :heading_bullets) == ["•", "◦"]
      # Unset options keep their default
      assert Options.get_extension_option(s, :minga_org, :pretty_bullets) == true
    end

    test "validates user config types at registration", %{server: s} do
      assert {:error, msg} =
               Options.register_extension_schema(s, :minga_org, @schema, conceal: "yes")

      assert msg =~ "boolean"
    end

    test "unknown user config keys produce warning but succeed", %{server: s} do
      # Unknown keys are logged as warnings, not errors
      assert :ok = Options.register_extension_schema(s, :minga_org, @schema, unknown_key: true)
    end

    test "set_extension_option validates against schema", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])

      assert {:ok, false} = Options.set_extension_option(s, :minga_org, :conceal, false)
      assert Options.get_extension_option(s, :minga_org, :conceal) == false

      assert {:error, msg} = Options.set_extension_option(s, :minga_org, :conceal, "nope")
      assert msg =~ "boolean"
    end

    test "set_extension_option rejects unregistered option names", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])

      assert {:error, msg} = Options.set_extension_option(s, :minga_org, :nonexistent, true)
      assert msg =~ "unknown option"
    end

    test "supports enum type descriptor", %{server: s} do
      schema = [{:format, {:enum, [:html, :pdf, :md]}, :html, "Default export format"}]
      Options.register_extension_schema(s, :exporter, schema, [])

      assert Options.get_extension_option(s, :exporter, :format) == :html
      assert {:ok, :pdf} = Options.set_extension_option(s, :exporter, :format, :pdf)
      assert {:error, _} = Options.set_extension_option(s, :exporter, :format, :docx)
    end

    test "two extensions can have options with the same name", %{server: s} do
      schema_a = [{:conceal, :boolean, true, "Ext A conceal"}]
      schema_b = [{:conceal, :boolean, false, "Ext B conceal"}]

      Options.register_extension_schema(s, :ext_a, schema_a, [])
      Options.register_extension_schema(s, :ext_b, schema_b, [])

      assert Options.get_extension_option(s, :ext_a, :conceal) == true
      assert Options.get_extension_option(s, :ext_b, :conceal) == false

      Options.set_extension_option(s, :ext_a, :conceal, false)
      # ext_b is unaffected
      assert Options.get_extension_option(s, :ext_b, :conceal) == false
    end

    test "per-filetype overrides work for extension options", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])

      # Global default is true
      assert Options.get_extension_option_for_filetype(s, :minga_org, :conceal, :org) == true

      # Set a filetype-specific override
      assert {:ok, false} =
               Options.set_extension_option_for_filetype(s, :minga_org, :org, :conceal, false)

      # Filetype lookup returns the override
      assert Options.get_extension_option_for_filetype(s, :minga_org, :conceal, :org) == false

      # Global value is unchanged
      assert Options.get_extension_option(s, :minga_org, :conceal) == true

      # Different filetype falls back to global
      assert Options.get_extension_option_for_filetype(s, :minga_org, :conceal, :markdown) == true
    end

    test "set_extension_option_for_filetype validates against schema", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])

      assert {:error, msg} =
               Options.set_extension_option_for_filetype(s, :minga_org, :org, :conceal, "nope")

      assert msg =~ "boolean"
    end

    test "get_extension_option_for_filetype falls back to global when no override", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, conceal: false)

      assert Options.get_extension_option_for_filetype(s, :minga_org, :conceal, :org) == false
    end

    test "get_extension_option_for_filetype with nil filetype returns global", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])

      assert Options.get_extension_option_for_filetype(s, :minga_org, :conceal, nil) == true
    end

    test "extension_schema returns the registered schema", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])
      assert Options.extension_schema(s, :minga_org) == @schema
    end

    test "extension_schema returns nil for unknown extension", %{server: s} do
      assert Options.extension_schema(s, :unknown) == nil
    end

    test "extension_option_description returns the description string", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])

      assert Options.extension_option_description(s, :minga_org, :conceal) ==
               "Hide markup delimiters"

      assert Options.extension_option_description(s, :minga_org, :pretty_bullets) ==
               "Replace heading stars with Unicode bullets"
    end

    test "extension_option_description returns nil for unknown option", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])
      assert Options.extension_option_description(s, :minga_org, :nonexistent) == nil
    end

    test "extension_option_description returns nil for unknown extension", %{server: s} do
      assert Options.extension_option_description(s, :unknown, :conceal) == nil
    end

    test "re-registration does not overwrite user-set values", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])
      Options.set_extension_option(s, :minga_org, :conceal, false)

      # Re-register (simulates config reload)
      Options.register_extension_schema(s, :minga_org, @schema, [])
      assert Options.get_extension_option(s, :minga_org, :conceal) == false
    end

    test "reset clears extension schemas and values", %{server: s} do
      Options.register_extension_schema(s, :minga_org, @schema, [])
      Options.reset(s)

      assert Options.extension_schema(s, :minga_org) == nil
      assert Options.get_extension_option(s, :minga_org, :conceal) == nil
    end
  end

  describe "type_for/1" do
    test "returns type descriptor for known options" do
      assert Options.type_for(:tab_width) == :pos_integer
      assert Options.type_for(:autopair) == :boolean
      assert Options.type_for(:line_numbers) == {:enum, [:hybrid, :absolute, :relative, :none]}
      assert Options.type_for(:theme) == :theme_atom
      assert Options.type_for(:font_family) == :string
    end

    test "returns nil for unknown options" do
      assert Options.type_for(:nonexistent) == nil
    end
  end

  describe "option_specs/0" do
    test "returns a list of {name, type, default} tuples" do
      specs = Options.option_specs()

      assert is_list(specs)
      assert length(specs) == length(Options.valid_names())

      for {name, _type, _default} <- specs do
        assert is_atom(name)
        assert name in Options.valid_names()
      end
    end

    test "specs match valid_names and defaults" do
      specs = Options.option_specs()

      for {name, _type, default} <- specs do
        assert Options.default(name) == default
      end
    end
  end
end
