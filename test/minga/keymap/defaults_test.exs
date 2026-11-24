defmodule Minga.Keymap.DefaultsTest do
  @moduledoc """
  The default keymap's contract with `docs/design/keys.md`: where each key lives, which keys are retired, and how which-key groups are labelled.
  """

  use ExUnit.Case, async: true

  import Minga.Keymap.Sigil

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.Keymap.NormalPrefixes

  # {keys after SPC, command}. Moved and new rows cite docs/design/keys.md.
  @leader_homes [
    # Kept neighbours
    {~k(SPC), :project_find_file},
    {~k(:), :command_palette},
    {~k(/), :search_project},
    {~k(f f), :find_file},
    {~k(f F), :find_file_other_window},
    {~k(f s), :save},
    {~k(f p), :open_config},
    {~k(b b), :buffer_list},
    {~k(,), :buffer_list},
    {~k(b d), :kill_buffer},
    {~k(b X), :force_kill_buffer},
    {~k(b D), :kill_other_buffers},
    {~k(b K), :kill_all_buffers},
    {~k(w h), :window_left},
    {~k(w j), :window_down},
    {~k(w k), :window_up},
    {~k(w l), :window_right},
    {~k(w v), :split_vertical},
    {~k(w s), :split_horizontal},
    {~k(q q), :quit_all},
    {~k(h c), :describe_command},
    {~k(h f), :describe_function},
    {~k(h k), :describe_key},
    {~k(c h), :call_hierarchy},
    {~k(c H), :call_hierarchy_outgoing},
    {~k(c v), :selection_expand},
    {~k(c V), :selection_shrink},
    {~k(c D), :find_references},
    {~k(s s), :search_buffer},
    {~k(s r), :search_and_replace},
    {~k(p f), :project_find_file},
    {~k(p p), :project_switch},
    {~k(p a), :project_add},
    {~k(p d), :project_remove},
    {~k(p i), :project_invalidate},
    {~k(p r), :project_recent_files},
    {~k(p .), :project_browse},
    {~k(p T), :test_all},
    {~k(TAB TAB), :workspace_toggle},
    {~k(TAB D), :workspace_close},
    # Moved to their mnemonic homes
    {~k(;), :enter_eval},
    {~k(c x), :diagnostics_list},
    {~k(c d), :goto_definition},
    {~k(s i), :document_symbols},
    {~k(s j), :jump_list},
    {~k(s u), :timeline_toggle},
    {~k(h a), :apropos},
    {~k(f o), :remote_find_file},
    # SPC a: everyday keys
    {~k(a a), :toggle_agentic_view},
    {~k(a n), :agent_new_session},
    {~k(a s), :agent_abort},
    {~k(a u), :undo_agent_session},
    {~k(a v), :toggle_agent_split},
    {~k(a ?), :inline_ask},
    {~k(a r), :workspace_pending_reviews},
    {~k(a e), :inline_edit},
    {~k(a W), :code_why},
    {~k(a A), :code_autobiography},
    {~k(a p), :agent_edits_decide},
    # SPC a q: Queue
    {~k(a q q), :agent_queued_inputs},
    {~k(a q f), :agent_queue_follow_up},
    # SPC a x: Context
    {~k(a x b), :agent_attach_buffer},
    {~k(a x f), :agent_attach_file},
    {~k(a x d), :agent_attach_diagnostics},
    {~k(a x l), :agent_draft_attachments},
    # SPC a S: Session
    {~k(a S h), :agent_session_history},
    {~k(a S R), :agent_session_rename},
    {~k(a S m), :agent_pick_model},
    {~k(a S t), :agent_pick_thinking},
    {~k(a S l), :agent_start_session_picker},
    {~k(a S H), :agent_retained_history},
    {~k(a S k), :agent_checklist},
    {~k(a S s), :agent_stop_session}
  ]

  # Keys docs/design/keys.md retires: they do nothing and are gone from which-key.
  @retired [
    ~k(a t),
    ~k(a P),
    ~k(a c),
    ~k(a Q),
    ~k(a o),
    ~k(a J),
    ~k(a f),
    ~k(a b),
    ~k(a F),
    ~k(a D),
    ~k(a j),
    ~k(a h),
    ~k(a R),
    ~k(a m),
    ~k(a T),
    ~k(a N),
    ~k(a k),
    ~k(a H),
    ~k(b P),
    ~k(b <),
    ~k(b >),
    ~k(TAB n),
    ~k(TAB p),
    ~k(TAB a),
    ~k(TAB d),
    ~k(c g),
    ~k(c j),
    ~k(g w),
    ~k(g a)
  ]

  @groups [
    {~k(a), "Minga"},
    {~k(a q), "Queue"},
    {~k(a x), "Context"},
    {~k(a S), "Session"},
    {~k(f), "Files"},
    {~k(b), "Buffers"},
    {~k(w), "Windows"},
    {~k(q), "Quit"},
    {~k(h), "Help"},
    {~k(m), "Filetype"},
    {~k(TAB), "Workspace"}
  ]

  describe "leader_trie/0" do
    test "every key resolves to the command at its home in docs/design/keys.md" do
      trie = Defaults.leader_trie()

      for {keys, command} <- @leader_homes do
        assert {:command, ^command, _description} = Bindings.lookup_sequence(trie, keys),
               "SPC #{Bindings.format_sequence(keys)} should run #{command}"
      end
    end

    test "retired keys resolve to nothing" do
      trie = Defaults.leader_trie()

      for keys <- @retired do
        refute match?({:command, _, _}, Bindings.lookup_sequence(trie, keys)),
               "SPC #{Bindings.format_sequence(keys)} is retired"
      end
    end

    test "SPC a keeps about a dozen everyday keys and three groups" do
      {:prefix, a_node} = Bindings.lookup(Defaults.leader_trie(), {?a, 0})
      children = Bindings.children(a_node)

      groups = for {key, label, :group} <- children, do: {key, label}
      commands = for {_key, _label, :command} <- children, do: :command

      assert Enum.sort(groups) ==
               Enum.sort([{{?q, 0}, "Queue"}, {{?x, 0}, "Context"}, {{?S, 0}, "Session"}])

      assert length(commands) in 10..14
    end

    test "groups carry Title Case labels and never a leading +" do
      trie = Defaults.leader_trie()

      for {keys, label} <- @groups do
        assert {:prefix, node} = Bindings.lookup_sequence(trie, keys)
        assert node.description == label
      end

      for {_keys, label} <- Defaults.group_prefixes() ++ Defaults.filetype_group_prefixes() do
        refute String.starts_with?(label, "+"), "group label #{inspect(label)} starts with +"
        assert label == String.capitalize(String.first(label)) <> String.slice(label, 1..-1//1)
      end
    end

    test "leader bindings do not define duplicate key sequences" do
      duplicates =
        Defaults.all_bindings()
        |> Enum.map(fn {keys, _command, _description} -> keys end)
        |> Enum.frequencies()
        |> Enum.filter(fn {_keys, count} -> count > 1 end)

      assert duplicates == []
    end

    test "unknown leader prefix returns :not_found" do
      assert :not_found = Bindings.lookup(Defaults.leader_trie(), {?x, 0})
    end
  end

  describe "normal prefix trie" do
    test "bracket pairs and g keys follow docs/design/keys.md" do
      trie = NormalPrefixes.trie()

      for {keys, command} <- [
            {~k(] e), :next_diagnostic},
            {~k([ e), :prev_diagnostic},
            {~k(] d), :next_git_hunk},
            {~k([ d), :prev_git_hunk},
            {~k(] c), :next_git_hunk},
            {~k([ c), :prev_git_hunk},
            {~k(] h), :timeline_next_edit},
            {~k([ h), :timeline_prev_edit},
            {~k(] n), :nav_next_sibling},
            {~k([ n), :nav_prev_sibling},
            {~k(z C), :fold_close_recursive},
            {~k(z O), :fold_open_recursive}
          ] do
        assert {:command, ^command, _} = Bindings.lookup_sequence(trie, keys),
               "#{Bindings.format_sequence(keys)} should run #{command}"
      end
    end

    test "gt and gT are retired with tabs" do
      trie = NormalPrefixes.trie()
      assert :not_found = Bindings.lookup_sequence(trie, ~k(g t))
      assert :not_found = Bindings.lookup_sequence(trie, ~k(g T))
    end
  end

  describe "filetype bindings" do
    test "include representative built-in SPC m leaf bindings" do
      bindings = Defaults.filetype_bindings()

      assert {:elixir, [{?a, 0}], :alternate_file, "Alternate file"} in bindings
      assert {:elixir, [{?t, 0}, {?t, 0}], :test_file, "Test file"} in bindings
      assert {:elixir, [{?t, 0}, {?a, 0}], :test_all, "Test all"} in bindings
      assert {:swift, [{?t, 0}, {?o, 0}], :test_output, "Show test output"} in bindings
    end

    test "label the test submenu Test" do
      assert Defaults.filetype_group_prefixes() == [{[{?t, 0}], "Test"}]
    end
  end

  describe "leader_key/0" do
    test "returns the SPC key tuple" do
      assert Defaults.leader_key() == {32, 0}
    end
  end

  describe "all_bindings/0" do
    test "each binding is a {keys, command, description} tuple" do
      assert [_ | _] = Defaults.all_bindings()

      for {keys, command, description} <- Defaults.all_bindings() do
        assert is_list(keys)
        assert is_atom(command)
        assert is_binary(description)
      end
    end
  end

  describe "normal_bindings/0" do
    test "lists the Vim keys describe-key reports" do
      bindings = Defaults.normal_bindings()

      for key <- [
            {?h, 0},
            {?j, 0},
            {?k, 0},
            {?l, 0},
            {?d, 0x02},
            {?u, 0x02},
            {?d, 0},
            {?c, 0},
            {?y, 0}
          ] do
        assert {_command, _description} = bindings[key]
      end

      for {_key, {command, description}} <- bindings do
        assert is_atom(command)
        assert is_binary(description)
      end
    end

    test "⌥h ⌥j ⌥k ⌥l alias SPC c v, ]n, [n and SPC c V, and ⌥: is gone" do
      bindings = Defaults.normal_bindings()

      assert {:selection_expand, _} = bindings[{?h, 0x04}]
      assert {:nav_next_sibling, _} = bindings[{?j, 0x04}]
      assert {:nav_prev_sibling, _} = bindings[{?k, 0x04}]
      assert {:selection_shrink, _} = bindings[{?l, 0x04}]
      refute Map.has_key?(bindings, {?:, 0x04})
    end

    test "⌃O and ⌃I (and Tab, which terminals send for ⌃I) walk the jump list" do
      bindings = Defaults.normal_bindings()

      assert {:jump_back, _} = bindings[{?o, 0x02}]
      assert {:jump_forward, _} = bindings[{?i, 0x02}]
      assert {:jump_forward, _} = bindings[{9, 0}]
    end
  end
end
