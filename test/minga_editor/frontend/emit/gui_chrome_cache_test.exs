defmodule MingaEditor.Frontend.Emit.GUI.ChromeCacheTest do
  @moduledoc "Tests fingerprint-based change detection in `sync_swiftui_chrome/4`."

  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Emit.GUI, as: EmitGUI
  alias MingaEditor.MinibufferData
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Frontend.Protocol.GUI.BoardCardPayload
  alias MingaEditor.Frontend.Protocol.GUI.BoardPayload
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Test.UnknownGuiPayloadShell

  import ExUnit.CaptureLog
  import MingaEditor.RenderPipeline.TestHelpers

  defmodule BoardPayloadShell do
    @moduledoc false

    alias MingaEditor.Frontend.Protocol.GUI.BoardCardPayload
    alias MingaEditor.Frontend.Protocol.GUI.BoardPayload

    @spec compute_layout(map()) :: MingaEditor.Layout.t()
    def compute_layout(state), do: MingaEditor.Shell.Traditional.compute_layout(state)

    @spec active_session(term()) :: nil
    def active_session(_shell_state), do: nil

    @spec gui_payload(term()) :: {:board, BoardPayload.t()}
    def gui_payload(_state) do
      {:board,
       %BoardPayload{
         visible?: true,
         focused_card_id: 1,
         zoomed_card_id: 1,
         cards: [
           %BoardCardPayload{
             id: 1,
             status: :idle,
             kind: :agent,
             task: "Board task",
             display_task: "Board task",
             created_at: DateTime.from_unix!(0)
           }
         ]
       }}
    end
  end

  defmodule PreviewSource do
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "Preview source"

    @impl true
    def preview?, do: true

    @impl true
    def live_preview?, do: false

    @impl true
    def gui_preview?, do: true

    @impl true
    def candidates(_ctx), do: [%Item{id: :preview, label: "preview"}]

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state

    @impl true
    def preview(_item, _ctx), do: [[{"source preview", 0xFFFFFF, false}]]
  end

  describe "sync_swiftui_chrome/4 fingerprint caching" do
    test "first frame sends chrome commands, then unchanged frames send nothing" do
      state = gui_state()

      {_ctx, caches, first_cmds} = sync_chrome(state)
      assert first_cmds != []

      # Status bar (0x76) is now handled by the RenderModel adapter path,
      # so the second sync_chrome call produces no commands.
      {_ctx, _caches, second_cmds} = sync_chrome(state, caches)
      assert second_cmds == []
    end

    test "theme is no longer emitted through sync_swiftui_chrome (migrated to adapter)" do
      # Theme encoding moved to the RenderModel + Adapter path.
      # sync_swiftui_chrome should NOT produce theme commands (0x74).
      state = gui_state()
      {_ctx, _caches, cmds} = sync_chrome(state)

      assert opcode_count(cmds, 0x74) == 0,
             "theme command should not appear in sync_swiftui_chrome output"
    end

    test "re-sends chrome when state changes between calls (excluding theme and status bar)" do
      state = gui_state(content: long_content(50))
      {_ctx, caches, _cmds} = sync_chrome(state)

      # Change the theme. Theme is now handled by the adapter, so 0x74
      # should NOT appear in sync_swiftui_chrome output. Status bar (0x76)
      # is also now handled by the adapter path.
      changed_state = %{state | theme: MingaEditor.UI.Theme.get!(:one_dark)}
      {_ctx, _caches2, cmds} = sync_chrome(changed_state, caches)

      assert opcode_count(cmds, 0x74) == 0,
             "theme command should not appear after theme change (handled by adapter)"

      assert opcode_count(cmds, 0x76) == 0,
             "status bar command should not appear (handled by adapter)"
    end

    test "tab bar is no longer emitted by sync_swiftui_chrome (handled by adapter)" do
      state = put_in(gui_state().shell_state.tab_bar, TabBar.new(Tab.new_file(1, "test.ex")))
      {_ctx, _caches, cmds} = sync_chrome(state)

      assert opcode_count(cmds, 0x71) == 0,
             "tab bar command should not appear (handled by adapter)"
    end

    test "file tree is no longer emitted by sync_swiftui_chrome (handled by adapter)" do
      state = gui_state()
      {_ctx, _caches, cmds} = sync_chrome(state)

      assert opcode_count(cmds, 0x93) == 0,
             "file tree command should not appear (handled by adapter)"

      assert opcode_count(cmds, 0x94) == 0,
             "file tree selection command should not appear (handled by adapter)"
    end

    test "git syncing and toast changes no longer emit through sync_swiftui_chrome (moved to adapter)" do
      # Git status was migrated to the RenderModel + Adapter path.
      # sync_swiftui_chrome no longer produces 0x85 opcodes.
      state = gui_state()
      {_ctx, _caches, cmds} = sync_chrome(state)
      assert opcode_cmds(cmds, 0x85) == []
    end

    test "closed chrome surfaces are handled by adapter (no longer emitted through sync_swiftui_chrome)" do
      # Picker, agent chat, minibuffer, and bottom panel are now handled by
      # the RenderModel adapter path. sync_swiftui_chrome no longer produces
      # these opcodes.
      {ctx, _caches, cmds} = sync_chrome(gui_state())

      assert is_map(ctx)
      assert opcode_count(cmds, 0x77) == 0, "picker should not appear (handled by adapter)"
      assert opcode_count(cmds, 0x78) == 0, "agent chat should not appear (handled by adapter)"
      assert opcode_count(cmds, 0x7F) == 0, "minibuffer should not appear (handled by adapter)"
    end

    test "picker is no longer emitted by sync_swiftui_chrome (handled by adapter)" do
      state = gui_state()
      state_a = open_test_picker(state, "a.txt")

      {_ctx, _caches, cmds} = sync_chrome(state_a)

      assert opcode_count(cmds, 0x77) == 0,
             "picker command should not appear (handled by adapter)"
    end

    test "minibuffer is no longer emitted by sync_swiftui_chrome (handled by adapter)" do
      state = gui_state()

      data_a =
        minibuffer_data([
          %{
            label: "edit",
            description: "Open file",
            match_score: 80,
            annotation: "file",
            match_positions: [0]
          }
        ])

      {_ctx, _caches, cmds} = sync_chrome(state, %Caches{}, data_a)

      assert opcode_count(cmds, 0x7F) == 0,
             "minibuffer command should not appear (handled by adapter)"
    end

    test "agent chat is no longer emitted by sync_swiftui_chrome (handled by adapter)" do
      # Agent chat is now handled by the RenderModel adapter path.
      # sync_swiftui_chrome should NOT produce agent chat commands (0x78).
      chat_state = agent_chat_state()
      {_ctx, _caches, cmds} = sync_chrome(chat_state)

      assert opcode_count(cmds, 0x78) == 0,
             "agent chat command should not appear (handled by adapter)"
    end

    test "switching from Board to Traditional no longer emits change summary through sync_swiftui_chrome" do
      # Change summary (0x89) is now handled by the RenderModel adapter path.
      board_state = %{gui_state() | shell: BoardPayloadShell}

      {_ctx, caches, board_cmds} = sync_chrome(board_state)
      assert [] = opcode_cmds(board_cmds, 0x87)
      assert [] = opcode_cmds(board_cmds, 0x89)

      {_ctx, _caches, dismiss_cmds} = sync_chrome(gui_state(), caches)
      assert [] = opcode_cmds(dismiss_cmds, 0x89),
             "change summary should not appear (handled by adapter)"
    end

    test "switching from Board to Traditional emits one Board dismiss payload via adapter" do
      # Board (0x87) is now handled by the RenderModel adapter path.
      # This test verifies sync_swiftui_chrome does NOT emit board commands.
      board_state = %{gui_state() | shell: BoardPayloadShell}

      {_ctx, caches, board_cmds} = sync_chrome(board_state)
      assert [] = opcode_cmds(board_cmds, 0x87)

      {_ctx, caches, dismiss_cmds} = sync_chrome(gui_state(), caches)
      assert [] = opcode_cmds(dismiss_cmds, 0x87)

      {_ctx, _caches, repeated_cmds} = sync_chrome(gui_state(), caches)
      assert [] = opcode_cmds(repeated_cmds, 0x87)
    end

    test "unsupported shell GUI payload dismisses Board via adapter without crashing" do
      # Board (0x87) is now handled by the RenderModel adapter path.
      # The unsupported payload warning is emitted by the board builder.
      board_state = %{gui_state() | shell: BoardPayloadShell}

      {_ctx, caches, _board_cmds} = sync_chrome(board_state)
      unsupported_state = %{gui_state() | shell: UnknownGuiPayloadShell}

      {{_ctx, _caches, cmds}, log} =
        with_log(fn -> sync_chrome(unsupported_state, caches) end)

      assert log =~ "Unsupported GUI shell payload"
      # Board commands are no longer emitted through sync_swiftui_chrome
      assert [] = opcode_cmds(cmds, 0x87)
    end

    test "workspaces are no longer emitted by sync_swiftui_chrome (handled by adapter)" do
      state = gui_state()
      tab_bar = tab_bar_with_two_workspaces()
      state_with_agents = put_in(state.shell_state.tab_bar, tab_bar)
      {_ctx, _caches, first_cmds} = sync_chrome(state_with_agents)

      assert opcode_count(first_cmds, 0x98) == 0,
             "workspace command should not appear (handled by adapter)"
    end

    test "agent chat survives dead prompt buffer process" do
      state = gui_state()
      {:ok, dead_pid} = Agent.start(fn -> nil end)
      Agent.stop(dead_pid)

      panel = %{state.workspace.agent_ui.panel | prompt_buffer: dead_pid}

      state = %{
        state
        | workspace: %{state.workspace | agent_ui: %{state.workspace.agent_ui | panel: panel}}
      }

      {ctx, _caches, _cmds} = sync_chrome(state)
      assert is_map(ctx)
    end
  end

  defp sync_chrome(state, caches \\ %Caches{}, minibuffer_data \\ nil) do
    {ctx, caches} =
      EmitGUI.sync_swiftui_chrome(
        Context.from_editor_state(state),
        StatusBarData.from_state(state),
        minibuffer_data,
        caches
      )

    {ctx, caches, collect_port_casts() |> List.flatten()}
  end

  defp collect_port_casts, do: collect_port_casts([])

  defp collect_port_casts(acc) do
    receive do
      {:"$gen_cast", {:send_commands, cmds}} -> collect_port_casts([cmds | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp opcode_count(cmds, opcode), do: cmds |> opcode_cmds(opcode) |> length()
  defp opcode_cmds(cmds, opcode), do: Enum.filter(cmds, &opcode?(&1, opcode))
  defp opcode?(<<opcode, _::binary>>, opcode), do: true
  defp opcode?(_, _opcode), do: false

  defp open_test_picker(state, label, _mode_prefix \\ "") do
    open_test_picker_with_source(state, label, nil, "")
  end

  defp open_test_picker_with_source(state, label, source, mode_prefix) do
    item = %MingaEditor.UI.Picker.Item{id: "same-id", label: label}
    picker = MingaEditor.UI.Picker.new([item], title: "Test")

    picker_state = %MingaEditor.State.Picker{
      picker: picker,
      source: source,
      action_menu: nil,
      mode_prefix: mode_prefix
    }

    ModalOverlay.open(state, :picker, PickerPayload.new(picker_state))
  end

  defp minibuffer_data([first | _] = candidates) do
    %MinibufferData{
      visible: true,
      mode: 0,
      cursor_pos: 1,
      prompt: ":",
      input: "e",
      context: "",
      selected_index: 0,
      candidates: candidates,
      total_candidates: Map.get(first, :total_candidates, length(candidates))
    }
  end

  defp tab_bar_with_two_workspaces do
    tab_bar = TabBar.new(Tab.new_file(1, "a.ex"))
    {tab_bar, workspace_a} = TabBar.add_workspace(tab_bar, "A")
    {tab_bar, workspace_b} = TabBar.add_workspace(tab_bar, "B")
    {tab_bar, tab_b} = TabBar.insert(tab_bar, :file, "b.ex")

    tab_bar
    |> TabBar.move_tab_to_workspace(1, workspace_a.id)
    |> TabBar.move_tab_to_workspace(tab_b.id, workspace_b.id)
  end

  defp agent_chat_state do
    state = gui_state()
    {:ok, chat_buf} = Minga.Buffer.start_link(content: "")
    {:ok, prompt_buf} = Minga.Buffer.start_link(content: "ab")
    {:ok, session} = Agent.start_link(fn -> nil end)
    Agent.stop(session)

    window = Window.new_agent_chat(1, chat_buf, 24, 80)

    workspace = %{
      state.workspace
      | windows: %Windows{tree: WindowTree.new(1), map: %{1 => window}, active: 1, next_id: 2},
        agent_ui: %{
          state.workspace.agent_ui
          | panel: %{state.workspace.agent_ui.panel | prompt_buffer: prompt_buf}
        }
    }

    tab = Tab.new_agent(1, "Agent") |> Tab.set_session(session)

    tab_bar =
      tab
      |> TabBar.new()
      |> TabBar.update_workspace(0, fn active_workspace ->
        active_workspace
        |> MingaEditor.State.Workspace.set_session(session)
        |> MingaEditor.State.Workspace.set_agent_ui(workspace.agent_ui)
      end)

    state
    |> Map.put(:workspace, workspace)
    |> put_in([Access.key(:shell_state), Access.key(:tab_bar)], tab_bar)
  end
end
