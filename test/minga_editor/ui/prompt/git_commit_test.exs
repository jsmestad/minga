defmodule MingaEditor.UI.Prompt.GitCommitTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Prompt.GitCommit

  # Build a minimal state map matching the shape that EditorState.set_status/2
  # writes to: it delegates to ShellState.set_status/2 which sets status_msg.
  @spec test_state() :: map()
  defp test_state do
    %{shell_state: %MingaEditor.Shell.Traditional.State{status_msg: nil}}
  end

  describe "label/0" do
    test "returns a non-empty string" do
      label = GitCommit.label()
      assert is_binary(label)
      assert label != ""
    end
  end

  describe "on_submit/2" do
    test "with empty string sets status containing cancelled" do
      state = test_state()

      new_state = GitCommit.on_submit("", state)
      assert new_state.shell_state.status_msg =~ "cancelled"
    end

    test "with whitespace-only string also cancels" do
      state = test_state()

      new_state = GitCommit.on_submit("   ", state)
      assert new_state.shell_state.status_msg =~ "cancelled"
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = test_state()

      assert GitCommit.on_cancel(state) == state
    end
  end
end
