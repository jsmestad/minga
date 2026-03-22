defmodule Minga.Keymap.ActiveTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Active
  alias Minga.Keymap.Bindings

  setup do
    {:ok, pid} = Active.start_link(name: :"store_#{System.unique_integer([:positive])}")
    %{store: pid}
  end

  describe "leader_trie/1" do
    test "returns defaults on startup", %{store: s} do
      trie = Active.leader_trie(s)
      # SPC f f should resolve to :find_file
      {:prefix, f_node} = Bindings.lookup(trie, {?f, 0})
      assert {:command, :find_file} = Bindings.lookup(f_node, {?f, 0})
    end

    test "has SPC m prefix for filetype bindings", %{store: s} do
      trie = Active.leader_trie(s)
      # SPC m should be a prefix node (registered by defaults)
      assert {:prefix, _m_node} = Bindings.lookup(trie, {?m, 0})
    end
  end

  describe "normal_bindings/1" do
    test "returns defaults when no overrides", %{store: s} do
      bindings = Active.normal_bindings(s)
      assert {_cmd, _desc} = bindings[{?h, 0}]
    end
  end

  describe "bind/5 leader sequences" do
    test "adds a new leader binding", %{store: s} do
      assert :ok = Active.bind(s, :normal, "SPC g s", :git_status, "Git status")

      trie = Active.leader_trie(s)
      {:prefix, g_node} = Bindings.lookup(trie, {?g, 0})
      assert {:command, :git_status} = Bindings.lookup(g_node, {?s, 0})
    end

    test "overrides an existing leader binding", %{store: s} do
      # SPC f f is :find_file by default
      Active.bind(s, :normal, "SPC f f", :my_finder, "My finder")

      trie = Active.leader_trie(s)
      {:prefix, f_node} = Bindings.lookup(trie, {?f, 0})
      assert {:command, :my_finder} = Bindings.lookup(f_node, {?f, 0})
    end

    test "default bindings still work after adding new ones", %{store: s} do
      Active.bind(s, :normal, "SPC g s", :git_status, "Git status")

      trie = Active.leader_trie(s)
      {:prefix, f_node} = Bindings.lookup(trie, {?f, 0})
      assert {:command, :find_file} = Bindings.lookup(f_node, {?f, 0})
    end
  end

  describe "bind/5 single-key normal bindings" do
    test "adds a normal-mode key override", %{store: s} do
      Active.bind(s, :normal, "Q", :replay_macro_q, "Replay macro q")

      bindings = Active.normal_bindings(s)
      assert {:replay_macro_q, "Replay macro q"} = bindings[{?Q, 0}]
    end

    test "overrides default normal binding", %{store: s} do
      Active.bind(s, :normal, "j", :custom_down, "Custom down")

      bindings = Active.normal_bindings(s)
      assert {:custom_down, "Custom down"} = bindings[{?j, 0}]
    end
  end

  describe "bind/5 insert mode" do
    test "adds an insert-mode binding", %{store: s} do
      assert :ok = Active.bind(s, :insert, "C-j", :next_line, "Next line")

      trie = Active.mode_trie(s, :insert)
      assert {:command, :next_line} = Bindings.lookup(trie, {?j, 0x02})
    end

    test "multiple insert bindings coexist", %{store: s} do
      Active.bind(s, :insert, "C-j", :next_line, "Next line")
      Active.bind(s, :insert, "C-k", :prev_line, "Prev line")

      trie = Active.mode_trie(s, :insert)
      assert {:command, :next_line} = Bindings.lookup(trie, {?j, 0x02})
      assert {:command, :prev_line} = Bindings.lookup(trie, {?k, 0x02})
    end
  end

  describe "bind/5 visual mode" do
    test "adds a visual-mode binding", %{store: s} do
      assert :ok = Active.bind(s, :visual, "C-x", :custom_cut, "Custom cut")

      trie = Active.mode_trie(s, :visual)
      assert {:command, :custom_cut} = Bindings.lookup(trie, {?x, 0x02})
    end
  end

  describe "bind/5 operator_pending mode" do
    test "adds an operator-pending binding", %{store: s} do
      assert :ok =
               Active.bind(
                 s,
                 :operator_pending,
                 "C-a",
                 :select_all,
                 "Select all"
               )

      trie = Active.mode_trie(s, :operator_pending)
      assert {:command, :select_all} = Bindings.lookup(trie, {?a, 0x02})
    end
  end

  describe "bind/5 command mode" do
    test "adds a command-mode binding", %{store: s} do
      assert :ok = Active.bind(s, :command, "C-p", :history_prev, "History prev")

      trie = Active.mode_trie(s, :command)
      assert {:command, :history_prev} = Bindings.lookup(trie, {?p, 0x02})
    end
  end

  describe "bind/5 error handling" do
    test "returns error for invalid key string", %{store: s} do
      assert {:error, _} = Active.bind(s, :normal, "", :noop, "noop")
    end

    test "returns error for unsupported mode atom", %{store: s} do
      assert {:error, _} = Active.bind(s, :bogus, "j", :noop, "noop")
    end
  end

  describe "bind/6 with filetype option" do
    test "stores filetype-scoped binding under SPC m", %{store: s} do
      assert :ok =
               Active.bind(
                 s,
                 :normal,
                 "SPC m t",
                 :mix_test,
                 "Run tests",
                 filetype: :elixir
               )

      trie = Active.filetype_trie(s, :elixir)
      assert {:command, :mix_test} = Bindings.lookup(trie, {?t, 0})
    end

    test "strips SPC m prefix from stored key sequence", %{store: s} do
      Active.bind(s, :normal, "SPC m f", :mix_format, "Format", filetype: :elixir)

      trie = Active.filetype_trie(s, :elixir)
      # Should be stored as just "f", not "SPC m f"
      assert {:command, :mix_format} = Bindings.lookup(trie, {?f, 0})
    end

    test "different filetypes have independent tries", %{store: s} do
      Active.bind(s, :normal, "SPC m t", :mix_test, "Test", filetype: :elixir)
      Active.bind(s, :normal, "SPC m t", :go_test, "Test", filetype: :go)

      elixir_trie = Active.filetype_trie(s, :elixir)
      go_trie = Active.filetype_trie(s, :go)

      assert {:command, :mix_test} = Bindings.lookup(elixir_trie, {?t, 0})
      assert {:command, :go_test} = Bindings.lookup(go_trie, {?t, 0})
    end

    test "filetype trie is empty for unregistered filetypes", %{store: s} do
      trie = Active.filetype_trie(s, :rust)
      assert :not_found = Bindings.lookup(trie, {?t, 0})
    end

    test "multiple keys under same filetype", %{store: s} do
      Active.bind(s, :normal, "SPC m t", :mix_test, "Test", filetype: :elixir)
      Active.bind(s, :normal, "SPC m f", :mix_format, "Format", filetype: :elixir)
      Active.bind(s, :normal, "SPC m r", :iex_run, "Run in IEx", filetype: :elixir)

      trie = Active.filetype_trie(s, :elixir)
      assert {:command, :mix_test} = Bindings.lookup(trie, {?t, 0})
      assert {:command, :mix_format} = Bindings.lookup(trie, {?f, 0})
      assert {:command, :iex_run} = Bindings.lookup(trie, {?r, 0})
    end

    test "filetype binding without SPC m prefix stores as-is", %{store: s} do
      # If someone writes bind :normal, "t", :test, "Test", filetype: :elixir
      # the key is stored as-is (no stripping needed)
      Active.bind(s, :normal, "t", :test, "Test", filetype: :elixir)

      trie = Active.filetype_trie(s, :elixir)
      assert {:command, :test} = Bindings.lookup(trie, {?t, 0})
    end
  end

  describe "bind/6 filetype-scoped insert mode" do
    test "stores insert-mode binding scoped to filetype", %{store: s} do
      assert :ok =
               Active.bind(s, :insert, "TAB", :org_table_align, "Align table", filetype: :org)

      trie = Active.filetype_mode_trie(s, :org, :insert)
      assert {:command, :org_table_align} = Bindings.lookup(trie, {9, 0})
    end

    test "filetype insert binding does not appear in global insert trie", %{store: s} do
      Active.bind(s, :insert, "TAB", :org_table_align, "Align table", filetype: :org)

      global_trie = Active.mode_trie(s, :insert)
      assert :not_found = Bindings.lookup(global_trie, {9, 0})
    end

    test "filetype insert binding does not appear in normal filetype trie", %{store: s} do
      Active.bind(s, :insert, "TAB", :org_table_align, "Align table", filetype: :org)

      normal_trie = Active.filetype_trie(s, :org)
      assert :not_found = Bindings.lookup(normal_trie, {9, 0})
    end

    test "different filetypes have independent insert tries", %{store: s} do
      Active.bind(s, :insert, "TAB", :org_table_align, "Align table", filetype: :org)
      Active.bind(s, :insert, "TAB", :md_indent, "Indent list", filetype: :markdown)

      org_trie = Active.filetype_mode_trie(s, :org, :insert)
      md_trie = Active.filetype_mode_trie(s, :markdown, :insert)

      assert {:command, :org_table_align} = Bindings.lookup(org_trie, {9, 0})
      assert {:command, :md_indent} = Bindings.lookup(md_trie, {9, 0})
    end

    test "filetype mode trie is empty for unregistered combinations", %{store: s} do
      trie = Active.filetype_mode_trie(s, :rust, :insert)
      assert :not_found = Bindings.lookup(trie, {9, 0})
    end
  end

  describe "bind/6 filetype-scoped visual mode" do
    test "stores visual-mode binding scoped to filetype", %{store: s} do
      Active.bind(s, :visual, "S", :org_surround, "Surround", filetype: :org)

      trie = Active.filetype_mode_trie(s, :org, :visual)
      assert {:command, :org_surround} = Bindings.lookup(trie, {?S, 0})
    end
  end

  describe "bind/6 filetype-scoped unsupported modes" do
    test "operator_pending filetype binding returns error", %{store: s} do
      assert {:error, msg} =
               Active.bind(s, :operator_pending, "x", :cmd, "Cmd", filetype: :org)

      assert msg =~ "not supported"
    end

    test "command mode filetype binding returns error", %{store: s} do
      assert {:error, msg} =
               Active.bind(s, :command, "x", :cmd, "Cmd", filetype: :org)

      assert msg =~ "not supported"
    end
  end

  describe "resolve_mode_binding/4" do
    test "filetype binding takes priority over global", %{store: s} do
      Active.bind(s, :insert, "TAB", :global_tab, "Global TAB")
      Active.bind(s, :insert, "TAB", :org_table_align, "Align table", filetype: :org)

      assert {:command, :org_table_align} =
               Active.resolve_mode_binding(s, :insert, :org, {9, 0})
    end

    test "falls back to global when no filetype binding exists", %{store: s} do
      Active.bind(s, :insert, "TAB", :global_tab, "Global TAB")

      assert {:command, :global_tab} = Active.resolve_mode_binding(s, :insert, :org, {9, 0})
    end

    test "falls back to global when filetype is nil", %{store: s} do
      Active.bind(s, :insert, "TAB", :global_tab, "Global TAB")

      assert {:command, :global_tab} = Active.resolve_mode_binding(s, :insert, nil, {9, 0})
    end

    test "returns :not_found when no binding exists anywhere", %{store: s} do
      assert :not_found = Active.resolve_mode_binding(s, :insert, :org, {9, 0})
    end

    test "filetype binding for one filetype does not affect another", %{store: s} do
      Active.bind(s, :insert, "TAB", :org_table_align, "Align table", filetype: :org)

      assert :not_found = Active.resolve_mode_binding(s, :insert, :markdown, {9, 0})
    end
  end

  describe "resolve_mode_binding/4 — prefix edge case" do
    test "prefix match in filetype trie falls through to global command", %{store: s} do
      # Filetype trie has C-j as a prefix (part of a multi-key sequence)
      Active.bind(s, :insert, "C-j C-k", :org_thing, "Org thing", filetype: :org)
      # Global trie has C-j as a direct command
      Active.bind(s, :insert, "C-j", :global_next, "Global next")

      # The filetype trie returns {:prefix, _} for C-j, not {:command, _}.
      # resolve_mode_binding should fall through to the global command.
      assert {:command, :global_next} =
               Active.resolve_mode_binding(s, :insert, :org, {?j, 0x02})
    end
  end

  describe "reset/1 — filetype mode tries" do
    test "reset clears filetype mode tries", %{store: s} do
      Active.bind(s, :insert, "TAB", :org_align, "Align", filetype: :org)
      Active.reset(s)

      trie = Active.filetype_mode_trie(s, :org, :insert)
      assert :not_found = Bindings.lookup(trie, {9, 0})
    end
  end

  describe "bind/5 scope overrides" do
    test "adds scope-specific binding", %{store: s} do
      Active.bind(s, {:agent, :normal}, "y", :agent_copy, "Agent copy")

      trie = Active.scope_trie(s, :agent, :normal)
      assert {:command, :agent_copy} = Bindings.lookup(trie, {?y, 0})
    end

    test "different scopes have independent tries", %{store: s} do
      Active.bind(s, {:agent, :normal}, "y", :agent_copy, "Agent copy")
      Active.bind(s, {:file_tree, :normal}, "y", :tree_copy, "Tree copy")

      agent_trie = Active.scope_trie(s, :agent, :normal)
      tree_trie = Active.scope_trie(s, :file_tree, :normal)

      assert {:command, :agent_copy} = Bindings.lookup(agent_trie, {?y, 0})
      assert {:command, :tree_copy} = Bindings.lookup(tree_trie, {?y, 0})
    end

    test "scope_overrides returns all registered scopes", %{store: s} do
      Active.bind(s, {:agent, :normal}, "y", :agent_copy, "Agent copy")

      overrides = Active.scope_overrides(s)
      assert Map.has_key?(overrides, :agent)
    end
  end

  describe "mode_trie/2" do
    test "returns empty trie for unregistered mode", %{store: s} do
      trie = Active.mode_trie(s, :insert)
      assert :not_found = Bindings.lookup(trie, {?j, 0x02})
    end
  end

  describe "reset/1" do
    test "removes all user overrides", %{store: s} do
      Active.bind(s, :normal, "SPC z z", :custom_cmd, "Custom command")
      Active.bind(s, :normal, "Q", :replay, "Replay")
      Active.bind(s, :insert, "C-j", :next, "Next")
      Active.bind(s, :normal, "SPC m t", :test, "Test", filetype: :elixir)
      Active.bind(s, {:agent, :normal}, "y", :copy, "Copy")

      Active.reset(s)

      # Normal overrides cleared
      assert Active.normal_overrides(s) == %{}

      # Mode tries cleared
      trie = Active.mode_trie(s, :insert)
      assert :not_found = Bindings.lookup(trie, {?j, 0x02})

      # Filetype tries reset to defaults (user override for SPC m t → :test removed,
      # but default +test prefix for :elixir remains from build_default_filetype_tries)
      ft_trie = Active.filetype_trie(s, :elixir)
      # The user's :test command should be gone; the key is now a +test prefix from defaults
      assert {:prefix, _} = Bindings.lookup(ft_trie, {?t, 0})

      # Scope overrides cleared
      assert Active.scope_overrides(s) == %{}

      # Leader trie reset to defaults
      trie = Active.leader_trie(s)

      case Bindings.lookup(trie, {?z, 0}) do
        {:prefix, z_node} ->
          assert :not_found = Bindings.lookup(z_node, {?z, 0})

        :not_found ->
          assert true
      end
    end
  end
end
