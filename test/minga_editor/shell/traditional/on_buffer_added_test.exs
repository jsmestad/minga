defmodule MingaEditor.Shell.Traditional.OnBufferAddedTest do
  @moduledoc """
  Focused tests for `Shell.Traditional.on_buffer_added/4`.

  Covers the dashboard auto-dismiss hook (#1425): when a buffer becomes
  active, any open dashboard modal is dismissed so the splash does not
  stick visually behind the buffer view.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Dashboard
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State.ModalOverlay.Dashboard, as: DashboardPayload
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerLegacy
  alias MingaEditor.UI.Picker, as: UIPicker
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp blank_workspace do
    %WorkspaceState{viewport: Viewport.new(24, 80)}
  end

  describe "dashboard auto-dismiss" do
    test "dismisses an active dashboard modal when a buffer is added" do
      shell_state = %ShellState{
        modal: {:dashboard, DashboardPayload.new(Dashboard.new_state())}
      }

      {:ok, buf} = BufferProcess.start_link(content: "hello")

      {new_shell, _ws, _effects} =
        Traditional.on_buffer_added(shell_state, blank_workspace(), buf, :open)

      assert new_shell.modal == :none
    end

    test "leaves an active picker modal alone when a buffer is added" do
      picker_payload =
        PickerPayload.new(%PickerLegacy{
          picker: UIPicker.new([], title: "test"),
          source: nil,
          restore: 0
        })

      shell_state = %ShellState{modal: {:picker, picker_payload}}

      {:ok, buf} = BufferProcess.start_link(content: "hello")

      {new_shell, _ws, _effects} =
        Traditional.on_buffer_added(shell_state, blank_workspace(), buf, :open)

      assert new_shell.modal == {:picker, picker_payload}
    end

    test "is a no-op when no modal is active" do
      shell_state = %ShellState{modal: :none}
      {:ok, buf} = BufferProcess.start_link(content: "hello")

      {new_shell, _ws, _effects} =
        Traditional.on_buffer_added(shell_state, blank_workspace(), buf, :open)

      assert new_shell.modal == :none
    end
  end
end
