defmodule MingaEditor.MouseClipboardTest do
  @moduledoc """
  Clipboard behavior for mouse selections.
  """

  use ExUnit.Case, async: true

  import Hammox

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Mode.VisualState
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Mouse
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Mouse, as: MouseState
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Workspace.State, as: WorkspaceState

  setup :verify_on_exit!

  setup do
    test_pid = self()

    stub(Minga.Clipboard.Mock, :write, fn text ->
      send(test_pid, {:clipboard_written, text})
      :ok
    end)

    stub(Minga.Clipboard.Mock, :read, fn -> nil end)

    :ok
  end

  test "native GUI mouse selection release does not copy to clipboard" do
    state = build_visual_drag_state(:native_gui)

    _state = Mouse.handle(state, 1, 0, :left, 0, :release, 1)

    refute_receive {:clipboard_written, _text}, 50
  end

  test "TUI mouse selection release keeps legacy auto-copy behavior" do
    state = build_visual_drag_state(:tui)

    _state = Mouse.handle(state, 1, 0, :left, 0, :release, 1)

    assert_receive {:clipboard_written, "hello"}, 200
  end

  defp build_visual_drag_state(frontend_type) do
    buffer = start_supervised!({BufferServer, content: "hello world"})
    BufferServer.set_option(buffer, :clipboard, :unnamedplus)
    BufferServer.move_to(buffer, {0, 4})

    visual_state = %VisualState{visual_anchor: {0, 0}, visual_type: :char}
    editing = VimState.transition(VimState.new(), :visual, visual_state)

    %EditorState{
      port_manager: nil,
      capabilities: %Capabilities{frontend_type: frontend_type},
      workspace: %WorkspaceState{
        viewport: Viewport.new(10, 40),
        buffers: %Buffers{active: buffer, list: [buffer]},
        editing: editing,
        mouse: MouseState.start_drag(%MouseState{}, {0, 0})
      }
    }
  end
end
