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
          :move_left,
          :move_right,
          :move_up,
          :move_down,
          :delete_before,
          :delete_at,
          :insert_newline,
          :undo,
          :redo,
          :find_file,
          :search_project,
          :buffer_list,
          :buffer_next,
          :buffer_prev,
          :kill_buffer,
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
          :view_scratch,
          :new_buffer,
          :diagnostics_list,
          :next_diagnostic,
          :prev_diagnostic,
          :lsp_info,
          :open_config,
          :theme_picker
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

  describe "execute function" do
    test "built-in execute functions accept and return a map state", %{registry: r} do
      {:ok, cmd} = Registry.lookup(r, :move_left)
      state = %{}
      result = cmd.execute.(state)
      assert is_map(result)
    end
  end
end
