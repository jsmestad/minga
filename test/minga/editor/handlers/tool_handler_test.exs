defmodule Minga.Editor.Handlers.ToolHandlerTest do
  @moduledoc """
  Pure-function tests for `Minga.Editor.Handlers.ToolHandler`.

  Uses `RenderPipeline.TestHelpers.base_state/1` to construct state
  without starting a GenServer.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.Handlers.ToolHandler
  alias Minga.Editor.State, as: EditorState

  import Minga.Editor.RenderPipeline.TestHelpers

  describe "tool_install_started" do
    test "sets status message and returns render + refresh effects" do
      state = base_state()
      event = {:minga_event, :tool_install_started, %{name: "ripgrep"}}
      {new_state, effects} = ToolHandler.handle(state, event)

      assert EditorState.status_msg(new_state) == "Installing ripgrep..."
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

      assert EditorState.status_msg(new_state) == "ripgrep: Downloading..."
      assert :render in effects
    end
  end

  describe "tool_install_complete" do
    test "sets success status and returns log + render effects" do
      state = base_state()
      event = {:minga_event, :tool_install_complete, %{name: "ripgrep", version: "14.1"}}
      {new_state, effects} = ToolHandler.handle(state, event)

      assert String.contains?(EditorState.status_msg(new_state), "ripgrep v14.1 installed")
      assert {:log_message, "Tool installed: ripgrep v14.1"} in effects
      assert :render in effects
      assert {:refresh_tool_picker} in effects
    end

    test "schedules clear_tool_status in non-headless mode" do
      state = base_state()
      state = %{state | backend: :tui}
      event = {:minga_event, :tool_install_complete, %{name: "ripgrep", version: "14.1"}}
      {_state, effects} = ToolHandler.handle(state, event)

      assert {:send_after, :clear_tool_status, 5_000} in effects
    end

    test "does not schedule timer in headless mode" do
      state = base_state()
      # base_state defaults to headless
      event = {:minga_event, :tool_install_complete, %{name: "ripgrep", version: "14.1"}}
      {_state, effects} = ToolHandler.handle(state, event)

      refute Enum.any?(effects, fn
               {:send_after, :clear_tool_status, _} -> true
               _ -> false
             end)
    end
  end

  describe "tool_install_failed" do
    test "sets error status and returns log + render effects" do
      state = base_state()
      event = {:minga_event, :tool_install_failed, %{name: "ripgrep", reason: "network error"}}
      {new_state, effects} = ToolHandler.handle(state, event)

      assert String.contains?(EditorState.status_msg(new_state), "ripgrep install failed")

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

  describe "clear_tool_status" do
    test "clears status when it starts with a tool prefix" do
      state = base_state()
      state = EditorState.set_status(state, "\u2713 ripgrep v14.1 installed")

      {new_state, effects} = ToolHandler.handle(state, :clear_tool_status)

      assert EditorState.status_msg(new_state) == nil
      assert :render in effects
    end

    test "preserves non-tool status messages" do
      state = base_state()
      state = EditorState.set_status(state, "Some other message")

      {new_state, effects} = ToolHandler.handle(state, :clear_tool_status)

      assert EditorState.status_msg(new_state) == "Some other message"
      assert :render in effects
    end
  end

  describe "tool_missing (suppressed)" do
    test "returns log effect when prompts are suppressed" do
      state = base_state()
      state = EditorState.update_shell_state(state, &%{&1 | suppress_tool_prompts: true})

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
