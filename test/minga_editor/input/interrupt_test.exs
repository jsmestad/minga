defmodule MingaEditor.Input.InterruptTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Completion
  alias Minga.Mode
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.HoverPopup
  alias MingaEditor.Input
  alias MingaEditor.Input.Interrupt
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Feedback
  alias MingaEditor.Shell.Traditional.HoverPopupWorkflow
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.ModalOverlay.Conflict, as: ConflictPayload
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.ModalOverlay.Prompt, as: PromptPayload
  alias MingaEditor.State.Picker
  alias MingaEditor.State.Prompt, as: PromptState
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  @ctrl_g 7
  @modal_variants [:picker, :prompt, :completion, :conflict]

  defp base_state(opts \\ []) do
    buf_opts = Keyword.get(opts, :buffer_opts, content: "hello\nworld")
    buf = start_supervised!({BufferProcess, buf_opts})

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        buffers: %Buffers{
          active: buf,
          list: [buf],
          active_index: 0
        }
      },
      interaction: %MingaEditor.State.Interaction{focus_stack: Input.default_stack()}
    }
  end

  @spec open_modal_variant(EditorState.t(), ModalOverlay.variant()) :: EditorState.t()
  defp open_modal_variant(state, :picker) do
    picker = MingaEditor.UI.Picker.new([%MingaEditor.UI.Picker.Item{id: "x", label: "x"}])
    ModalWorkflow.open(state, :picker, PickerPayload.new(%Picker{picker: picker}))
  end

  defp open_modal_variant(state, :prompt) do
    prompt = %PromptState{handler: __MODULE__, text: "query", cursor: 5, label: "Find"}
    ModalWorkflow.open(state, :prompt, PromptPayload.new(prompt))
  end

  defp open_modal_variant(state, :completion) do
    completion = %Completion{items: [], trigger_position: {0, 0}}
    ModalWorkflow.open(state, :completion, CompletionPayload.new(:tab1, completion: completion))
  end

  defp open_modal_variant(state, :conflict) do
    ModalWorkflow.open(
      state,
      :conflict,
      ConflictPayload.new(state.workspace.buffers.active, "/tmp/test.txt")
    )
  end

  @spec dirty_interrupt_axes(EditorState.t()) :: {EditorState.t(), HoverPopup.t()}
  defp dirty_interrupt_axes(state) do
    hover = HoverPopup.new("hover docs", 3, 4)

    mode_state = %{
      Mode.initial_state()
      | leader_node: %{?a => :noop},
        prefix_node: %{?b => :noop},
        pending: :replace,
        count: 2
    }

    vim = %{state.workspace.editing | mode: :insert, mode_state: mode_state}

    state = %{
      state
      | workspace: %{state.workspace | keymap_scope: :agent, editing: vim}
    }

    state = WhichKeyWorkflow.begin(state, %{}, [])
    state = WhichKeyWorkflow.reveal(state, state.shell_runtime.state.whichkey.generation)

    state =
      state
      |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("stale status")
      |> HoverPopupWorkflow.show(hover)
      |> then(fn state ->
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          (&UIState.set_prefix(&1, :g)).(state.workspace.agent_ui)
        )
      end)

    {state, hover}
  end

  @spec assert_known_good_after_interrupt(EditorState.t(), HoverPopup.t()) :: true
  defp assert_known_good_after_interrupt(state, _hover) do
    assert state.workspace.keymap_scope == :editor
    assert state.workspace.editing.mode == :normal
    assert state.workspace.editing.mode_state == Mode.initial_state()
    assert Runtime.state(state.shell_runtime).modal == :none
    assert Runtime.state(state.shell_runtime).whichkey.node == nil
    assert Runtime.state(state.shell_runtime).whichkey.show == false
    assert state.workspace.agent_ui.view |> View.pending_prefix() == nil
    assert state.shell_runtime.state.notice.message == nil
    assert state.shell_runtime.state.hover_popup == nil
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
      assert new_state.workspace.keymap_scope == :editor
      assert new_state.workspace.editing.mode == :normal
      assert Runtime.state(new_state.shell_runtime).modal == :none
      assert Runtime.state(new_state.shell_runtime).whichkey.node == nil
    end
  end

  describe "scope reset" do
    test "resets :agent scope to :editor" do
      state = base_state()
      state = %{state | workspace: SessionState.set_keymap_scope(state.workspace, :agent)}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.workspace.keymap_scope == :editor
    end

    test "resets :file_tree scope to :editor" do
      state = base_state()
      state = %{state | workspace: SessionState.set_keymap_scope(state.workspace, :file_tree)}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.workspace.keymap_scope == :editor
    end

    test "leaves :editor scope unchanged" do
      state = base_state()
      assert state.workspace.keymap_scope == :editor
      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.workspace.keymap_scope == :editor
    end
  end

  describe "mode reset" do
    test "resets :insert to :normal" do
      state = base_state()
      vim = %{state.workspace.editing | mode: :insert, mode_state: Mode.initial_state()}
      state = %{state | workspace: %{state.workspace | editing: vim}}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.workspace.editing.mode == :normal
    end

    test "resets :visual to :normal" do
      state = base_state()
      vim = %{state.workspace.editing | mode: :visual, mode_state: Mode.initial_state()}
      state = %{state | workspace: %{state.workspace | editing: vim}}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.workspace.editing.mode == :normal
    end

    test "resets :operator_pending to :normal" do
      state = base_state()
      vim = %{state.workspace.editing | mode: :operator_pending, mode_state: Mode.initial_state()}
      state = %{state | workspace: %{state.workspace | editing: vim}}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.workspace.editing.mode == :normal
    end

    test "resets :command to :normal" do
      state = base_state()
      vim = %{state.workspace.editing | mode: :command, mode_state: Mode.initial_state()}
      state = %{state | workspace: %{state.workspace | editing: vim}}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.workspace.editing.mode == :normal
    end

    test "fresh mode_state replaces stale non-normal mode state" do
      state = base_state()

      vim = %{
        state.workspace.editing
        | mode: :normal,
          mode_state: %Minga.Mode.CommandState{input: "w"}
      }

      state = %{state | workspace: %{state.workspace | editing: vim}}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.workspace.editing.mode == :normal
      assert new_state.workspace.editing.mode_state == Mode.initial_state()
    end

    test "fresh mode_state clears leader sequence state" do
      state = base_state()

      mode_state = %{
        Mode.initial_state()
        | leader_node: %{?b => {:command, :list_buffers}},
          leader_keys: ["SPC"],
          prefix_node: %{?g => {:command, :goto_line}},
          prefix_keys: ["g"],
          insert_changed: true
      }

      vim = %{state.workspace.editing | mode_state: mode_state}
      state = %{state | workspace: %{state.workspace | editing: vim}}

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.workspace.editing.mode_state == Mode.initial_state()
    end

    test "leaves :normal mode unchanged" do
      state = base_state()
      assert state.workspace.editing.mode == :normal
      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.workspace.editing.mode == :normal
    end
  end

  describe "overlay dismissal" do
    test "closes open picker" do
      state = base_state()

      picker =
        MingaEditor.UI.Picker.new([
          %MingaEditor.UI.Picker.Item{id: "a", label: "a"},
          %MingaEditor.UI.Picker.Item{id: "b", label: "b"},
          %MingaEditor.UI.Picker.Item{id: "c", label: "c"}
        ])

      state =
        ModalWorkflow.open(
          state,
          :picker,
          PickerPayload.new(%Picker{picker: picker, source: nil})
        )

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert Runtime.state(new_state.shell_runtime).modal == :none
    end

    test "dismisses which-key popup" do
      state = WhichKeyWorkflow.begin(base_state(), %{}, [])
      state = WhichKeyWorkflow.reveal(state, state.shell_runtime.state.whichkey.generation)

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert Runtime.state(new_state.shell_runtime).whichkey.node == nil
      assert Runtime.state(new_state.shell_runtime).whichkey.show == false
    end

    test "dismisses conflict prompt" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = ModalWorkflow.open(state, :conflict, ConflictPayload.new(buf, "/tmp/test.txt"))

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      refute ModalOverlay.match(Runtime.state(new_state.shell_runtime).modal, :conflict)
    end

    test "closes completion menu" do
      state = base_state()
      completion = %Completion{items: [], trigger_position: {0, 0}}

      payload =
        MingaEditor.State.ModalOverlay.Completion.new(:tab1, completion: completion)

      state = ModalWorkflow.open(state, :completion, payload)

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert MingaEditor.Shell.Traditional.ModalWorkflow.completion(new_state) == nil
      refute ModalOverlay.match(new_state.shell_runtime.state.modal, :completion)
    end

    test "clears the notice without mutating operation feedback" do
      state =
        base_state()
        |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("some message")

      {operation_feedback, _operation} =
        OperationFeedback.start(
          state.feedback.operation_feedback,
          :external_format,
          "buffer:ctrl-g",
          "Formatting"
        )

      state = %{
        state
        | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
      }

      operation_feedback = state.feedback.operation_feedback

      assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
      assert new_state.shell_runtime.state.notice.message == nil
      assert new_state.feedback.operation_feedback == operation_feedback
    end
  end

  describe "combined resets" do
    for variant <- @modal_variants do
      test "resets stale axes while dismissing #{variant} modal" do
        variant = unquote(variant)

        {state, hover} =
          base_state()
          |> open_modal_variant(variant)
          |> dirty_interrupt_axes()

        assert {:handled, new_state} = Interrupt.handle_key(state, @ctrl_g, 0)
        assert_known_good_after_interrupt(new_state, hover)
      end
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
