defmodule MingaEditor.Handlers.GuiActionStartRemedyTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.StartRequest
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Traditional.Workflow

  test "a remedy click on a notice that no longer offers that remedy does nothing" do
    state = TestHelpers.base_state()

    for {lifecycle, clicked} <- [
          {:starting, :retry},
          {:unavailable, :set_up_provider},
          {{:conversation, self()}, :retry},
          {{:failed, StartFailure.missing_credentials()}, :retry},
          {{:failed, StartFailure.timed_out(StartRequest.default())}, :set_up_provider},
          {{:failed, %StartFailure{message: "Remote session stopped.", remedy: nil}}, :retry}
        ] do
      shown =
        Workflow.install_agent_ui(
          state,
          UIState.restore_chat(state.workspace.agent_ui, lifecycle)
        )

      assert GuiActionHandler.dispatch(shown, {:agent_start_remedy, clicked}) == shown
    end
  end
end
