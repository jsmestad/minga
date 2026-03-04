defmodule Minga.Keymap.StoreTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Store
  alias Minga.Keymap.Trie

  setup do
    {:ok, pid} = Store.start_link(name: :"store_#{System.unique_integer([:positive])}")
    %{store: pid}
  end

  describe "leader_trie/1" do
    test "returns defaults on startup", %{store: s} do
      trie = Store.leader_trie(s)
      # SPC f f should resolve to :find_file
      {:prefix, f_node} = Trie.lookup(trie, {?f, 0})
      assert {:command, :find_file} = Trie.lookup(f_node, {?f, 0})
    end
  end

  describe "normal_bindings/1" do
    test "returns defaults when no overrides", %{store: s} do
      bindings = Store.normal_bindings(s)
      assert {_cmd, _desc} = bindings[{?h, 0}]
    end
  end

  describe "bind/5 leader sequences" do
    test "adds a new leader binding", %{store: s} do
      assert :ok = Store.bind(s, :normal, "SPC g s", :git_status, "Git status")

      trie = Store.leader_trie(s)
      {:prefix, g_node} = Trie.lookup(trie, {?g, 0})
      assert {:command, :git_status} = Trie.lookup(g_node, {?s, 0})
    end

    test "overrides an existing leader binding", %{store: s} do
      # SPC f f is :find_file by default
      Store.bind(s, :normal, "SPC f f", :my_finder, "My finder")

      trie = Store.leader_trie(s)
      {:prefix, f_node} = Trie.lookup(trie, {?f, 0})
      assert {:command, :my_finder} = Trie.lookup(f_node, {?f, 0})
    end

    test "default bindings still work after adding new ones", %{store: s} do
      Store.bind(s, :normal, "SPC g s", :git_status, "Git status")

      trie = Store.leader_trie(s)
      {:prefix, f_node} = Trie.lookup(trie, {?f, 0})
      assert {:command, :find_file} = Trie.lookup(f_node, {?f, 0})
    end
  end

  describe "bind/5 single-key normal bindings" do
    test "adds a normal-mode key override", %{store: s} do
      Store.bind(s, :normal, "Q", :replay_macro_q, "Replay macro q")

      bindings = Store.normal_bindings(s)
      assert {:replay_macro_q, "Replay macro q"} = bindings[{?Q, 0}]
    end

    test "overrides default normal binding", %{store: s} do
      Store.bind(s, :normal, "j", :custom_down, "Custom down")

      bindings = Store.normal_bindings(s)
      assert {:custom_down, "Custom down"} = bindings[{?j, 0}]
    end
  end

  describe "bind/5 error handling" do
    test "returns error for invalid key string", %{store: s} do
      assert {:error, _} = Store.bind(s, :normal, "", :noop, "noop")
    end

    test "returns error for unsupported mode", %{store: s} do
      assert {:error, _} = Store.bind(s, :visual, "SPC g s", :noop, "noop")
    end
  end

  describe "reset/1" do
    test "removes all user overrides", %{store: s} do
      Store.bind(s, :normal, "SPC g s", :git_status, "Git status")
      Store.bind(s, :normal, "Q", :replay, "Replay")
      Store.reset(s)

      trie = Store.leader_trie(s)
      # SPC g should not have s anymore (unless it's in defaults)
      case Trie.lookup(trie, {?g, 0}) do
        {:prefix, g_node} ->
          assert :not_found = Trie.lookup(g_node, {?s, 0})

        :not_found ->
          assert true
      end

      assert Store.normal_overrides(s) == %{}
    end
  end
end
