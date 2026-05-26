defmodule MingaEditor.StatusBar.DataSafeModeTest do
  @moduledoc false

  # Mutates global application env via Minga.SafeMode.
  use ExUnit.Case, async: false

  alias Minga.Config.Options
  alias MingaEditor.StatusBar.Data
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Viewport

  test "from_state to_modeline_data carries safe_mode true" do
    Minga.SafeMode.put(true)
    on_exit(fn -> Minga.SafeMode.put(false) end)

    options = start_supervised!({Options, name: nil})

    state = %EditorState{
      port_manager: self(),
      options_server: options,
      workspace: %SessionState{viewport: Viewport.new(24, 80)},
      shell_state: %MingaEditor.Shell.Traditional.State{}
    }

    {:buffer, buffer_data} = Data.from_state(state)
    modeline_data = Data.to_modeline_data({:buffer, buffer_data})

    assert buffer_data.safe_mode == true
    assert modeline_data.safe_mode == true
  end
end
