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

      expected =
        [
          :save,
          :quit,
          :force_quit,
          :quit_all,
          :force_quit_all,
          :move_left,
          :move_right,
          :move_up,
          :move_down,
          :delete_before,
          :delete_at,
          :delete_chars_at,
          :delete_chars_before,
          :insert_newline,
          :undo,
          :redo,
          :find_file,
          :search_project,
          :buffer_list,
          :buffer_list_all,
          :buffer_next,
          :buffer_prev,
          :kill_buffer,
          :cycle_agent_tabs,
          :command_palette,
          :delete_line,
          :yank_line,
          :paste_after,
          :paste_before,
          :half_page_down,
          :half_page_up,
          :page_down,
          :page_up,
          :cycle_line_numbers,
          :view_messages,
          :view_warnings,
          :new_buffer,
          :diagnostics_list,
          :next_diagnostic,
          :prev_diagnostic,
          :prev_git_hunk,
          :lsp_info,
          :open_config,
          :reload_config,
          :format_buffer,
          :agent_abort,
          :agent_new_session,
          :agent_pick_model,
          :agent_cycle_model,
          :agent_cycle_thinking,
          :agent_summarize,
          :git_blame_line,
          :git_preview_hunk,
          :git_revert_hunk,
          :git_stage_hunk,
          :goto_definition,
          :hover,
          :next_git_hunk,
          :theme_picker,
          :toggle_agent_panel,
          :toggle_agentic_view,
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
          :toggle_comment_line,
          :toggle_comment_selection,
          :toggle_wrap,
          :fold_toggle,
          :fold_close,
          :fold_open,
          :fold_close_all,
          :fold_open_all,
          :alternate_file
        ]
        |> Enum.sort()

      assert names == expected
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
    test "built-in execute functions accept and return a map state", %{registry: r} do
      {:ok, cmd} = Registry.lookup(r, :move_left)
      state = %{}
      result = cmd.execute.(state)
      assert is_map(result)
    end
  end
end
