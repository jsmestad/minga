defmodule MingaEditor.State.ModalOverlayTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.ModalOverlay.Conflict, as: ConflictPayload
  alias MingaEditor.State.ModalOverlay.Dashboard, as: DashboardPayload
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.ModalOverlay.Prompt, as: PromptPayload
  alias MingaEditor.State.Picker, as: PickerLegacy
  alias MingaEditor.State.Prompt, as: PromptLegacy
  alias MingaEditor.UI.Picker, as: UIPicker
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp base_state do
    %EditorState{
      port_manager: nil,
      workspace: %WorkspaceState{
        viewport: %Viewport{top: 0, left: 0, rows: 10, cols: 40}
      },
      shell_state: %ShellState{}
    }
  end

  defp picker_payload(label \\ "test") do
    PickerPayload.new(
      %PickerLegacy{
        picker: UIPicker.new([], title: label),
        source: nil,
        restore: 7
      },
      opened_at: 1_000
    )
  end

  defp prompt_payload(text \\ "search") do
    PromptPayload.new(
      %PromptLegacy{handler: SomeHandler, text: text, cursor: byte_size(text), label: ":"},
      opened_at: 1_001
    )
  end

  defp dashboard_payload do
    DashboardPayload.new(%{cursor: 0, items: []}, opened_at: 1_002)
  end

  defp completion_payload(tab_id \\ 1) do
    completion =
      Completion.new(
        [],
        {0, 0}
      )

    CompletionPayload.new(completion, tab_id, opened_at: 1_003)
  end

  defp conflict_payload(buffer \\ self()) do
    ConflictPayload.new(buffer, "buffer changed on disk", opened_at: 1_004)
  end

  describe "queries on the modal value" do
    test "none/0 returns :none" do
      assert ModalOverlay.none() == :none
    end

    test "tag/1 returns :none for :none and the variant tag for a tuple" do
      assert ModalOverlay.tag(:none) == :none
      assert ModalOverlay.tag({:picker, picker_payload()}) == :picker
      assert ModalOverlay.tag({:prompt, prompt_payload()}) == :prompt
      assert ModalOverlay.tag({:completion, completion_payload()}) == :completion
      assert ModalOverlay.tag({:conflict, conflict_payload()}) == :conflict
      assert ModalOverlay.tag({:dashboard, dashboard_payload()}) == :dashboard
    end

    test "active?/1 distinguishes :none from any variant" do
      refute ModalOverlay.active?(:none)
      assert ModalOverlay.active?({:picker, picker_payload()})
      assert ModalOverlay.active?({:conflict, conflict_payload()})
    end

    test "match/2 is true only for the same tag" do
      assert ModalOverlay.match(:none, :none)
      assert ModalOverlay.match({:picker, picker_payload()}, :picker)
      refute ModalOverlay.match({:picker, picker_payload()}, :prompt)
      refute ModalOverlay.match({:picker, picker_payload()}, :none)
      refute ModalOverlay.match(:none, :picker)
    end
  end

  describe "open/3 from :none" do
    test "writes the modal field and mirrors picker payload to the legacy slot" do
      state = base_state()
      payload = picker_payload()

      result = ModalOverlay.open(state, :picker, payload)

      assert result.shell_state.modal == {:picker, payload}
    end

    test "writes the prompt legacy field" do
      state = base_state()
      payload = prompt_payload()

      result = ModalOverlay.open(state, :prompt, payload)

      assert result.shell_state.modal == {:prompt, payload}
      assert result.shell_state.prompt_ui == payload.prompt_ui
    end

    test "writes the dashboard legacy field" do
      state = base_state()
      payload = dashboard_payload()

      result = ModalOverlay.open(state, :dashboard, payload)

      assert result.shell_state.modal == {:dashboard, payload}
      assert result.shell_state.dashboard == payload.state
    end

    test "writes the completion legacy field on workspace" do
      state = base_state()
      payload = completion_payload(7)

      result = ModalOverlay.open(state, :completion, payload)

      assert result.shell_state.modal == {:completion, payload}
      assert result.workspace.completion == payload.completion
    end

    test "writes the conflict legacy field as a {pid, message} tuple" do
      state = base_state()
      buffer = self()
      payload = conflict_payload(buffer)

      result = ModalOverlay.open(state, :conflict, payload)

      assert result.shell_state.modal == {:conflict, payload}
      assert result.workspace.pending_conflict == {buffer, payload.message}
    end
  end

  describe "open/3 displacement" do
    test "replacing a picker with a prompt clears the picker legacy slot" do
      state =
        base_state()
        |> ModalOverlay.open(:picker, picker_payload())

      prompt = prompt_payload("hello")
      result = ModalOverlay.open(state, :prompt, prompt)

      assert result.shell_state.modal == {:prompt, prompt}
      assert result.shell_state.prompt_ui == prompt.prompt_ui
    end

    test "replacing completion with picker clears workspace.completion" do
      state =
        base_state()
        |> ModalOverlay.open(:completion, completion_payload(1))

      picker = picker_payload()
      result = ModalOverlay.open(state, :picker, picker)

      assert result.shell_state.modal == {:picker, picker}
      assert result.workspace.completion == nil
    end

    test "replacing dashboard clears the dashboard legacy field" do
      state =
        base_state()
        |> ModalOverlay.open(:dashboard, dashboard_payload())

      picker = picker_payload()
      result = ModalOverlay.open(state, :picker, picker)

      assert result.shell_state.modal == {:picker, picker}
      assert result.shell_state.dashboard == nil
    end
  end

  describe "open/3 conflict-sticky rule" do
    test "open(:picker) while conflict is active is suppressed and returns state unchanged" do
      state =
        base_state()
        |> ModalOverlay.open(:conflict, conflict_payload())

      result = ModalOverlay.open(state, :picker, picker_payload())

      assert result == state
    end

    test "open(:conflict) over an existing conflict replaces (same-variant transition)" do
      state =
        base_state()
        |> ModalOverlay.open(:conflict, conflict_payload(self()))

      other = self()
      next = ConflictPayload.new(other, "different message", opened_at: 2_000)
      result = ModalOverlay.open(state, :conflict, next)

      assert result.shell_state.modal == {:conflict, next}
      assert result.workspace.pending_conflict == {other, "different message"}
    end
  end

  describe "transition/3" do
    test "bypasses the conflict-sticky rule" do
      state =
        base_state()
        |> ModalOverlay.open(:conflict, conflict_payload())

      picker = picker_payload()
      result = ModalOverlay.transition(state, :picker, picker)

      assert result.shell_state.modal == {:picker, picker}
      assert result.workspace.pending_conflict == nil
    end
  end

  describe "close/1 and dismiss/1" do
    test "close clears the active picker and resets the legacy slot" do
      state =
        base_state()
        |> ModalOverlay.open(:picker, picker_payload())

      result = ModalOverlay.close(state)

      assert result.shell_state.modal == :none
    end

    test "dismiss clears the active prompt and resets the legacy slot" do
      state =
        base_state()
        |> ModalOverlay.open(:prompt, prompt_payload())

      result = ModalOverlay.dismiss(state)

      assert result.shell_state.modal == :none
      assert result.shell_state.prompt_ui == %PromptLegacy{}
    end

    test "close clears workspace.completion when a completion is active" do
      state =
        base_state()
        |> ModalOverlay.open(:completion, completion_payload(3))

      result = ModalOverlay.close(state)

      assert result.shell_state.modal == :none
      assert result.workspace.completion == nil
    end

    test "close on an idle state is a no-op" do
      state = base_state()
      result = ModalOverlay.close(state)
      assert result == state
    end
  end

  describe "divergence assertion (dev/test only)" do
    test "raises when prompt_ui is mutated outside the gate" do
      state =
        base_state()
        |> ModalOverlay.open(:prompt, prompt_payload())

      tampered =
        update_in(state.shell_state.prompt_ui, fn pui ->
          %{pui | cursor: 999}
        end)

      assert_raise RuntimeError, ~r/ModalOverlay divergence/, fn ->
        ModalOverlay.close(tampered)
      end
    end

    test "raises when workspace.completion is cleared outside the gate" do
      state =
        base_state()
        |> ModalOverlay.open(:completion, completion_payload(2))

      tampered = put_in(state.workspace.completion, nil)

      assert_raise RuntimeError, ~r/ModalOverlay divergence/, fn ->
        ModalOverlay.close(tampered)
      end
    end

    test "tolerates legacy mutation while modal is :none" do
      state = base_state()

      tampered =
        put_in(state.shell_state.prompt_ui, %PromptLegacy{
          handler: SomeHandler,
          text: "x",
          cursor: 1,
          label: ":"
        })

      payload = picker_payload()
      result = ModalOverlay.open(tampered, :picker, payload)

      assert result.shell_state.modal == {:picker, payload}
      # The mutated prompt_ui is preserved: the gate makes no claims about
      # legacy fields whose variant is not currently tracked.
      assert result.shell_state.prompt_ui.text == "x"
    end
  end
end
