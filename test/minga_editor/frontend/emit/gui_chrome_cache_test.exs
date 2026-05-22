defmodule MingaEditor.Frontend.Emit.GUI.ChromeCacheTest do
  @moduledoc "Tests fingerprint-based change detection in `sync_swiftui_chrome/4`."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer
  alias Minga.Project.FileTree
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Emit.GUI, as: EmitGUI
  alias MingaEditor.MinibufferData
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Shell.Board.State, as: BoardState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  import MingaEditor.RenderPipeline.TestHelpers

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

  @moduletag :tmp_dir

  describe "sync_swiftui_chrome/4 fingerprint caching" do
    test "first frame sends chrome commands, then unchanged frames send only status bar" do
      state = gui_state()

      {_ctx, caches, first_cmds} = sync_chrome(state)
      assert first_cmds != []

      {_ctx, _caches, second_cmds} = sync_chrome(state, caches)
      assert Enum.map(second_cmds, &opcode!/1) == [0x76]
    end

    test "theme fingerprint includes color content, not only theme name" do
      state = gui_state()
      {_ctx, caches, _cmds} = sync_chrome(state)
      theme = state.theme

      changed_theme = %{
        theme
        | editor: %{theme.editor | bg: Bitwise.bxor(theme.editor.bg, 0x000001)}
      }

      changed_state = %{state | theme: changed_theme}

      {_ctx, caches2, cmds} = sync_chrome(changed_state, caches)

      assert opcode_count(cmds, 0x74) == 1
      assert length(cmds) > 1
      refute caches2.last_gui_theme == caches.last_gui_theme
    end

    test "re-sends chrome when state changes between calls" do
      state = gui_state(content: long_content(50))
      {_ctx, caches, _cmds} = sync_chrome(state)

      changed_state = %{state | theme: MingaEditor.UI.Theme.get!(:one_dark)}
      {_ctx, _caches2, cmds} = sync_chrome(changed_state, caches)

      assert opcode_count(cmds, 0x74) == 1, "expected theme command after theme change"
      assert length(cmds) > 1, "expected more than just status bar after theme change"
    end

    test "tab bar cache changes when active buffer dirty state changes" do
      state = put_in(gui_state().shell_state.tab_bar, TabBar.new(Tab.new_file(1, "test.ex")))
      {_ctx, caches, _cmds} = sync_chrome(state)

      BufferProcess.insert_text(state.workspace.buffers.active, "!")

      {_ctx, _caches2, cmds} = sync_chrome(state, caches)

      assert Enum.any?(cmds, &match?(<<0x71, _::binary>>, &1)),
             "expected gui_tab_bar command after dirty state changes"
    end

    test "hidden file tree cache includes project root and resends when it changes" do
      first_root = "/tmp/first-project"
      second_root = "/tmp/second-project"

      first_state =
        gui_state()
        |> put_in(
          [Access.key(:workspace), Access.key(:file_tree), Access.key(:project_root)],
          first_root
        )

      {_ctx, caches, first_cmds} = sync_chrome(first_state)
      assert Enum.any?(first_cmds, &hidden_tree_cmd_for_root?(&1, first_root))
      assert caches.last_gui_file_tree_fp == {:no_tree, first_root}

      second_state =
        gui_state()
        |> put_in(
          [Access.key(:workspace), Access.key(:file_tree), Access.key(:project_root)],
          second_root
        )

      {_ctx, caches2, second_cmds} = sync_chrome(second_state, caches)

      assert Enum.any?(second_cmds, &hidden_tree_cmd_for_root?(&1, second_root))
      assert caches2.last_gui_file_tree_fp == {:no_tree, second_root}
    end

    test "ready file tree rows are cached, but diagnostics and selection changes emit targeted updates",
         %{tmp_dir: tmp_dir} do
      {state, file_tree, file_path} = ready_file_tree_state(tmp_dir, count: 300)

      {_ctx, caches, first_cmds} = sync_chrome(state)
      assert has_opcode?(first_cmds, 0x93)

      {_ctx, caches2, cached_cmds} = sync_chrome(state, caches)
      assert caches2.last_gui_file_tree_fp == caches.last_gui_file_tree_fp
      refute has_opcode?(cached_cmds, 0x93)

      moved_state =
        put_in(
          state.workspace.file_tree,
          FileTreeState.replace_tree(file_tree, FileTree.select(file_tree.tree, 42))
        )

      {_ctx, _caches3, moved_cmds} = sync_chrome(moved_state, caches)
      refute has_opcode?(moved_cmds, 0x93)
      assert opcode_count(moved_cmds, 0x94) == 1

      uri = SyncServer.path_to_uri(file_path)
      on_exit(fn -> Diagnostics.clear(:gui_file_tree_cache_test, uri) end)

      :ok =
        Diagnostics.publish(:gui_file_tree_cache_test, uri, [
          %Diagnostic{
            range: %{start_line: 0, start_col: 0, end_line: 0, end_col: 1},
            severity: :error,
            message: "boom"
          }
        ])

      {_ctx, _caches4, diagnostic_cmds} = sync_chrome(state, caches)
      assert has_opcode?(diagnostic_cmds, 0x93)
      refute has_opcode?(diagnostic_cmds, 0x94)
    end

    test "git syncing and toast changes re-send hidden git status command" do
      state = gui_state()
      {_ctx, caches, _cmds} = sync_chrome(state)

      syncing_state =
        state
        |> MingaEditor.State.set_git_toast(%{
          message: "Push failed: fetch first",
          level: :error,
          action: :pull_and_retry,
          dismiss_ref: make_ref()
        })
        |> Map.put(
          :git_remote_op,
          {make_ref(), make_ref(), {"/tmp/repo", "Pushed", "Push failed"}}
        )

      {_ctx, caches2, syncing_cmds} = sync_chrome(syncing_state, caches)

      assert [
               <<0x85, _repo_state::8, 1::8, _ahead::16, _behind::16, 0::16, 0::16, 1::8,
                 _level::8, 1::8, _msg_len::16, _msg::binary>>
             ] = opcode_cmds(syncing_cmds, 0x85)

      refute caches2.last_gui_git_status_fp == caches.last_gui_git_status_fp

      {_ctx, caches3, stopped_cmds} = sync_chrome(state, caches2)
      assert [<<0x85, _repo_state::8, 0::8, _rest::binary>>] = opcode_cmds(stopped_cmds, 0x85)
      refute caches3.last_gui_git_status_fp == caches2.last_gui_git_status_fp
    end

    test "closed chrome surfaces cache their not-visible state and return updated context" do
      {ctx, caches, _cmds} = sync_chrome(gui_state())

      assert caches.last_gui_picker_fp == :closed
      assert caches.last_gui_agent_chat_fp == :not_visible
      assert is_map(ctx)
      assert Map.has_key?(ctx, :message_store)
    end

    test "picker cache fingerprints open picker content" do
      state = gui_state()
      state_a = open_test_picker(state, "a.txt")
      state_b = open_test_picker(state, "b.txt")

      {_ctx, caches, _cmds} = sync_chrome(state_a)
      refute caches.last_gui_picker_fp in [:closed, nil]

      {_ctx, caches2, _cmds} = sync_chrome(state_b, caches)
      refute caches2.last_gui_picker_fp == caches.last_gui_picker_fp
    end

    test "picker cache fingerprints mode prefix changes" do
      state = gui_state()
      state_a = open_test_picker(state, "same.txt")
      state_b = open_test_picker(state, "same.txt", ">")

      {_ctx, caches, _cmds} = sync_chrome(state_a)
      {_ctx, caches2, _cmds} = sync_chrome(state_b, caches)

      refute caches2.last_gui_picker_fp == caches.last_gui_picker_fp
    end

    test "picker sync emits source-provided GUI preview content" do
      state = open_test_picker_with_source(gui_state(), "preview", PreviewSource)

      {_ctx, _caches, cmds} = sync_chrome(state)

      assert Enum.any?(cmds, &String.contains?(&1, "source preview"))
    end

    test "minibuffer cache changes when encoded candidate metadata changes" do
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

      {_ctx, caches, _cmds} = sync_chrome(state, %Caches{}, data_a)

      data_b =
        minibuffer_data([
          %{
            label: "edit",
            description: "Open file",
            match_score: 80,
            annotation: "buffer",
            match_positions: [1],
            total_candidates: 2
          }
        ])

      {_ctx, caches2, cmds} = sync_chrome(state, caches, data_b)

      assert has_opcode?(cmds, 0x7F)
      refute caches2.last_gui_minibuffer == caches.last_gui_minibuffer
    end

    test "workspace, agent chat, and board fingerprints include encoded content" do
      state = gui_state()
      tab_bar = tab_bar_with_two_workspaces()
      state_a = put_in(state.shell_state.tab_bar, tab_bar)
      {_ctx, caches, _cmds} = sync_chrome(state_a)
      [_, tab_b] = tab_bar.tabs
      state_b = put_in(state.shell_state.tab_bar, %{tab_bar | active_id: tab_b.id})
      {_ctx, caches2, _cmds} = sync_chrome(state_b, caches)
      refute caches2.last_gui_workspaces_fp == caches.last_gui_workspaces_fp

      chat_state = agent_chat_state()
      {_ctx, chat_caches, _cmds} = sync_chrome(chat_state)
      Minga.Buffer.move_to(chat_state.workspace.agent_ui.panel.prompt_buffer, {0, 1})
      {_ctx, chat_caches2, _cmds} = sync_chrome(chat_state, chat_caches)
      refute chat_caches2.last_gui_agent_chat_fp == chat_caches.last_gui_agent_chat_fp

      thinking_state = put_in(chat_state.workspace.agent_ui.panel.thinking_level, "high")
      {_ctx, chat_caches3, cmds} = sync_chrome(thinking_state, chat_caches2)

      assert [chat_cmd] = opcode_cmds(cmds, 0x78)
      assert <<0x78, _section_count::8, sections::binary>> = chat_cmd

      assert <<level_len::16, level::binary-size(level_len)>> =
               gui_agent_chat_section!(sections, 0x08)

      assert level == "high"
      refute chat_caches3.last_gui_agent_chat_fp == chat_caches2.last_gui_agent_chat_fp

      board = BoardState.new()
      {board_a, card} = BoardState.create_card(board, task: "Original task", status: :idle)
      board_state = %{gui_state() | shell: MingaEditor.Shell.Board, shell_state: board_a}
      {_ctx, board_caches, _cmds} = sync_chrome(board_state)
      board_b = BoardState.update_card(board_a, card.id, &%{&1 | task: "Updated task"})

      {_ctx, board_caches2, _cmds} =
        sync_chrome(%{board_state | shell_state: board_b}, board_caches)

      refute board_caches2.last_gui_board_fp == board_caches.last_gui_board_fp
    end

    test "workspace fingerprint updates when the last agent workspace disappears" do
      state = gui_state()
      tab_bar = tab_bar_with_two_workspaces()
      state_with_agents = put_in(state.shell_state.tab_bar, tab_bar)
      {_ctx, caches, first_cmds} = sync_chrome(state_with_agents)

      assert Enum.any?(first_cmds, &opcode?(&1, 0x98))
      assert caches.last_gui_workspaces_fp != nil

      tab_bar_without_agents =
        tab_bar
        |> TabBar.remove_workspace(1)
        |> TabBar.remove_workspace(2)

      state_without_agents = put_in(state.shell_state.tab_bar, tab_bar_without_agents)
      {_ctx, caches2, second_cmds} = sync_chrome(state_without_agents, caches)

      workspaces_cmd = Enum.find(second_cmds, &opcode?(&1, 0x98))
      assert <<0x98, payload_len::16, payload::binary-size(payload_len)>> = workspaces_cmd
      assert <<2::8, _active::16, _mode::8, _flags::8, 1::8, _rest::binary>> = payload
      assert caches2.last_gui_workspaces_fp != nil

      {_ctx, caches3, third_cmds} = sync_chrome(state_without_agents, caches2)
      refute Enum.any?(third_cmds, &opcode?(&1, 0x98))
      assert caches3.last_gui_workspaces_fp == caches2.last_gui_workspaces_fp
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

  defp has_opcode?(cmds, opcode), do: Enum.any?(cmds, &opcode?(&1, opcode))
  defp opcode_count(cmds, opcode), do: cmds |> opcode_cmds(opcode) |> length()
  defp opcode_cmds(cmds, opcode), do: Enum.filter(cmds, &opcode?(&1, opcode))
  defp opcode!(<<opcode, _::binary>>), do: opcode
  defp opcode?(<<opcode, _::binary>>, opcode), do: true
  defp opcode?(_, _opcode), do: false

  defp gui_agent_chat_section!(sections, target_id),
    do: do_gui_agent_chat_section!(sections, target_id)

  defp do_gui_agent_chat_section!(
         <<target_id::8, len::16, payload::binary-size(len), _rest::binary>>,
         target_id
       ),
       do: payload

  defp do_gui_agent_chat_section!(
         <<_id::8, len::16, _payload::binary-size(len), rest::binary>>,
         target_id
       ),
       do: do_gui_agent_chat_section!(rest, target_id)

  defp hidden_tree_cmd_for_root?(
         <<0x93, payload_len::32, payload::binary-size(payload_len)>>,
         root
       ) do
    root_len = byte_size(root)

    match?(
      <<2::8, tree_flags::8, 0::8, 0::16, ^root_len::16, ^root::binary-size(^root_len), 0::16,
        0::16, 0::16>>
      when Bitwise.band(tree_flags, 0x01) == 0,
      payload
    )
  end

  defp hidden_tree_cmd_for_root?(_cmd, _root), do: false

  defp ready_file_tree_state(tmp_dir, opts) do
    count = Keyword.fetch!(opts, :count)
    root = Path.join(tmp_dir, "gui-file-tree")
    File.mkdir_p!(root)

    for index <- 1..count do
      filename = "file_#{String.pad_leading(Integer.to_string(index), 3, "0")}.ex"
      File.write!(Path.join(root, filename), "")
    end

    file_path = Path.join(root, "file_001.ex")
    file_tree = FileTreeState.open(%FileTreeState{}, FileTree.new(root, width: 32), nil)
    state = gui_state() |> put_in([Access.key(:workspace), Access.key(:file_tree)], file_tree)
    {state, file_tree, file_path}
  end

  defp open_test_picker(state, label, mode_prefix \\ "") do
    open_test_picker_with_source(state, label, nil, mode_prefix)
  end

  defp open_test_picker_with_source(state, label, source, mode_prefix \\ "") do
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
