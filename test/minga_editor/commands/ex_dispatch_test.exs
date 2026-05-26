defmodule MingaEditor.Commands.ExDispatchTest do
  # This suite touches the global command registry, so it must not run async.
  use ExUnit.Case, async: false

  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Viewport

  setup do
    if Process.whereis(Minga.Command.Registry) == nil do
      start_supervised!(Minga.Command.Registry)
    end

    Minga.Command.Registry.reset()
    :ok
  end

  test "zero-arg provider-backed ex commands resolve through the registry and execute" do
    new_state = Commands.execute(state(), {:execute_ex_command, {:indent_picker, []}})

    assert ModalOverlay.tag(EditorState.modal(new_state)) == :picker
  end

  test "tuple-arg ex commands in the registry bypass list execute through tuple handling" do
    new_state = Commands.execute(state(), {:execute_ex_command, {:agent_set_model, ["gpt-4o"]}})

    assert MingaEditor.State.AgentAccess.panel(new_state).model_name == "gpt-4o"
  end

  test "safe mode ex command reports active state" do
    Minga.SafeMode.put(true)
    on_exit(fn -> Minga.SafeMode.put(false) end)

    new_state = Commands.execute(state(), {:execute_ex_command, {:safe_mode_status, []}})

    assert EditorState.status_msg(new_state) =~ "Safe mode is active"
  end

  test "safe mode ex command reports inactive state" do
    Minga.SafeMode.put(false)
    on_exit(fn -> Minga.SafeMode.put(false) end)

    new_state = Commands.execute(state(), {:execute_ex_command, {:safe_mode_status, []}})

    assert EditorState.status_msg(new_state) == "Safe mode is inactive"
  end

  defp state do
    %EditorState{
      port_manager: nil,
      workspace: %SessionState{
        viewport: Viewport.new(24, 80)
      }
    }
  end
end
