defmodule MingaEditor.StatusBar.DataSafeModeTest do
  @moduledoc false

  # Mutates global application env via Minga.SafeMode.
  use ExUnit.Case, async: false

  alias Minga.Config.Options
  alias MingaEditor.StatusBar.Data
  alias MingaEditor.StatusBar.Data.Buffer, as: StatusBuffer
  alias MingaEditor.StatusBar.Data.Common
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Session.State, as: SessionState

  test "from_state to_modeline_data carries safe_mode true" do
    Minga.SafeMode.put(true)
    on_exit(fn -> Minga.SafeMode.put(false) end)

    options = start_supervised!({Options, name: nil})

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      interaction: %MingaEditor.State.Interaction{options_server: options},
      workspace: %SessionState{},
      shell_runtime: Runtime.new(Runtime.default_entry(), %MingaEditor.Shell.Traditional.State{})
    }

    %Data{common: %Common{status: status}, content: %StatusBuffer{}} =
      data = Data.from_state(state)

    modeline_data = Data.to_modeline_data(data)

    assert status.safe_mode? == true
    assert modeline_data.safe_mode == true
  end
end
