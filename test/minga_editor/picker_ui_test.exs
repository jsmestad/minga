defmodule MingaEditor.PickerUITest do
  @moduledoc "Tests PickerUI picker-state transitions and orchestration."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Shell.Traditional.ModalWorkflow
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
    |> ModalWorkflow.open(:picker, PickerPayload.new(picker_state))
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
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          %ShellState{tab_bar: tb, modal: {:picker, PickerPayload.new(picker_state)}}
        )
    }

    {state, original_buf, preview_buf}
  end

  # A live-preview source used to prove that rapid typing through the input
  # path keeps preview/selection working against a large candidate set. Each
  # preview records the previewed item id into editor state so tests can assert
  # the applied result still drives on_select/2.
  defmodule LargePreviewSource do
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "Large preview"

    @impl true
    def candidates(_ctx), do: []

    @impl true
    def on_select(%Item{id: id}, state), do: Map.put(state, :previewed_id, id)

    @impl true
    def on_cancel(state), do: state

    @impl true
    def live_preview?, do: true
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

    ModalWorkflow.open(state, :picker, PickerPayload.new(picker_state))
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
      {:picker, %{picker_ui: %{action_menu: {actions, 0}}}} = new_state.shell_runtime.state.modal

      assert actions == [
               {"Kill all marked",
                {:bulk, :kill_marked, Picker.marked_items(marked_buffer_picker())}}
             ]
    end

    test "Enter applies source bulk select when items are marked" do
      state = picker_state_with_buffers(["alpha", "beta", "gamma"])

      new_state = PickerUI.handle_key(state, 13, 0)

      assert new_state.shell_runtime.state.modal == :none
      assert Enum.count(new_state.workspace.buffers.list) == 1
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
        shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            %ShellState{modal: {:picker, PickerPayload.new(picker_state)}}
          )
      }

      result = PickerUI.handle_key(state, ?d, 0)
      {:picker, %{picker_ui: picker_ui}} = result.shell_runtime.state.modal

      assert picker_ui.picker.query == "d"
      assert result.shell_runtime.state.notice.message == nil
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

      assert new_state.shell_runtime.state.modal == :none
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

      assert {:picker, %{picker_ui: %{action_menu: {actions, 0}}}} =
               menu_state.shell_runtime.state.modal

      assert Enum.map(actions, &elem(&1, 0)) == ["Open", "Delete"]

      new_state = PickerUI.handle_key(menu_state, 13, 0)

      assert new_state.shell_runtime.state.modal == :none
      assert Map.get(new_state, :action_item_id) == :first
      refute Map.has_key?(new_state, :bulk_selected)
    end
  end

  describe "preview promotion" do
    test "restores the original tab before creating the promoted preview tab" do
      {state, original_buf, preview_buf} = preview_promotion_state()

      new_state = PickerUI.handle_key(state, 13, 0)

      tb = new_state.shell_runtime.state.tab_bar
      assert new_state.shell_runtime.state.modal == :none
      assert TabBar.count(tb) == 2
      assert %Buffers{active: ^original_buf} = TabBar.get(tb, 1).context.buffers
      assert %Buffers{active: ^preview_buf} = TabBar.get(tb, 2).context.buffers
      assert new_state.workspace.buffers.active == preview_buf
    end

    test "backspace through a mode prefix restores the original source and prompt" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      switched_state = PickerUI.handle_key(state, ?>, 0)
      {:picker, %{picker_ui: switched_pui}} = switched_state.shell_runtime.state.modal
      assert switched_pui.source == MingaEditor.UI.Picker.CommandSource
      assert switched_pui.original_source == MingaEditor.UI.Picker.FileSource
      assert switched_pui.mode_prefix == ">"

      reverted_state = PickerUI.handle_key(switched_state, 127, 0)
      {:picker, %{picker_ui: reverted_pui}} = reverted_state.shell_runtime.state.modal
      assert reverted_pui.source == MingaEditor.UI.Picker.FileSource
      assert reverted_pui.original_source == nil
      assert reverted_pui.mode_prefix == ""
    end

    test "hash mode switches to project search and backspaces to the original source" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      switched_state = PickerUI.handle_key(state, ?#, 0)
      {:picker, %{picker_ui: switched_pui}} = switched_state.shell_runtime.state.modal
      assert switched_pui.source == MingaEditor.UI.Picker.ProjectSearchSource
      assert switched_pui.original_source == MingaEditor.UI.Picker.FileSource
      assert switched_pui.mode_prefix == "#"

      reverted_state = PickerUI.handle_key(switched_state, 127, 0)
      {:picker, %{picker_ui: reverted_pui}} = reverted_state.shell_runtime.state.modal
      assert reverted_pui.source == MingaEditor.UI.Picker.FileSource
      assert reverted_pui.original_source == nil
      assert reverted_pui.mode_prefix == ""
    end

    test "typing fix in git log stays in the fuzzy query" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      source = :"Elixir.MingaEditor.PickerUITest.GitLogSource"
      picker = Picker.new([%Item{id: "abc123", label: "abc123"}], title: "Git Log")
      picker_state = %PickerState{picker: picker, source: source}
      state = ModalOverlay.open(state, :picker, PickerPayload.new(picker_state))

      state = Enum.reduce(~c"fix", state, fn cp, acc -> PickerUI.handle_key(acc, cp, 0) end)
      {:picker, %{picker_ui: pui}} = state.shell_runtime.state.modal

      assert pui.source == source
      assert pui.picker.query == "fix"
    end
  end

  describe "rapid typing against a large candidate set" do
    # Upper bound on results the picker retains per refilter. Mirrors the
    # @result_limit in MingaEditor.UI.Picker; the filtered list must never
    # exceed this no matter how many candidates match, so each keystroke does a
    # fixed amount of result-building work rather than materializing every match.
    @result_limit 200

    defp large_picker_state(source, item_count) do
      state = TestHelpers.base_state(content: "initial")

      items = for i <- 1..item_count, do: %Item{id: i, label: "config_module_#{i}.ex"}
      picker = Picker.new(items, title: source.title(), max_visible: 10)

      picker_state = %PickerState{
        picker: picker,
        source: source,
        restore: state.workspace.buffers.active_index
      }

      ModalWorkflow.open(state, :picker, PickerPayload.new(picker_state))
    end

    defp type_string(state, string) do
      string
      |> String.to_charlist()
      |> Enum.reduce(state, fn cp, acc -> PickerUI.handle_key(acc, cp, 0) end)
    end

    test "each keystroke keeps the filtered set bounded to the result limit" do
      state = large_picker_state(NoBulkActionsSource, 10_000)

      # Type a query character-by-character through the real input path. Every
      # intermediate query matches all 10k candidates, but the picker must keep
      # only the bounded top-K so per-keystroke work is fixed, not O(n).
      final =
        Enum.reduce(["c", "co", "con", "conf", "config"], state, fn query, _acc ->
          typed = type_string(state, query)
          {:picker, %{picker_ui: %{picker: picker}}} = typed.shell_runtime.state.modal

          assert picker.query == query
          assert Picker.count(picker) == @result_limit
          assert Picker.total(picker) == 10_000
          typed
        end)

      {:picker, %{picker_ui: %{picker: picker}}} = final.shell_runtime.state.modal
      assert Picker.count(picker) == @result_limit
    end

    test "filtered result for a huge set matches the bounded prefix of the full match order" do
      # The input path against 10k candidates must yield exactly the bounded
      # top-K, identical to filtering directly. This guards against the input
      # path quietly diverging from Picker.refilter (e.g. an unbounded code path
      # sneaking back in).
      typed = type_string(large_picker_state(NoBulkActionsSource, 10_000), "config")
      {:picker, %{picker_ui: %{picker: picker}}} = typed.shell_runtime.state.modal

      reference =
        for(i <- 1..10_000, do: %Item{id: i, label: "config_module_#{i}.ex"})
        |> Picker.new()
        |> Picker.filter("config")

      assert Enum.map(picker.filtered, & &1.id) == Enum.map(reference.filtered, & &1.id)
    end

    test "input path stays bounded regardless of candidate-set size" do
      # The work per keystroke is bounded by the result limit, not the candidate
      # count: a 50k set produces the same number of retained results as a 1k
      # set for an all-matching query, so typing cost does not scale with size.
      small = type_string(large_picker_state(NoBulkActionsSource, 1_000), "config")
      large = type_string(large_picker_state(NoBulkActionsSource, 50_000), "config")

      {:picker, %{picker_ui: %{picker: small_picker}}} = small.shell_runtime.state.modal
      {:picker, %{picker_ui: %{picker: large_picker}}} = large.shell_runtime.state.modal

      assert Picker.count(small_picker) == @result_limit
      assert Picker.count(large_picker) == @result_limit
    end

    test "rapid typing through the input path returns promptly for a large set" do
      # Coarse catastrophe guard, not a tight latency SLA (that would be flaky on
      # a shared runner). A full per-keystroke scan-and-sort plus per-candidate
      # match-position computation over 20k candidates would blow well past this
      # ceiling; bounded top-K stays far under it. Measures the whole 6-keystroke
      # input path, then asserts a generous per-keystroke ceiling.
      state = large_picker_state(NoBulkActionsSource, 20_000)
      keystrokes = String.to_charlist("config")

      {micros, final} =
        :timer.tc(fn ->
          Enum.reduce(keystrokes, state, fn cp, acc -> PickerUI.handle_key(acc, cp, 0) end)
        end)

      {:picker, %{picker_ui: %{picker: picker}}} = final.shell_runtime.state.modal
      assert picker.query == "config"
      assert Picker.count(picker) == @result_limit

      per_keystroke_ms = micros / Enum.count(keystrokes) / 1_000

      assert per_keystroke_ms < 250,
             "per-keystroke input path took #{Float.round(per_keystroke_ms, 2)}ms against 20k candidates; expected bounded top-K to stay well under the 250ms catastrophe ceiling"
    end

    test "live preview still runs on_select for the applied result while typing a large set" do
      state = large_picker_state(LargePreviewSource, 10_000)

      typed = type_string(state, "config_module_1.ex")
      {:picker, %{picker_ui: %{picker: picker}}} = typed.shell_runtime.state.modal

      # Selection landed on a real match and preview applied on_select for it.
      assert Picker.selected_item(picker) != nil
      assert Map.get(typed, :previewed_id) == Picker.selected_id(picker)
    end

    test "mode switching is preserved when the first keystroke is a prefix in a large set" do
      # Behavior preservation: typing the command prefix `>` as the first char in
      # a switchable source still swaps sources even with a huge candidate list,
      # rather than being swallowed into a query refilter.
      state = large_file_picker_state(50_000)

      switched = PickerUI.handle_key(state, ?>, 0)
      {:picker, %{picker_ui: pui}} = switched.shell_runtime.state.modal

      assert pui.source == MingaEditor.UI.Picker.CommandSource
      assert pui.original_source == MingaEditor.UI.Picker.FileSource
      assert pui.mode_prefix == ">"
    end

    defp large_file_picker_state(item_count) do
      state = TestHelpers.base_state(content: "initial")

      items = for i <- 1..item_count, do: %Item{id: "file_#{i}.ex", label: "file_#{i}.ex"}
      picker = Picker.new(items, title: "Files", max_visible: 10)

      picker_state = %PickerState{
        picker: picker,
        source: MingaEditor.UI.Picker.FileSource,
        restore: state.workspace.buffers.active_index
      }

      ModalWorkflow.open(state, :picker, PickerPayload.new(picker_state))
    end
  end
end
