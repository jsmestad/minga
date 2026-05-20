defmodule MingaEditor.Input.HandlerTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Conflict, as: ConflictPayload
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Input
  alias MingaEditor.Input.ConflictPrompt
  alias MingaEditor.Input.GlobalBindings
  alias MingaEditor.Input.ModeFSM

  # Minimal editor state for testing handlers in isolation.
  # Handlers only inspect/modify the fields they care about.
  defp base_state(opts \\ []) do
    buf_opts = Keyword.get(opts, :buffer_opts, content: "hello\nworld")
    {:ok, buf} = BufferProcess.start_link(buf_opts)

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        buffers: %Buffers{
          active: buf,
          list: [buf],
          active_index: 0
        }
      },
      focus_stack: Input.default_stack()
    }
  end

  describe "ConflictPrompt" do
    test "passes through when no conflict is pending" do
      state = base_state()
      assert {:passthrough, _} = ConflictPrompt.handle_key(state, ?j, 0)
    end

    test "handles 'r' key during conflict by reloading" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = ModalOverlay.open(state, :conflict, ConflictPayload.new(buf, "/tmp/test.txt"))

      assert {:handled, new_state} = ConflictPrompt.handle_key(state, ?r, 0)
      refute ModalOverlay.match(new_state.shell_state.modal, :conflict)
      assert new_state.shell_state.status_msg =~ "reloaded"
    end

    test "handles 'k' key during conflict by keeping local", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "conflict_test.txt")
      File.write!(path, "hello\nworld")
      state = base_state(buffer_opts: [file_path: path])
      buf = state.workspace.buffers.active
      state = ModalOverlay.open(state, :conflict, ConflictPayload.new(buf, path))

      assert {:handled, new_state} = ConflictPrompt.handle_key(state, ?k, 0)
      refute ModalOverlay.match(new_state.shell_state.modal, :conflict)
    end

    test "swallows unrecognized keys during conflict" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = ModalOverlay.open(state, :conflict, ConflictPayload.new(buf, "/tmp/test.txt"))

      assert {:handled, new_state} = ConflictPrompt.handle_key(state, ?x, 0)
      # State unchanged except for swallowing the key
      assert new_state.shell_state.modal == state.shell_state.modal
    end
  end

  describe "GlobalBindings" do
    test "handles Ctrl+S" do
      state = base_state()
      ctrl = Protocol.mod_ctrl()
      assert {:handled, _} = GlobalBindings.handle_key(state, ?s, ctrl)
    end

    test "passes through non-global keys" do
      state = base_state()
      assert {:passthrough, _} = GlobalBindings.handle_key(state, ?j, 0)
    end
  end

  describe "ModeFSM" do
    test "always handles (never passes through)" do
      state = base_state()
      assert {:handled, _} = ModeFSM.handle_key(state, ?j, 0)
    end
  end
end
