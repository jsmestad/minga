defmodule MingaEditor.Frontend.Emit.GUI.ChromeCacheTest do
  @moduledoc """
  Tests for fingerprint-based change detection in `sync_swiftui_chrome/4`.

  Verifies that unchanged chrome components are skipped on subsequent
  frames, and that changed components are re-sent. Inspects the returned
  `Caches` struct rather than the process dictionary.
  """

  use ExUnit.Case, async: true

  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer
  alias Minga.Project.FileTree
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.MinibufferData
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Emit.GUI, as: EmitGUI
  alias MingaEditor.Shell.Board.State, as: BoardState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.State.Windows

  import MingaEditor.RenderPipeline.TestHelpers

  defp flush_port_casts do
    receive do
      {:"$gen_cast", {:send_commands, _}} -> flush_port_casts()
    after
      0 -> :ok
    end
  end

  defp collect_port_casts do
    collect_port_casts([])
  end

  defp collect_port_casts(acc) do
    receive do
      {:"$gen_cast", {:send_commands, cmds}} -> collect_port_casts([cmds | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "sync_swiftui_chrome/4 fingerprint caching" do
    test "sends chrome commands on first call" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      casts = collect_port_casts()
      assert casts != [], "expected at least one port cast on first call"

      all_cmds = List.flatten(casts)
      assert all_cmds != []
    end

    test "skips unchanged chrome on second call with identical state" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      # First call: populates caches.
      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      # Second call with the same state and populated caches: only status bar should be sent.
      EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, caches)
      casts = collect_port_casts()

      assert length(casts) == 1, "expected exactly one port cast (status bar always sent)"

      all_cmds = List.flatten(casts)

      status_bar_cmds =
        Enum.filter(all_cmds, fn
          <<0x76, _::binary>> -> true
          _ -> false
        end)

      assert length(status_bar_cmds) == 1,
             "expected exactly one status bar command on unchanged second call"

      assert length(all_cmds) == 1,
             "expected only status bar command on second call, got #{length(all_cmds)} commands"
    end

    test "re-sends chrome when state changes between calls" do
      state = gui_state(content: long_content(50))
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      changed_state = %{state | theme: MingaEditor.UI.Theme.get!(:one_dark)}
      sb_data2 = StatusBarData.from_state(changed_state)

      EmitGUI.sync_swiftui_chrome(Context.from_editor_state(changed_state), sb_data2, nil, caches)
      casts = collect_port_casts()

      all_cmds = List.flatten(casts)

      theme_cmds =
        Enum.filter(all_cmds, fn
          <<0x74, _::binary>> -> true
          _ -> false
        end)

      assert length(theme_cmds) == 1, "expected theme command after theme change"
      assert length(all_cmds) > 1, "expected more than just status bar after theme change"
    end

    test "theme cache changes when same-name theme colors change" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      theme = state.theme

      changed_theme = %{
        theme
        | editor: %{theme.editor | bg: Bitwise.bxor(theme.editor.bg, 0x000001)}
      }

      changed_state = %{state | theme: changed_theme}

      {_ctx, caches2} =
        EmitGUI.sync_swiftui_chrome(
          Context.from_editor_state(changed_state),
          StatusBarData.from_state(changed_state),
          nil,
          caches
        )

      casts = collect_port_casts()
      all_cmds = List.flatten(casts)

      assert Enum.any?(all_cmds, &match?(<<0x74, _::binary>>, &1)),
             "expected gui_theme command when same-name colors change"

      refute caches2.last_gui_theme == caches.last_gui_theme
    end

    test "file tree cache key is populated after first call" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      caches0 = %Caches{}
      assert caches0.last_gui_file_tree_fp == nil

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, caches0)

      flush_port_casts()

      assert caches.last_gui_file_tree_fp == {:no_tree, ""}
    end

    test "hidden file tree command carries project root for shared GUI chrome" do
      root = "/tmp/minga-project"
      state = gui_state()
      state = put_in(state.workspace.file_tree.project_root, root)
      sb_data = StatusBarData.from_state(state)

      EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      all_cmds = collect_port_casts() |> List.flatten()
      root_len = byte_size(root)

      assert Enum.any?(all_cmds, fn
               <<0x93, payload_len::32, payload::binary-size(payload_len)>> ->
                 match?(
                   <<2::8, tree_flags::8, 0::8, 0::16, ^root_len::16,
                     ^root::binary-size(root_len), 0::16, 0::16, 0::16>>
                   when Bitwise.band(tree_flags, 0x01) == 0,
                   payload
                 )

               _ ->
                 false
             end)
    end

    test "hidden file tree cache resends when project root changes" do
      first_root = "/tmp/first-project"
      second_root = "/tmp/second-project"

      first_state = gui_state()
      first_state = put_in(first_state.workspace.file_tree.project_root, first_root)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(
          Context.from_editor_state(first_state),
          StatusBarData.from_state(first_state),
          nil,
          %Caches{}
        )

      flush_port_casts()

      second_state = gui_state()
      second_state = put_in(second_state.workspace.file_tree.project_root, second_root)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(
          Context.from_editor_state(second_state),
          StatusBarData.from_state(second_state),
          nil,
          caches
        )

      all_cmds = collect_port_casts() |> List.flatten()
      root_len = byte_size(second_root)

      assert caches.last_gui_file_tree_fp == {:no_tree, second_root}

      assert Enum.any?(all_cmds, fn
               <<0x93, payload_len::32, payload::binary-size(payload_len)>> ->
                 match?(
                   <<2::8, tree_flags::8, 0::8, 0::16, ^root_len::16,
                     ^second_root::binary-size(root_len), 0::16, 0::16, 0::16>>
                   when Bitwise.band(tree_flags, 0x01) == 0,
                   payload
                 )

               _ ->
                 false
             end)
    end

    test "ready large file trees reuse cached rows on the second frame" do
      root =
        Path.join(System.tmp_dir!(), "minga-gui-file-tree-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)

      for index <- 1..300 do
        filename = "file_#{String.pad_leading(Integer.to_string(index), 3, "0")}.ex"
        File.write!(Path.join(root, filename), "")
      end

      file_tree = FileTreeState.open(%FileTreeState{}, FileTree.new(root, width: 32), nil)

      state = gui_state()
      state = put_in(state.workspace.file_tree, file_tree)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(
          Context.from_editor_state(state),
          StatusBarData.from_state(state),
          nil,
          %Caches{}
        )

      first_cmds = collect_port_casts() |> List.flatten()
      assert Enum.any?(first_cmds, &match?(<<0x93, _::binary>>, &1))

      {_ctx, caches2} =
        EmitGUI.sync_swiftui_chrome(
          Context.from_editor_state(state),
          StatusBarData.from_state(state),
          nil,
          caches
        )

      second_cmds = collect_port_casts() |> List.flatten()

      assert caches2.last_gui_file_tree_fp == caches.last_gui_file_tree_fp
      refute Enum.any?(second_cmds, &match?(<<0x93, _::binary>>, &1))
    end

    test "ready file trees resend full GUI rows when diagnostics change" do
      root =
        Path.join(
          System.tmp_dir!(),
          "minga-gui-file-tree-diagnostics-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      file_path = Path.join(root, "alpha.ex")
      File.write!(file_path, "")

      uri = SyncServer.path_to_uri(file_path)

      on_exit(fn ->
        Diagnostics.clear(:gui_file_tree_cache_test, uri)
      end)

      file_tree = FileTreeState.open(%FileTreeState{}, FileTree.new(root, width: 32), nil)

      state = gui_state()
      state = put_in(state.workspace.file_tree, file_tree)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(
          Context.from_editor_state(state),
          StatusBarData.from_state(state),
          nil,
          %Caches{}
        )

      flush_port_casts()

      :ok =
        Diagnostics.publish(:gui_file_tree_cache_test, uri, [
          %Diagnostic{
            range: %{start_line: 0, start_col: 0, end_line: 0, end_col: 1},
            severity: :error,
            message: "boom"
          }
        ])

      {_ctx, _caches2} =
        EmitGUI.sync_swiftui_chrome(
          Context.from_editor_state(state),
          StatusBarData.from_state(state),
          nil,
          caches
        )

      cmds = collect_port_casts() |> List.flatten()

      assert Enum.any?(cmds, &match?(<<0x93, _::binary>>, &1))
      refute Enum.any?(cmds, &match?(<<0x94, _::binary>>, &1))
    end

    test "ready large file tree selection changes emit selection update without resending rows" do
      root =
        Path.join(
          System.tmp_dir!(),
          "minga-gui-file-tree-selection-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)

      for index <- 1..300 do
        filename = "file_#{String.pad_leading(Integer.to_string(index), 3, "0")}.ex"
        File.write!(Path.join(root, filename), "")
      end

      file_tree = FileTreeState.open(%FileTreeState{}, FileTree.new(root, width: 32), nil)

      state = gui_state()
      state = put_in(state.workspace.file_tree, file_tree)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(
          Context.from_editor_state(state),
          StatusBarData.from_state(state),
          nil,
          %Caches{}
        )

      flush_port_casts()

      moved_tree = FileTreeState.replace_tree(file_tree, FileTree.select(file_tree.tree, 42))
      moved_state = put_in(state.workspace.file_tree, moved_tree)

      {_ctx, _caches2} =
        EmitGUI.sync_swiftui_chrome(
          Context.from_editor_state(moved_state),
          StatusBarData.from_state(moved_state),
          nil,
          caches
        )

      second_cmds = collect_port_casts() |> List.flatten()

      refute Enum.any?(second_cmds, &match?(<<0x93, _::binary>>, &1))
      assert [<<0x94, _::binary>>] = Enum.filter(second_cmds, &match?(<<0x94, _::binary>>, &1))
    end

    test "git syncing and toast changes re-send hidden git status command" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      syncing_state =
        MingaEditor.State.set_git_toast(state, %{
          message: "Push failed: fetch first",
          level: :error,
          action: :pull_and_retry,
          dismiss_ref: make_ref()
        })

      syncing_state = %{
        syncing_state
        | git_remote_op: {make_ref(), make_ref(), {"/tmp/repo", "Pushed", "Push failed"}}
      }

      {_ctx, caches2} =
        EmitGUI.sync_swiftui_chrome(
          Context.from_editor_state(syncing_state),
          sb_data,
          nil,
          caches
        )

      git_status_cmds =
        for <<0x85, _::binary>> = cmd <- List.flatten(collect_port_casts()), do: cmd

      assert [
               <<0x85, _repo_state::8, 1::8, _ahead::16, _behind::16, 0::16, 0::16, 1::8,
                 _level::8, 1::8, _msg_len::16, _msg::binary>>
             ] = git_status_cmds

      refute caches2.last_gui_git_status_fp == caches.last_gui_git_status_fp
      flush_port_casts()

      {_ctx, caches3} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, caches2)

      stopped_cmds =
        for <<0x85, _::binary>> = cmd <- List.flatten(collect_port_casts()), do: cmd

      assert [<<0x85, _repo_state::8, 0::8, _rest::binary>>] = stopped_cmds
      refute caches3.last_gui_git_status_fp == caches2.last_gui_git_status_fp
    end

    test "picker cache tracks closed state" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      assert caches.last_gui_picker_fp == :closed
    end

    test "agent chat cache tracks not-visible state" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      assert caches.last_gui_agent_chat_fp == :not_visible
    end

    test "bottom panel returns updated context" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

      {ctx, _caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      assert is_map(ctx)
      assert Map.has_key?(ctx, :message_store)
    end

    test "picker cache fingerprints an open picker without crashing" do
      item = %MingaEditor.UI.Picker.Item{id: "a", label: "a.txt"}
      picker = MingaEditor.UI.Picker.new([item], title: "Test")
      state = gui_state()

      picker_state = %MingaEditor.State.Picker{picker: picker, source: nil, action_menu: nil}
      state = ModalOverlay.open(state, :picker, PickerPayload.new(picker_state))
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      refute caches.last_gui_picker_fp in [:closed, nil]
    end

    test "picker cache changes when visible item content changes" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)
      state_a = open_test_picker(state, "a.txt")

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state_a), sb_data, nil, %Caches{})

      flush_port_casts()

      state_b = open_test_picker(state, "b.txt")

      {_ctx, caches2} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state_b), sb_data, nil, caches)

      flush_port_casts()

      refute caches2.last_gui_picker_fp == caches.last_gui_picker_fp
    end

    test "minibuffer cache changes when encoded candidate metadata changes" do
      state = gui_state()
      sb_data = StatusBarData.from_state(state)

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

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, data_a, %Caches{})

      flush_port_casts()

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

      {_ctx, caches2} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, data_b, caches)

      casts = collect_port_casts()
      all_cmds = List.flatten(casts)

      assert Enum.any?(all_cmds, &match?(<<0x7F, _::binary>>, &1)),
             "expected gui_minibuffer command when encoded candidate metadata changes"

      refute caches2.last_gui_minibuffer == caches.last_gui_minibuffer
    end

    test "agent group cache changes when active group changes" do
      state = gui_state()
      tb = tab_bar_with_two_agent_groups()
      state_a = put_in(state.shell_state.tab_bar, tb)
      sb_data = StatusBarData.from_state(state_a)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state_a), sb_data, nil, %Caches{})

      flush_port_casts()

      [_, tab_b] = tb.tabs
      state_b = put_in(state.shell_state.tab_bar, %{tb | active_id: tab_b.id})

      {_ctx, caches2} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state_b), sb_data, nil, caches)

      flush_port_casts()

      refute caches2.last_gui_agent_groups_fp == caches.last_gui_agent_groups_fp
    end

    test "agent chat cache changes when prompt cursor moves without text changes" do
      state = agent_chat_state()
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      prompt = state.workspace.agent_ui.panel.prompt_buffer
      Minga.Buffer.move_to(prompt, {0, 1})

      {_ctx, caches2} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, caches)

      flush_port_casts()

      refute caches2.last_gui_agent_chat_fp == caches.last_gui_agent_chat_fp
    end

    test "board cache changes when encoded card content changes without status changes" do
      board = BoardState.new()
      {board_a, card} = BoardState.create_card(board, task: "Original task", status: :idle)
      state = %{gui_state() | shell: MingaEditor.Shell.Board, shell_state: board_a}
      sb_data = StatusBarData.from_state(state)

      {_ctx, caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      board_b = BoardState.update_card(board_a, card.id, &%{&1 | task: "Updated task"})
      state_b = %{state | shell_state: board_b}

      {_ctx, caches2} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state_b), sb_data, nil, caches)

      flush_port_casts()

      refute caches2.last_gui_board_fp == caches.last_gui_board_fp
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

      sb_data = StatusBarData.from_state(state)

      {ctx, _caches} =
        EmitGUI.sync_swiftui_chrome(Context.from_editor_state(state), sb_data, nil, %Caches{})

      flush_port_casts()

      assert is_map(ctx)
    end
  end

  defp open_test_picker(state, label) do
    item = %MingaEditor.UI.Picker.Item{id: "same-id", label: label}
    picker = MingaEditor.UI.Picker.new([item], title: "Test")
    picker_state = %MingaEditor.State.Picker{picker: picker, source: nil, action_menu: nil}
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

  defp tab_bar_with_two_agent_groups do
    tb = TabBar.new(Tab.new_file(1, "a.ex"))
    {tb, group_a} = TabBar.add_agent_group(tb, "A")
    {tb, group_b} = TabBar.add_agent_group(tb, "B")
    {tb, tab_b} = TabBar.insert(tb, :file, "b.ex")

    tb
    |> TabBar.move_tab_to_group(1, group_a.id)
    |> TabBar.move_tab_to_group(tab_b.id, group_b.id)
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
    tb = TabBar.new(tab)

    state
    |> Map.put(:workspace, workspace)
    |> put_in([Access.key(:shell_state), Access.key(:tab_bar)], tb)
  end
end
