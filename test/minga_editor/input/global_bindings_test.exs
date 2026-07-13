defmodule MingaEditor.Input.GlobalBindingsTest do
  @moduledoc "Global input behavior for canceling LSP formatting."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Input.GlobalBindings
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.LSP.FormatOperation
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  test "Esc cancels the newest underlying LSP format request and drops ownership" do
    state = base_state()
    buffer = state.workspace.buffers.active
    client = fake_client(self())
    ref = make_ref()
    operation = operation(client, ref, buffer)
    state = EditorState.update_lsp(state, &LSPState.track_format(&1, operation))

    assert {:passthrough, new_state} = GlobalBindings.handle_key(state, 27, 0)
    assert_receive {:cancel_request, ^ref}
    refute LSPState.format_active?(new_state.lsp, ref)
    assert EditorState.status_msg(new_state) == "Format canceled"
  end

  test "Esc remains a passthrough when no format is active" do
    state = base_state()

    assert GlobalBindings.handle_key(state, 27, 0) == {:passthrough, state}
  end

  defp operation(client, ref, buffer) do
    FormatOperation.new(
      client: client,
      ref: ref,
      buffer: buffer,
      version: 0,
      encoding: :utf8,
      spinner_timer: make_ref(),
      cancellable_timer: make_ref(),
      timeout_timer: make_ref()
    )
  end

  defp fake_client(parent) do
    start_supervised!(
      {Task,
       fn ->
         receive do
           {:"$gen_cast", {:cancel_request, ref}} ->
             send(parent, {:cancel_request, ref})
         end
       end},
      id: {:fake_client, make_ref()}
    )
  end

  defp base_state do
    buffer = start_supervised!({BufferProcess, content: "hello\n"}, id: {:buffer, make_ref()})

    workspace = %MingaEditor.Session.State{
      viewport: Viewport.new(24, 80),
      editing: VimState.new(),
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buffer, 24, 80)},
        active: 1,
        next_id: 2
      }
    }

    %EditorState{port_manager: self(), workspace: workspace}
  end
end
