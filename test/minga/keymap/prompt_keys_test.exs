defmodule Minga.Keymap.PromptKeysTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.PromptKeys
  alias Minga.Keymap.Scope

  @ctrl 0x02

  @text_editing for letter <- ~c"aehwu", do: {letter, @ctrl}

  describe "picker_trie/1" do
    test "binds the established picker keys" do
      trie = PromptKeys.picker_trie(split: true)

      assert Bindings.lookup(trie, {?j, @ctrl}) == {:command, :picker_next}
      assert Bindings.lookup(trie, {?k, @ctrl}) == {:command, :picker_prev}
      assert Bindings.lookup(trie, {57_353, 0}) == {:command, :picker_next}
      assert Bindings.lookup(trie, {57_352, 0}) == {:command, :picker_prev}
      assert Bindings.lookup(trie, {13, 0}) == {:command, :picker_select}
      assert Bindings.lookup(trie, {27, 0}) == {:command, :picker_cancel}
      assert Bindings.lookup(trie, {9, 0}) == {:command, :picker_complete}
      assert Bindings.lookup(trie, {57_363, 0}) == {:command, :picker_page_down}
      assert Bindings.lookup(trie, {57_362, 0}) == {:command, :picker_page_up}
      assert Bindings.lookup(trie, {?., @ctrl}) == {:command, :picker_act_menu}
      assert Bindings.lookup(trie, {?v, @ctrl}) == {:command, :picker_open_split}
    end

    test "binds ⌃V only for sources whose selection shows in the focused window" do
      assert Bindings.lookup(PromptKeys.picker_trie(), {?v, @ctrl}) == :not_found
    end

    test "leaves typing, text editing and the retired chords unbound" do
      trie = PromptKeys.picker_trie(split: true)
      retired = [{?n, @ctrl}, {?p, @ctrl}, {?g, @ctrl}, {?o, @ctrl}, {?d, @ctrl}, {?v, 0x04}]

      for key <- [{?a, 0}, {?j, 0}, {127, 0}] ++ @text_editing ++ retired do
        assert Bindings.lookup(trie, key) == :not_found, inspect(key)
      end
    end
  end

  describe "picker_hints/3" do
    test "the hints follow what the list can do, in the keys a list or a prompt prefers" do
      for {rows?, list_keys?, expected} <- [
            {false, true, [{"q", "close"}]},
            {false, false, [{"esc", "close"}]},
            {true, true, [{"j k", "move"}, {"↩", "run"}, {"q", "close"}]},
            {true, false, [{"⌃J ⌃K", "move"}, {"↩", "run"}, {"esc", "close"}]}
          ] do
        keys_for = &default_picker_keys(list_keys?, &1)
        assert PromptKeys.picker_hints(rows?, list_keys?, keys_for) == expected
      end
    end

    test "the hints name the keys that run each command now, so a rebind shows" do
      rebound = %{
        picker_next: [{?n, 0}],
        picker_prev: [{?p, 0}],
        picker_select: [{13, 0}],
        picker_cancel: [{?x, 0}]
      }

      assert PromptKeys.picker_hints(true, true, &Map.fetch!(rebound, &1)) ==
               [{"n p", "move"}, {"↩", "run"}, {"x", "close"}]
    end

    test "a key held with another modifier names it and yields to a plain or control key" do
      rebound = %{
        picker_next: [{?j, 0x04}, {57_353, 0}],
        picker_prev: [{?k, 0x08}],
        picker_select: [{13, 0x01}],
        picker_cancel: [{?q, 0x04}, {?g, 0x02}]
      }

      assert PromptKeys.picker_hints(true, false, &Map.fetch!(rebound, &1)) ==
               [{"↓ ⌘K", "move"}, {"⇧↩", "run"}, {"⌃G", "close"}]
    end
  end

  # The single keys that run `command` in the default picker trie, for a list (`list_keys?`) or a prompt.
  defp default_picker_keys(list_keys?, command) do
    trie = if list_keys?, do: PromptKeys.picker_list_trie(), else: PromptKeys.picker_trie()
    for [key] <- Minga.Keymap.Bindings.sequences_for_command(trie, command), do: key
  end

  describe "prompt_trie/1" do
    test "binds run, cancel and complete" do
      trie = PromptKeys.prompt_trie()

      assert Bindings.lookup(trie, {13, 0}) == {:command, :prompt_submit}
      assert Bindings.lookup(trie, {27, 0}) == {:command, :prompt_cancel}
      assert Bindings.lookup(trie, {9, 0}) == {:command, :prompt_complete}
    end

    test "⌃J and ⌃K move only when the prompt shows a list; otherwise ⌃K stays text editing" do
      assert Bindings.lookup(PromptKeys.prompt_trie(list: true), {?k, @ctrl}) ==
               {:command, :prompt_prev}

      assert Bindings.lookup(PromptKeys.prompt_trie(list: true), {?j, @ctrl}) ==
               {:command, :prompt_next}

      assert Bindings.lookup(PromptKeys.prompt_trie(), {?k, @ctrl}) == :not_found
      assert Bindings.lookup(PromptKeys.prompt_trie(), {?j, @ctrl}) == :not_found
    end

    test "never binds the text-editing control keys" do
      for trie <- [PromptKeys.prompt_trie(), PromptKeys.prompt_trie(list: true)],
          key <- @text_editing do
        assert Bindings.lookup(trie, key) == :not_found, inspect(key)
      end
    end
  end

  describe "the picker and prompt scopes" do
    test "are built-in scopes that publish the tries in the insert vim state" do
      assert Scope.Picker in Scope.builtin_modules()
      assert Scope.Prompt in Scope.builtin_modules()

      assert Scope.Picker.keymap(:insert, picker_split: true) ==
               PromptKeys.picker_trie(split: true)

      assert Scope.Prompt.keymap(:insert, prompt_list: true) == PromptKeys.prompt_trie(list: true)
      assert Scope.Picker.keymap(:normal, []) == PromptKeys.picker_list_trie()
      assert Scope.Picker.keymap(:cua, []) == Bindings.new()
      assert Scope.Prompt.keymap(:insert, []) == PromptKeys.prompt_trie()
      assert Scope.Prompt.keymap(:cua, []) == Bindings.new()
    end

    test "are modal scopes, never the workspace scope" do
      assert Scope.Picker.modal?()
      assert Scope.Prompt.modal?()
      refute Scope.Editor.modal?()

      assert :picker in Scope.all_scopes()
      refute :picker in Scope.surface_scopes()
      refute :prompt in Scope.surface_scopes()
      assert :editor in Scope.surface_scopes()
    end

    test "which-key lists the picker keys with their labels" do
      labels =
        PromptKeys.picker_trie(split: true)
        |> Bindings.children()
        |> Map.new(fn {key, label, _kind} -> {key, label} end)

      assert labels[{?j, @ctrl}] == "Next"
      assert labels[{?k, @ctrl}] == "Previous"
      assert labels[{13, 0}] == "Open the selection"
      assert labels[{?v, @ctrl}] == "Open in a split"
      assert labels[{?., @ctrl}] == "Act on the highlighted row"
      assert labels[{27, 0}] == "Close"
    end
  end
end
