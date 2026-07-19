defmodule MingaEditor.Handlers.ToolHandlerTest do
  @moduledoc "Focused workflow tests for `MingaEditor.Handlers.ToolHandler`."

  use ExUnit.Case, async: true

  alias MingaEditor.Handlers.ToolHandler
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.ToolPromptWorkflow

  import MingaEditor.RenderPipeline.TestHelpers

  describe "tool_install_started" do
    test "sets status message and returns render + refresh effects" do
      state = base_state()
      event = {:minga_event, :tool_install_started, %{name: "ripgrep"}}
      {new_state, effects} = ToolHandler.handle(state, event)

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) ==
               "Installing ripgrep..."

      assert :render in effects
      assert {:refresh_tool_picker} in effects
    end
  end

  describe "tool_install_progress" do
    test "updates status with progress message" do
      state = base_state()

      event =
        {:minga_event, :tool_install_progress, %{name: "ripgrep", message: "Downloading..."}}

      {new_state, effects} = ToolHandler.handle(state, event)

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) ==
               "ripgrep: Downloading..."

      assert :render in effects
    end
  end

  describe "tool_install_complete" do
    test "relies on NoticeWorkflow timer and emits no tool clear timer" do
      state = base_state(backend: :tui)
      event = {:minga_event, :tool_install_complete, %{name: "ripgrep", version: "14.1"}}
      {new_state, effects} = ToolHandler.handle(state, event)

      assert String.contains?(NoticeWorkflow.message(new_state), "ripgrep v14.1 installed")
      assert {:log_message, "Tool installed: ripgrep v14.1"} in effects
      assert {:refresh_tool_picker} in effects
      assert :render in effects

      refute Enum.any?(effects, &match?({:send_after, :clear_tool_status, _}, &1))

      timer = new_state.shell_runtime.state.notice.timer
      assert is_reference(timer)
      assert Process.read_timer(timer) in 1..2_000
      NoticeWorkflow.dismiss(new_state)
    end

    test "headless completion creates no notice timer" do
      state = base_state()
      event = {:minga_event, :tool_install_complete, %{name: "ripgrep", version: "14.1"}}
      {new_state, _effects} = ToolHandler.handle(state, event)

      assert new_state.shell_runtime.state.notice.timer == nil
    end
  end

  describe "tool_install_failed" do
    test "sets error status and returns log + render effects" do
      state = base_state()
      event = {:minga_event, :tool_install_failed, %{name: "ripgrep", reason: "network error"}}
      {new_state, effects} = ToolHandler.handle(state, event)

      assert String.contains?(
               MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state),
               "ripgrep install failed"
             )

      assert Enum.any?(effects, fn
               {:log_message, msg} -> String.contains?(msg, "Tool install failed")
               _ -> false
             end)

      assert :render in effects
    end

    test "handles non-binary reason" do
      state = base_state()
      event = {:minga_event, :tool_install_failed, %{name: "ripgrep", reason: :timeout}}
      {_new_state, effects} = ToolHandler.handle(state, event)

      assert Enum.any?(effects, fn
               {:log_message, msg} -> String.contains?(msg, ":timeout")
               _ -> false
             end)
    end
  end

  describe "tool_uninstall_complete" do
    test "returns log + refresh + render effects" do
      state = base_state()
      event = {:minga_event, :tool_uninstall_complete, %{name: "ripgrep"}}
      {_state, effects} = ToolHandler.handle(state, event)

      assert {:log_message, "Tool uninstalled: ripgrep"} in effects
      assert {:refresh_tool_picker} in effects
      assert :render in effects
    end
  end

  describe "legacy clear_tool_status delivery" do
    test "cannot dismiss newer tool-like notices" do
      for message <- ["Installing fd...", "✓ fd v9 installed"] do
        state =
          base_state(rendering: :disabled)
          |> NoticeWorkflow.publish(message)

        notice_id = state.shell_runtime.state.notice.id

        assert {:noreply, delivered} = MingaEditor.handle_info(:clear_tool_status, state)
        assert NoticeWorkflow.message(delivered) == message
        assert delivered.shell_runtime.state.notice.id == notice_id
      end
    end
  end

  describe "tool_missing (suppressed)" do
    test "returns log effect when prompts are suppressed" do
      state = base_state()
      state = ToolPromptWorkflow.suppress(state, true)

      event = {:minga_event, :tool_missing, %Minga.Events.ToolMissingEvent{command: "rg"}}
      {new_state, effects} = ToolHandler.handle(state, event)

      assert new_state == state

      assert Enum.any?(effects, fn
               {:log, :editor, :debug, msg} -> String.contains?(msg, "suppressed")
               _ -> false
             end)
    end
  end

  describe "catch-all" do
    test "unknown messages return no-op" do
      state = base_state()
      {new_state, effects} = ToolHandler.handle(state, :unknown_tool_msg)
      assert new_state == state
      assert effects == []
    end
  end
end
