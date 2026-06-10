defmodule MingaEditor.PickerUITest do
  @moduledoc "Tests PickerUI picker-state transitions and orchestration."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  defp marked_buffer_picker do
    [
      %Item{id: 0, label: "alpha"},
      %Item{id: 1, label: "beta"},
      %Item{id: 2, label: "gamma"}
    ]
    |> Picker.new(title: "Switch buffer", max_visible: 10)
    |> Picker.move_down()
    |> Picker.toggle_mark()
    |> Picker.move_down()
    |> Picker.toggle_mark()
  end

  defp picker_state_with_buffers([first_content | rest]) do
    state = TestHelpers.base_state(content: first_content)

    buffers =
      Enum.reduce(rest, state.workspace.buffers, fn content, acc ->
        {:ok, pid} = BufferProcess.start_link(content: content)
        Buffers.add_background(acc, pid)
      end)

    picker_state = %PickerState{
      picker: marked_buffer_picker(),
      source: MingaEditor.UI.Picker.BufferSource,
      restore: 0
    }

    state
    |> EditorState.set_buffers(buffers)
    |> ModalOverlay.open(:picker, PickerPayload.new(picker_state))
  end

  defp preview_promotion_state do
    {:ok, original_buf} = BufferProcess.start_link(content: "original")
    {:ok, preview_buf} = BufferProcess.start_link(content: "preview")
    win_id = 1
    original_window = Window.new(win_id, original_buf, 24, 80)
    preview_window = %{original_window | buffer: preview_buf, content: {:buffer, preview_buf}}

    original_workspace = %SessionState{
      viewport: Viewport.new(24, 80),
      editing: VimState.new(),
      buffers: %Buffers{active: original_buf, list: [original_buf], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => original_window},
        active: win_id,
        next_id: win_id + 1
      }
    }

    preview_workspace = %{
      original_workspace
      | buffers: %Buffers{active: preview_buf, list: [original_buf, preview_buf], active_index: 1},
        windows: %{original_workspace.windows | map: %{win_id => preview_window}}
    }

    tab = Tab.new_file(1, "original.ex")
    tb = TabBar.new(tab)
    tb = TabBar.update_context(tb, 1, SessionState.to_tab_context(original_workspace))

    picker = Picker.new([%Item{id: "preview", label: "preview.ex"}], title: "Files")

    picker_state = %PickerState{
      picker: picker,
      source: MingaEditor.UI.Picker.FileSource,
      restore: 0
    }

    state = %EditorState{
      port_manager: self(),
      workspace: preview_workspace,
      shell_state: %ShellState{tab_bar: tb, modal: {:picker, PickerPayload.new(picker_state)}}
    }

    {state, original_buf, preview_buf}
  end

  defmodule NoBulkActionsSource do
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "No bulk actions"

    @impl true
    def candidates(_ctx), do: []

    @impl true
    def on_select(%Item{id: id}, state), do: Map.put(state, :selected_item_id, id)

    @impl true
    def on_cancel(state), do: state

    @impl true
    def actions(_item), do: [{"Open", :open}, {"Delete", :delete}]

    @impl true
    def on_action(:open, %Item{id: id}, state), do: Map.put(state, :action_item_id, id)

    def on_action(:delete, %Item{id: id}, state),
      do: Map.put(state, :action_item_id, {:delete, id})

    def on_action(_action, _item, state), do: state
  end

  defp picker_state_for_source(state, source, items) do
    picker = items |> Picker.new(title: "Test", max_visible: 10) |> mark_all_picker()

    picker_state = %PickerState{
      picker: picker,
      source: source,
      restore: state.workspace.buffers.active_index
    }

    ModalOverlay.open(state, :picker, PickerPayload.new(picker_state))
  end

  defp mark_all_picker(%Picker{items: []} = picker), do: picker

  defp mark_all_picker(%Picker{} = picker) do
    Enum.reduce(1..length(picker.items), picker, fn _, acc ->
      Picker.toggle_mark(acc) |> Picker.move_down()
    end)
  end

  describe "bulk picker actions" do
    test "C-o shows source bulk actions when items are marked" do
      state = picker_state_with_buffers(["alpha", "beta", "gamma"])

      new_state = PickerUI.handle_key(state, ?o, MingaEditor.Input.mod_ctrl())
      {:picker, %{picker_ui: %{action_menu: {actions, 0}}}} = new_state.shell_state.modal

      assert actions == [
               {"Kill all marked",
                {:bulk, :kill_marked, Picker.marked_items(marked_buffer_picker())}}
             ]
    end

    test "Enter applies source bulk select when items are marked" do
      state = picker_state_with_buffers(["alpha", "beta", "gamma"])

      new_state = PickerUI.handle_key(state, 13, 0)

      assert new_state.shell_state.modal == :none
      assert length(new_state.workspace.buffers.list) == 1
      assert Minga.Buffer.content(new_state.workspace.buffers.active) == "alpha"
    end
  end

  describe "branch delete shortcut" do
    test "plain d remains query input for a generic picker that exposes delete actions" do
      picker =
        Picker.new([%Item{id: :delete_me, label: "Delete me"}], title: "Delete Action Test")

      picker_state = %PickerState{
        picker: picker,
        source: Minga.Test.DeleteActionPickerSource,
        restore: 0
      }

      state = %EditorState{
        port_manager: nil,
        workspace: %SessionState{viewport: Viewport.new(24, 80), editing: VimState.new()},
        shell_state: %ShellState{modal: {:picker, PickerPayload.new(picker_state)}}
      }

      result = PickerUI.handle_key(state, ?d, 0)
      {:picker, %{picker_ui: picker_ui}} = result.shell_state.modal

      assert picker_ui.picker.query == "d"
      assert result.shell_state.status_msg == nil
      assert result.workspace.editing.mode == :normal
    end
  end

  describe "bulk action fallback for sources without bulk support" do
    test "Enter still performs normal single select when marks exist" do
      state = TestHelpers.base_state(content: "initial")

      picker_state =
        picker_state_for_source(state, NoBulkActionsSource, [
          %Item{id: :first, label: "first"},
          %Item{id: :second, label: "second"}
        ])

      new_state = PickerUI.handle_key(picker_state, 13, 0)

      assert new_state.shell_state.modal == :none
      assert Map.get(new_state, :selected_item_id) == :first
      refute Map.has_key?(new_state, :bulk_selected)
    end

    test "C-o falls back to normal per-item actions and Enter dispatches on_action" do
      state = TestHelpers.base_state(content: "initial")

      picker_state =
        picker_state_for_source(state, NoBulkActionsSource, [
          %Item{id: :first, label: "first"},
          %Item{id: :second, label: "second"}
        ])

      menu_state = PickerUI.handle_key(picker_state, ?o, MingaEditor.Input.mod_ctrl())

      assert {:picker, %{picker_ui: %{action_menu: {actions, 0}}}} = menu_state.shell_state.modal
      assert Enum.map(actions, &elem(&1, 0)) == ["Open", "Delete"]

      new_state = PickerUI.handle_key(menu_state, 13, 0)

      assert new_state.shell_state.modal == :none
      assert Map.get(new_state, :action_item_id) == :first
      refute Map.has_key?(new_state, :bulk_selected)
    end
  end

  describe "preview promotion" do
    test "restores the original tab before creating the promoted preview tab" do
      {state, original_buf, preview_buf} = preview_promotion_state()

      new_state = PickerUI.handle_key(state, 13, 0)

      tb = new_state.shell_state.tab_bar
      assert new_state.shell_state.modal == :none
      assert TabBar.count(tb) == 2
      assert %Buffers{active: ^original_buf} = TabBar.get(tb, 1).context.buffers
      assert %Buffers{active: ^preview_buf} = TabBar.get(tb, 2).context.buffers
      assert new_state.workspace.buffers.active == preview_buf
    end

    test "backspace through a mode prefix restores the original source and prompt" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      switched_state = PickerUI.handle_key(state, ?>, 0)
      {:picker, %{picker_ui: switched_pui}} = switched_state.shell_state.modal
      assert switched_pui.source == MingaEditor.UI.Picker.CommandSource
      assert switched_pui.original_source == MingaEditor.UI.Picker.FileSource
      assert switched_pui.mode_prefix == ">"

      reverted_state = PickerUI.handle_key(switched_state, 127, 0)
      {:picker, %{picker_ui: reverted_pui}} = reverted_state.shell_state.modal
      assert reverted_pui.source == MingaEditor.UI.Picker.FileSource
      assert reverted_pui.original_source == nil
      assert reverted_pui.mode_prefix == ""
    end

    test "hash mode switches to project search and backspaces to the original source" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      switched_state = PickerUI.handle_key(state, ?#, 0)
      {:picker, %{picker_ui: switched_pui}} = switched_state.shell_state.modal
      assert switched_pui.source == MingaEditor.UI.Picker.ProjectSearchSource
      assert switched_pui.original_source == MingaEditor.UI.Picker.FileSource
      assert switched_pui.mode_prefix == "#"

      reverted_state = PickerUI.handle_key(switched_state, 127, 0)
      {:picker, %{picker_ui: reverted_pui}} = reverted_state.shell_state.modal
      assert reverted_pui.source == MingaEditor.UI.Picker.FileSource
      assert reverted_pui.original_source == nil
      assert reverted_pui.mode_prefix == ""
    end

    test "typing fix in git log stays in the fuzzy query" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      source = :"Elixir.MingaEditor.PickerUITest.GitLogSource"
      picker = Picker.new([%Item{id: "abc123", label: "abc123"}], title: "Git Log")
      picker_state = %PickerState{picker: picker, source: source}
      state = put_in(state.shell_state.modal, {:picker, PickerPayload.new(picker_state)})

      state = Enum.reduce(~c"fix", state, fn cp, acc -> PickerUI.handle_key(acc, cp, 0) end)
      {:picker, %{picker_ui: pui}} = state.shell_state.modal

      assert pui.source == source
      assert pui.picker.query == "fix"
    end
  end
end
