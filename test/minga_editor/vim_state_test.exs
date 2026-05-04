defmodule MingaEditor.VimStateTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.VimState`.

  Focused on the snapshot/restore contract: `VimState.normalize/1` is the
  chokepoint that ensures a vim state captured into long-lived storage
  (tab context) is a valid resting state — `mode` and `mode_state`
  agreeing on which struct holds the FSM context.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Mode
  alias MingaEditor.VimState

  alias Minga.Mode.{
    CommandState,
    EvalState,
    OperatorPendingState,
    ReplaceState,
    SearchPromptState,
    SearchState,
    State,
    VisualState
  }

  describe "normalize/1" do
    test "rebuilds %CommandState{} -> %Mode.State{} when mode is :normal" do
      # Reproduces the post-`:e <path><CR>` window where Command.handle_key
      # returned a CommandState alongside the new :normal mode.
      vim = %VimState{mode: :normal, mode_state: %CommandState{input: ""}}

      result = VimState.normalize(vim)

      assert result.mode == :normal
      assert match?(%State{}, result.mode_state)
    end

    test "rebuilds %EvalState{} -> %Mode.State{} when mode is :normal" do
      vim = %VimState{mode: :normal, mode_state: %EvalState{input: "1+1"}}
      result = VimState.normalize(vim)
      assert match?(%State{}, result.mode_state)
    end

    test "rebuilds %SearchState{} -> %Mode.State{} when mode is :normal" do
      vim = %VimState{
        mode: :normal,
        mode_state: %SearchState{direction: :forward, input: "foo"}
      }

      result = VimState.normalize(vim)
      assert match?(%State{}, result.mode_state)
    end

    test "passes through when mode_state already matches mode" do
      vim = %VimState{mode: :normal, mode_state: Mode.initial_state()}
      assert VimState.normalize(vim) == vim
    end

    test "passes through a properly-typed VisualState (preserves visual_anchor)" do
      visual = %VisualState{visual_type: :char, visual_anchor: {3, 7}}
      vim = %VimState{mode: :visual, mode_state: visual}

      result = VimState.normalize(vim)

      assert result.mode == :visual
      assert result.mode_state == visual
    end

    test "rebuilds when mode is :command but mode_state is the wrong struct" do
      vim = %VimState{mode: :command, mode_state: Mode.initial_state()}
      result = VimState.normalize(vim)
      assert match?(%CommandState{}, result.mode_state)
    end

    test "raises for context-required modes carrying a wrong mode_state struct" do
      # Visual is a context-required mode. Arriving here with %Mode.State{}
      # in mode_state means the caller bypassed the proper transition path;
      # surfacing the bug at snapshot time is better than silently writing
      # nonsense into a tab context.
      vim = %VimState{mode: :visual, mode_state: Mode.initial_state()}

      assert_raise ArgumentError, ~r/requires an explicit mode_state/, fn ->
        VimState.normalize(vim)
      end
    end
  end

  describe "normalize/1 — property: mode and mode_state always agree after normalize" do
    @default_state_modes [:normal, :insert, :command, :eval, :replace]

    # Maps each default-state mode to the struct module its mode_state should be.
    @expected_struct %{
      normal: State,
      insert: State,
      command: CommandState,
      eval: EvalState,
      replace: ReplaceState
    }

    # Generators for various mode_state struct types. The set is deliberately
    # broad so the property explores cross-mode mismatches the way the bug
    # manifests in production (`:normal` carrying a leaving `%CommandState{}`).
    defp mismatch_state_gen do
      StreamData.one_of([
        StreamData.constant(%State{}),
        StreamData.constant(%CommandState{}),
        StreamData.constant(%EvalState{}),
        StreamData.constant(%ReplaceState{}),
        StreamData.constant(%SearchState{direction: :forward}),
        StreamData.constant(%SearchPromptState{}),
        StreamData.constant(%VisualState{visual_type: :char}),
        StreamData.constant(%OperatorPendingState{operator: :delete})
      ])
    end

    property "default-state modes always produce the expected struct after normalize" do
      check all(
              mode <- StreamData.member_of(@default_state_modes),
              mode_state <- mismatch_state_gen()
            ) do
        vim = %VimState{mode: mode, mode_state: mode_state}
        result = VimState.normalize(vim)

        expected_module = Map.fetch!(@expected_struct, mode)
        assert is_struct(result.mode_state, expected_module)
        assert result.mode == mode
      end
    end
  end
end
