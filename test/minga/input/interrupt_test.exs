defmodule Minga.Input.InterruptTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Completion
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Picker
  alias Minga.Editor.State.WhichKey
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Input
  alias Minga.Input.Interrupt
  alias Minga.Mode

  @ctrl_g 7

  defp base_state(opts \\ []) do
    buf_opts = Keyword.get(opts, :buffer_opts, content: "hello\nworld")
    {:ok, buf} = BufferServer.start_link(buf_opts)

    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(24, 80),
      vim: VimState.new(),
      buffers: %Buffers{
        active: buf,
        list: [buf],
        active_index: 0
      },
      focus_stack: Input.default_stack()
    }
  end

  describe "Ctrl-G basics" do
    test "handles Ctrl-G and returns :handled" do
      state = base_state()
      assert {:handled, _new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
    end

    test "passes through for any other key" do
      state = base_state()
      assert {:passthrough, ^state} = Interrupt.handle_key(state, ?j, 0)
    end

    test "passes through for Ctrl-G with modifiers" do
      state = base_state()
      assert {:passthrough, ^state} = Interrupt.handle_key(state, @ctrl_g, 1)
    end

    test "in clean state, Ctrl-G is a no-op that still returns :handled" do
      state = base_state()
      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.keymap_scope == :editor
      assert new_state.vim.mode == :normal
      assert new_state.picker_ui.picker == nil
      assert new_state.whichkey.node == nil
    end
  end

  describe "scope reset" do
    test "resets :agent scope to :editor" do
      state = %{base_state() | keymap_scope: :agent}
      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.keymap_scope == :editor
    end

    test "resets :file_tree scope to :editor" do
      state = %{base_state() | keymap_scope: :file_tree}
      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.keymap_scope == :editor
    end

    test "leaves :editor scope unchanged" do
      state = base_state()
      assert state.keymap_scope == :editor
      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.keymap_scope == :editor
    end
  end

  describe "mode reset" do
    test "resets :insert to :normal" do
      state = base_state()
      vim = %{state.vim | mode: :insert, mode_state: Mode.initial_state()}
      state = %{state | vim: vim}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.vim.mode == :normal
    end

    test "resets :visual to :normal" do
      state = base_state()
      vim = %{state.vim | mode: :visual, mode_state: Mode.initial_state()}
      state = %{state | vim: vim}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.vim.mode == :normal
    end

    test "resets :operator_pending to :normal" do
      state = base_state()
      vim = %{state.vim | mode: :operator_pending, mode_state: Mode.initial_state()}
      state = %{state | vim: vim}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.vim.mode == :normal
    end

    test "resets :command to :normal" do
      state = base_state()
      vim = %{state.vim | mode: :command, mode_state: Mode.initial_state()}
      state = %{state | vim: vim}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.vim.mode == :normal
    end

    test "fresh mode_state clears prefix_node" do
      state = base_state()
      mode_state = %{Mode.initial_state() | prefix_node: %{?a => :fold_toggle}}
      vim = %{state.vim | mode: :normal, mode_state: mode_state}
      state = %{state | vim: vim}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.vim.mode_state.prefix_node == nil
    end

    test "fresh mode_state clears leader_node" do
      state = base_state()
      mode_state = %{Mode.initial_state() | leader_node: %{?b => {:command, :list_buffers}}}
      vim = %{state.vim | mode_state: mode_state}
      state = %{state | vim: vim}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.vim.mode_state.leader_node == nil
    end

    test "leaves :normal mode unchanged" do
      state = base_state()
      assert state.vim.mode == :normal
      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.vim.mode == :normal
    end
  end

  describe "overlay dismissal" do
    test "closes open picker" do
      state = base_state()
      picker = Minga.Picker.new(["a", "b", "c"])
      state = %{state | picker_ui: %Picker{picker: picker, source: nil}}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.picker_ui.picker == nil
    end

    test "dismisses which-key popup" do
      state = base_state()
      state = %{state | whichkey: %WhichKey{node: %{}, show: true}}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.whichkey.node == nil
      assert new_state.whichkey.show == false
    end

    test "dismisses conflict prompt" do
      state = base_state()
      buf = state.buffers.active
      state = %{state | pending_conflict: {buf, "/tmp/test.txt"}}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.pending_conflict == nil
    end

    test "closes completion menu" do
      state = base_state()
      completion = %Completion{items: [], trigger_position: {0, 0}}
      state = %{state | completion: completion}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.completion == nil
    end

    test "clears status message" do
      state = %{base_state() | status_msg: "some message"}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.status_msg == nil
    end
  end

  describe "combined resets" do
    test "resets everything at once" do
      state = base_state()
      buf = state.buffers.active
      picker = Minga.Picker.new(["x"])
      completion = %Completion{items: [], trigger_position: {0, 0}}

      vim = %{state.vim | mode: :visual, mode_state: Mode.initial_state()}

      state = %{
        state
        | keymap_scope: :agent,
          vim: vim,
          picker_ui: %Picker{picker: picker},
          whichkey: %WhichKey{node: %{}, show: true},
          pending_conflict: {buf, "/tmp/x"},
          completion: completion,
          status_msg: "hello"
      }

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.keymap_scope == :editor
      assert new_state.vim.mode == :normal
      assert new_state.picker_ui.picker == nil
      assert new_state.whichkey.node == nil
      assert new_state.whichkey.show == false
      assert new_state.pending_conflict == nil
      assert new_state.completion == nil
      assert new_state.status_msg == nil
    end
  end

  describe "handler ordering" do
    test "Interrupt is first in overlay_handlers" do
      [first | _] = Input.overlay_handlers()
      assert first == Interrupt
    end

    test "Interrupt is first in default_stack" do
      [first | _] = Input.default_stack()
      assert first == Interrupt
    end
  end
end
