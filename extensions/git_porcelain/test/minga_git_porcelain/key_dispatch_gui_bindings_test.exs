defmodule MingaGitPorcelain.KeyDispatchGUIBindingsTest do
  @moduledoc "Tests GUI-only key dispatch bindings."
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Keymap.Active
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.KeyDispatch
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  test "SPC g d s is available for GUI frontends only" do
    gui_state = state_with_frontend(:native_gui)
    tui_state = state_with_frontend(:tui)

    assert "Not a diff view" =
             dispatch_keys(gui_state, [32, ?g, ?d, ?s]) |> EditorState.status_msg()

    assert "Not in a git repository" =
             dispatch_keys(tui_state, [32, ?g, ?d, ?s]) |> EditorState.status_msg()
  end

  test "TUI keeps SPC g d as the direct diff command" do
    state = state_with_frontend(:tui)

    assert "Not in a git repository" =
             dispatch_keys(state, [32, ?g, ?d]) |> EditorState.status_msg()
  end

  test "GUI moves the default diff command to SPC g d f" do
    state = state_with_frontend(:native_gui)

    assert nil == dispatch_keys(state, [32, ?g, ?d]) |> EditorState.status_msg()

    assert "Not in a git repository" =
             dispatch_keys(state, [32, ?g, ?d, ?f]) |> EditorState.status_msg()
  end

  test "an existing exact user binding for SPC g d s is preserved" do
    keymap_server = start_supervised!({Active, name: nil})
    :ok = Active.bind(keymap_server, :normal, "SPC g d s", :git_status_toggle, "User diff")

    state = state_with_frontend(:native_gui, keymap_server)
    state = dispatch_keys(state, [32, ?g, ?d, ?s])

    assert state.workspace.keymap_scope == :git_status
    assert EditorState.status_msg(state) == nil
  end

  test "an existing exact user binding for SPC g d is preserved in GUI" do
    keymap_server = start_supervised!({Active, name: nil})
    :ok = Active.bind(keymap_server, :normal, "SPC g d", :git_status_toggle, "User diff")

    state = state_with_frontend(:native_gui, keymap_server)
    state = dispatch_keys(state, [32, ?g, ?d])

    assert state.workspace.keymap_scope == :git_status
    assert EditorState.status_msg(state) == nil
  end

  defp state_with_frontend(frontend_type, keymap_server \\ nil) do
    buf =
      start_supervised!(
        Supervisor.child_spec({Buffer, content: "x"}, id: {:buffer, frontend_type})
      )

    state = %EditorState{
      port_manager: self(),
      workspace: %SessionState{viewport: Viewport.new(24, 80)},
      capabilities: %Capabilities{frontend_type: frontend_type}
    }

    state =
      if keymap_server do
        %{state | keymap_server: keymap_server}
      else
        state
      end

    EditorState.add_buffer(state, buf)
  end

  defp dispatch_keys(state, keys) do
    Enum.reduce(keys, state, fn key, acc ->
      KeyDispatch.handle_key(acc, key, 0)
    end)
  end
end
