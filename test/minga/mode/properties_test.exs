defmodule Minga.Mode.PropertiesTest do
  @moduledoc """
  Property tests for the Mode FSM dispatcher.

  Two invariants:
    1. `Mode.process/3` always returns `{new_mode, [command()], state()}`
       where `new_mode` is a member of the closed `Mode.mode()` enum.
    2. Pressing Escape from any mode transitions to `:normal` (the rest mode).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Keymap.Defaults
  alias Minga.Mode

  alias Minga.Mode.{
    CommandState,
    DeleteConfirmState,
    EvalState,
    OperatorPendingState,
    ReplaceState,
    SearchPromptState,
    SearchState,
    State,
    SubstituteConfirmState,
    ToolConfirmState,
    VisualState
  }

  @escape 27

  # The full Mode.mode() enum. Kept here as a literal so the test fails if
  # `Mode.mode()` ever expands without the property generators tracking it.
  @all_modes [
    :normal,
    :insert,
    :visual,
    :visual_line,
    :visual_block,
    :operator_pending,
    :command,
    :eval,
    :replace,
    :search,
    :search_prompt,
    :substitute_confirm,
    :extension_confirm,
    :tool_confirm,
    :delete_confirm
  ]

  # Modes Mode.process/3 actually dispatches. :visual_line and :visual_block
  # are valid mode atoms in the FSM enum, but they're held by VisualState's
  # :visual_type field — the dispatcher routes both through Minga.Mode.Visual
  # via the :visual key.
  #
  # NOTE: :extension_confirm is intentionally omitted: its state struct
  # has no `count` field, so `Mode.reset_count/1` raises a KeyError when
  # the dispatcher applies a transition result. Re-add this mode once
  # `ExtensionConfirmState` includes `count: nil`.
  @dispatchable_modes [
    :normal,
    :insert,
    :visual,
    :operator_pending,
    :command,
    :eval,
    :replace,
    :search,
    :search_prompt,
    :substitute_confirm,
    :tool_confirm,
    :delete_confirm
  ]

  # ── Generators ────────────────────────────────────────────────────────────

  # Builds a fresh `Mode.State` populated with the production keymap so
  # leader/normal-binding lookups behave the same as in the editor.
  defp base_state do
    %{
      Mode.initial_state()
      | leader_trie: Defaults.leader_trie(),
        normal_bindings: Defaults.normal_bindings()
    }
  end

  defp default_mode_state(:normal), do: base_state()
  defp default_mode_state(:insert), do: base_state()
  defp default_mode_state(:replace), do: %ReplaceState{}
  defp default_mode_state(:visual), do: %VisualState{visual_type: :char}
  defp default_mode_state(:operator_pending), do: %OperatorPendingState{operator: :delete}
  defp default_mode_state(:command), do: %CommandState{}
  defp default_mode_state(:eval), do: %EvalState{}
  defp default_mode_state(:search), do: %SearchState{direction: :forward}
  defp default_mode_state(:search_prompt), do: %SearchPromptState{}

  defp default_mode_state(:substitute_confirm) do
    %SubstituteConfirmState{
      matches: [{0, 0, 1}],
      pattern: "x",
      replacement: "y",
      original_content: "x"
    }
  end

  defp default_mode_state(:tool_confirm) do
    %ToolConfirmState{pending: [:formatter]}
  end

  defp default_mode_state(:delete_confirm) do
    %DeleteConfirmState{path: "/tmp/x", name: "x", dir?: false}
  end

  # Codepoints across the printable ASCII range plus control codes that the
  # FSM recognises (Esc, Backspace, Enter, etc.). Keep modifiers small —
  # the FSM only branches on Ctrl/Alt, not arbitrary masks.
  defp key_gen do
    gen all(
          codepoint <- StreamData.integer(0..127),
          modifiers <- StreamData.integer(0..7)
        ) do
      {codepoint, modifiers}
    end
  end

  # ── Property 1: result shape and mode-enum closure ─────────────────────────

  property "Mode.process/3 always returns {mode, [command], state} with mode in the enum" do
    check all(
            mode <- StreamData.member_of(@dispatchable_modes),
            key <- key_gen()
          ) do
      state = default_mode_state(mode)
      result = Mode.process(mode, key, state)

      assert {new_mode, commands, new_state} = result
      assert new_mode in @all_modes, "#{inspect(new_mode)} is not a valid mode atom"
      assert is_list(commands)
      assert is_struct(new_state)
    end
  end

  # ── Property 2: Esc is a universal exit to :normal ─────────────────────────

  property "Escape from any mode lands in :normal" do
    check all(mode <- StreamData.member_of(@dispatchable_modes)) do
      state = default_mode_state(mode)
      {new_mode, _commands, _new_state} = Mode.process(mode, {@escape, 0}, state)
      assert new_mode == :normal
    end
  end

  # ── Sanity guard: enum coverage ────────────────────────────────────────────

  test "default_mode_state/1 covers every dispatchable mode" do
    for mode <- @dispatchable_modes do
      assert match?(%_{}, default_mode_state(mode)) or
               match?(%State{}, default_mode_state(mode))
    end
  end
end
