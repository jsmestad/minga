defmodule Minga.Command.RegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Command
  alias Minga.Command.Registry

  # Each test gets its own named registry to avoid cross-test pollution.
  setup do
    name = :"registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: name)
    {:ok, registry: name}
  end

  describe "built-in commands" do
    test "all built-in commands are registered on start", %{registry: r} do
      names = r |> Registry.all() |> Enum.map(& &1.name) |> Enum.sort()

      # Core commands that must always be present (not exhaustive, but covers
      # all major categories). New commands are expected to be added over time.
      required_commands =
        [
          # Buffer management
          :save,
          :quit,
          :force_quit,
          :quit_all,
          :force_quit_all,
          :buffer_list,
          :buffer_list_all,
          :buffer_next,
          :buffer_prev,
          :kill_buffer,
          :new_buffer,
          :view_messages,
          :view_warnings,
          :open_config,
          :reload_config,

          # Movement
          :move_left,
          :move_right,
          :move_up,
          :move_down,
          :half_page_down,
          :half_page_up,
          :page_down,
          :page_up,

          # Editing
          :delete_before,
          :delete_at,
          :delete_chars_at,
          :delete_chars_before,
          :insert_newline,
          :undo,
          :redo,
          :paste_after,
          :paste_before,
          :delete_line,
          :yank_line,

          # Search & UI
          :command_palette,
          :find_file,
          :search_project,
          :theme_picker,
          :set_language,
          :diagnostics_list,
          :filetype_menu,

          # Tabs
          :tab_next,
          :tab_prev,
          :tab_goto_1,
          :tab_goto_2,
          :tab_goto_3,
          :tab_goto_4,
          :tab_goto_5,
          :tab_goto_6,
          :tab_goto_7,
          :tab_goto_8,
          :tab_goto_9,

          # LSP
          :lsp_info,
          :lsp_restart,
          :lsp_start,
          :lsp_stop,
          :goto_definition,
          :hover,

          # Git
          :next_git_hunk,
          :prev_git_hunk,
          :git_stage_hunk,
          :git_revert_hunk,
          :git_preview_hunk,
          :git_blame_line,

          # Folding
          :fold_toggle,
          :fold_close,
          :fold_open,
          :fold_close_all,
          :fold_open_all,

          # Agent
          :toggle_agent_panel,
          :toggle_agentic_view,
          :cycle_agent_tabs,
          :agent_abort,
          :agent_new_session,
          :agent_pick_model,
          :agent_cycle_model,
          :agent_summarize,
          :agent_cycle_thinking,

          # Line display
          :cycle_line_numbers,
          :toggle_wrap,
          :toggle_comment_line,
          :toggle_comment_selection,

          # Format & alternate
          :format_buffer,
          :alternate_file,

          # Diagnostics
          :next_diagnostic,
          :prev_diagnostic,

          # Tests
          :test_file,
          :test_all,
          :test_at_point,
          :test_rerun,
          :test_output
        ]
        |> Enum.sort()

      for cmd <- required_commands do
        assert cmd in names, "Expected command #{cmd} to be registered"
      end

      # Verify we have at least as many commands as the required set
      assert length(names) >= length(required_commands)
    end

    test "looking up :save returns the built-in save command", %{registry: r} do
      assert {:ok, %Command{name: :save, description: desc}} = Registry.lookup(r, :save)
      assert is_binary(desc) and byte_size(desc) > 0
    end

    test "all built-in commands have non-empty descriptions", %{registry: r} do
      for cmd <- Registry.all(r) do
        assert is_binary(cmd.description) and byte_size(cmd.description) > 0,
               "Command #{cmd.name} has an empty description"
      end
    end

    test "all built-in commands have callable execute functions", %{registry: r} do
      for cmd <- Registry.all(r) do
        assert is_function(cmd.execute),
               "Command #{cmd.name} has a non-function execute field"
      end
    end

    test "requires_buffer is set correctly for buffer-dependent commands", %{registry: r} do
      # Commands that need a buffer
      for name <- [:save, :move_left, :delete_before, :undo] do
        {:ok, cmd} = Registry.lookup(r, name)

        assert cmd.requires_buffer,
               "Expected #{name} to require a buffer"
      end

      # Commands that work without a buffer
      for name <- [:command_palette, :find_file, :toggle_agent_panel, :new_buffer] do
        {:ok, cmd} = Registry.lookup(r, name)

        refute cmd.requires_buffer,
               "Expected #{name} to NOT require a buffer"
      end
    end
  end

  describe "register/4" do
    test "registers a new custom command", %{registry: r} do
      noop = fn state -> state end
      :ok = Registry.register(r, :my_cmd, "Do something", noop)

      assert {:ok, %Command{name: :my_cmd, description: "Do something", execute: ^noop}} =
               Registry.lookup(r, :my_cmd)
    end

    test "overwriting an existing command replaces it", %{registry: r} do
      first = fn state -> Map.put(state, :first, true) end
      second = fn state -> Map.put(state, :second, true) end

      :ok = Registry.register(r, :save, "First save", first)
      :ok = Registry.register(r, :save, "Second save", second)

      assert {:ok, %Command{description: "Second save", execute: ^second}} =
               Registry.lookup(r, :save)
    end

    test "registered command appears in all/1", %{registry: r} do
      :ok = Registry.register(r, :unique_cmd, "Unique", fn s -> s end)
      names = r |> Registry.all() |> Enum.map(& &1.name)
      assert :unique_cmd in names
    end

    test "registering multiple distinct commands keeps all of them", %{registry: r} do
      :ok = Registry.register(r, :alpha, "Alpha", fn s -> s end)
      :ok = Registry.register(r, :beta, "Beta", fn s -> s end)

      assert {:ok, %Command{name: :alpha}} = Registry.lookup(r, :alpha)
      assert {:ok, %Command{name: :beta}} = Registry.lookup(r, :beta)
    end
  end

  describe "lookup/2" do
    test "returns :error for unknown command names", %{registry: r} do
      assert :error = Registry.lookup(r, :definitely_not_registered)
    end

    test "lookup is case-sensitive — :Save differs from :save", %{registry: r} do
      assert :error = Registry.lookup(r, :Save)
      assert {:ok, _} = Registry.lookup(r, :save)
    end
  end

  describe "all/1" do
    test "returns a list of Command structs", %{registry: r} do
      cmds = Registry.all(r)
      assert is_list(cmds)
      for cmd <- cmds, do: assert(%Command{} = cmd)
    end

    test "count grows when a new command is registered", %{registry: r} do
      before_count = length(Registry.all(r))
      :ok = Registry.register(r, :extra, "Extra", fn s -> s end)
      assert length(Registry.all(r)) == before_count + 1
    end

    test "count stays the same when an existing command is overwritten", %{registry: r} do
      before_count = length(Registry.all(r))
      :ok = Registry.register(r, :save, "New save description", fn s -> s end)
      assert length(Registry.all(r)) == before_count
    end
  end

  describe "reset/1" do
    test "removes user commands and restores built-ins", %{registry: r} do
      :ok = Registry.register(r, :custom_cmd, "Custom", fn s -> s end)
      assert {:ok, _} = Registry.lookup(r, :custom_cmd)

      :ok = Registry.reset(r)

      assert :error = Registry.lookup(r, :custom_cmd)
      assert {:ok, %Command{name: :save}} = Registry.lookup(r, :save)
    end

    test "restores overwritten built-in descriptions", %{registry: r} do
      :ok = Registry.register(r, :save, "Overridden save", fn s -> s end)
      :ok = Registry.reset(r)

      {:ok, cmd} = Registry.lookup(r, :save)
      assert cmd.description == "Save the current file"
    end

    test "count returns to built-in count after reset", %{registry: r} do
      built_in_count = length(Registry.all(r))
      :ok = Registry.register(r, :extra1, "E1", fn s -> s end)
      :ok = Registry.register(r, :extra2, "E2", fn s -> s end)
      assert length(Registry.all(r)) == built_in_count + 2

      :ok = Registry.reset(r)
      assert length(Registry.all(r)) == built_in_count
    end
  end

  describe "execute function" do
    test "user-registered execute functions work correctly", %{registry: r} do
      :ok = Registry.register(r, :my_cmd, "Test", fn state -> Map.put(state, :ran, true) end)
      {:ok, cmd} = Registry.lookup(r, :my_cmd)
      result = cmd.execute.(%{})
      assert result == %{ran: true}
    end
  end
end
