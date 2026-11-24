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
      assert Scope.Picker.keymap(:normal, []) == Bindings.new()
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
