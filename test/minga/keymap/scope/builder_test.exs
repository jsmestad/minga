defmodule Minga.Keymap.Scope.BuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Scope.Builder

  describe "build_trie/1" do
    test "empty options returns empty trie" do
      trie = Builder.build_trie([])
      assert :not_found = Bindings.lookup(trie, {?j, 0})
    end

    test "merges a single group" do
      trie = Builder.build_trie(groups: [:cua_navigation])

      # Kitty protocol up arrow
      assert {:command, :move_up} = Bindings.lookup(trie, {57_352, 0})
      # macOS up arrow
      assert {:command, :move_up} = Bindings.lookup(trie, {0xF700, 0})
    end

    test "merges multiple groups" do
      trie = Builder.build_trie(groups: [:cua_navigation, :ctrl_agent_common])

      # From cua_navigation
      assert {:command, :move_up} = Bindings.lookup(trie, {57_352, 0})
      # From ctrl_agent_common
      assert {:command, :agent_ctrl_c} = Bindings.lookup(trie, {?c, 0x02})
    end

    test "global exclude removes commands from all groups" do
      trie = Builder.build_trie(groups: [:cua_navigation], exclude: [:move_up])

      # move_up excluded (both encodings)
      assert :not_found = Bindings.lookup(trie, {57_352, 0})
      assert :not_found = Bindings.lookup(trie, {0xF700, 0})
      # move_down still present
      assert {:command, :move_down} = Bindings.lookup(trie, {57_353, 0})
    end

    test "per-group exclude removes commands from that group only" do
      trie =
        Builder.build_trie(
          groups: [
            {:cua_navigation, exclude: [:half_page_up, :half_page_down]},
            :ctrl_agent_common
          ]
        )

      # half_page_up excluded from cua_navigation
      assert :not_found = Bindings.lookup(trie, {57_352, 0x01})
      # move_up still present
      assert {:command, :move_up} = Bindings.lookup(trie, {57_352, 0})
      # ctrl_agent_common unaffected
      assert {:command, :agent_ctrl_c} = Bindings.lookup(trie, {?c, 0x02})
    end

    test "then function applies scope-specific bindings on top" do
      trie =
        Builder.build_trie(
          groups: [:ctrl_agent_common],
          then: fn t ->
            t
            |> Bindings.bind([{?q, 0}], :my_close, "Close")
          end
        )

      # Group binding present
      assert {:command, :agent_ctrl_c} = Bindings.lookup(trie, {?c, 0x02})
      # Scope binding present
      assert {:command, :my_close} = Bindings.lookup(trie, {?q, 0})
    end

    test "then function overrides group bindings on conflict" do
      trie =
        Builder.build_trie(
          groups: [:ctrl_agent_common],
          then: fn t ->
            # Override Ctrl+C from group with a different command
            Bindings.bind(t, [{?c, 0x02}], :my_abort, "My abort")
          end
        )

      assert {:command, :my_abort} = Bindings.lookup(trie, {?c, 0x02})
    end
  end

  describe "groups_to_trie/1" do
    test "shorthand for build_trie with groups only" do
      trie = Builder.groups_to_trie([:cua_navigation])
      assert {:command, :move_up} = Bindings.lookup(trie, {57_352, 0})
    end
  end

  describe "group_names_from/1" do
    test "extracts names from mixed spec list" do
      specs = [:cua_navigation, {:cua_cmd_chords, exclude: [:undo]}, :ctrl_agent_common]

      assert [:cua_navigation, :cua_cmd_chords, :ctrl_agent_common] =
               Builder.group_names_from(specs)
    end

    test "handles empty list" do
      assert [] = Builder.group_names_from([])
    end
  end

  describe "validate_groups!/1" do
    test "returns :ok for known groups" do
      assert :ok = Builder.validate_groups!([:cua_navigation, :ctrl_agent_common])
    end

    test "raises for unknown groups" do
      assert_raise ArgumentError, ~r/unknown shared groups/, fn ->
        Builder.validate_groups!([:cua_navigation, :nonexistent_group])
      end
    end
  end

  describe "Builder macro generates behaviour callbacks" do
    # Define a test scope module using the Builder
    defmodule TestScope do
      use Minga.Keymap.Scope.Builder,
        name: :test_scope,
        display_name: "Test Scope"

      alias Minga.Keymap.Bindings

      @impl true
      def keymap(:normal, _context) do
        build_trie(
          groups: [:cua_navigation],
          then: fn trie ->
            Bindings.bind(trie, [{?x, 0}], :test_action, "Test action")
          end
        )
      end

      def keymap(_state, _context), do: Bindings.new()

      @impl true
      def shared_keymap, do: Bindings.new()

      @impl true
      def help_groups(_focus), do: []

      @impl true
      def included_groups, do: [:cua_navigation]
    end

    test "name/0 returns configured name" do
      assert :test_scope = TestScope.name()
    end

    test "display_name/0 returns configured display name" do
      assert "Test Scope" = TestScope.display_name()
    end

    test "on_enter/1 passes state through" do
      assert :my_state = TestScope.on_enter(:my_state)
    end

    test "on_exit/1 passes state through" do
      assert :my_state = TestScope.on_exit(:my_state)
    end

    test "keymap/2 returns trie with group + scope bindings" do
      trie = TestScope.keymap(:normal, [])

      # From group
      assert {:command, :move_up} = Bindings.lookup(trie, {57_352, 0})
      # Scope-specific
      assert {:command, :test_action} = Bindings.lookup(trie, {?x, 0})
    end

    test "keymap/2 returns empty trie for unconfigured vim states" do
      trie = TestScope.keymap(:insert, [])
      assert :not_found = Bindings.lookup(trie, {?x, 0})
    end
  end

  describe "Builder with overridable on_enter/on_exit" do
    defmodule CustomLifecycleScope do
      use Minga.Keymap.Scope.Builder,
        name: :custom,
        display_name: "Custom"

      alias Minga.Keymap.Bindings

      @impl true
      def on_enter(state), do: Map.put(state, :entered, true)

      @impl true
      def on_exit(state), do: Map.put(state, :exited, true)

      @impl true
      def keymap(_state, _context), do: Bindings.new()

      @impl true
      def shared_keymap, do: Bindings.new()

      @impl true
      def help_groups(_focus), do: []

      @impl true
      def included_groups, do: []
    end

    test "custom on_enter/1 is used" do
      assert %{entered: true} = CustomLifecycleScope.on_enter(%{})
    end

    test "custom on_exit/1 is used" do
      assert %{exited: true} = CustomLifecycleScope.on_exit(%{})
    end
  end
end
