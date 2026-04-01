defmodule MingaEditor.Shell.Traditional.Chrome.TUITest do
  use ExUnit.Case, async: true

  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias Minga.Mode.CommandState
  alias Minga.Mode.OperatorPendingState
  alias Minga.Mode.VisualState
  alias MingaEditor.Shell.Traditional.Chrome.TUI, as: ChromeTUI

  import MingaEditor.RenderPipeline.TestHelpers

  defp run_through_content(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {_frames, cursor_info, state} = Content.build_content(state, scrolls)
    {scrolls, cursor_info, state, layout}
  end

  defp status_bar_text(chrome) do
    chrome.status_bar_draws
    |> Enum.sort_by(fn {row, col, _text, _face} -> {row, col} end)
    |> Enum.map_join(fn {_row, _col, text, _face} -> text end)
  end

  defp with_mode(state, mode, mode_state \\ nil) do
    vim = VimState.transition(state.workspace.editing, mode, mode_state)
    put_in(state.workspace.editing, vim)
  end

  defp with_tab_bar(state, tab_bar) do
    put_in(state.shell_state.tab_bar, tab_bar)
  end

  describe "Chrome.TUI.build/4" do
    test "returns a Chrome struct" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
    end

    test "tab bar field is a list (TUI renders tab bar)" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert is_list(chrome.tab_bar)
    end

    test "includes minibuffer draw" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.minibuffer
    end

    test "includes global status bar draws" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.status_bar_draws
    end

    test "includes region definitions" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert is_list(chrome.regions)
      assert Enum.all?(chrome.regions, &is_binary/1)
    end
  end

  # ── Status bar mode badges ──────────────────────────────────────────────

  describe "status bar mode badge" do
    test "shows NORMAL badge in normal mode" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert status_bar_text(chrome) =~ "NORMAL"
    end

    test "shows INSERT badge in insert mode" do
      state = base_state() |> with_mode(:insert)
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert status_bar_text(chrome) =~ "INSERT"
    end

    test "shows VISUAL badge in visual mode" do
      state = base_state() |> with_mode(:visual, %VisualState{visual_type: :char})
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert status_bar_text(chrome) =~ "VISUAL"
    end

    test "shows COMMAND badge in command mode" do
      state = base_state() |> with_mode(:command, %CommandState{input: "w"})
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert status_bar_text(chrome) =~ "COMMAND"
    end

    test "shows REPLACE badge in replace mode" do
      state = base_state() |> with_mode(:replace)
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert status_bar_text(chrome) =~ "REPLACE"
    end

    test "shows NORMAL badge in operator_pending mode (matches Vim convention)" do
      state =
        base_state() |> with_mode(:operator_pending, %OperatorPendingState{operator: :delete})

      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert status_bar_text(chrome) =~ "NORMAL"
    end
  end

  # ── Tab bar buffer names ────────────────────────────────────────────────

  describe "tab bar buffer names" do
    test "tab bar shows buffer name from tab bar state" do
      tab = Tab.new_file(1, "main.ex")
      tb = TabBar.new(tab)

      state = base_state() |> with_tab_bar(tb)
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      tab_text =
        chrome.tab_bar
        |> Enum.sort_by(fn {row, col, _text, _face} -> {row, col} end)
        |> Enum.map_join(fn {_row, _col, text, _face} -> text end)

      assert tab_text =~ "main.ex"
    end

    test "tab bar shows multiple buffer names" do
      tab1 = Tab.new_file(1, "one.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "two.ex")

      state = base_state() |> with_tab_bar(tb)
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      tab_text =
        chrome.tab_bar
        |> Enum.sort_by(fn {row, col, _text, _face} -> {row, col} end)
        |> Enum.map_join(fn {_row, _col, text, _face} -> text end)

      assert tab_text =~ "one.ex"
      assert tab_text =~ "two.ex"
    end
  end

  # ── Minibuffer in command mode ──────────────────────────────────────────

  describe "minibuffer in command mode" do
    test "minibuffer shows : prefix with command input" do
      state = base_state() |> with_mode(:command, %CommandState{input: "write"})
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      mb_text =
        chrome.minibuffer
        |> Enum.map_join(fn {_row, _col, text, _face} -> text end)

      assert mb_text =~ ":write"
    end
  end

  # ── Split window separators ─────────────────────────────────────────────

  describe "separators for split windows" do
    test "no separators for a single window" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert chrome.separators == []
    end

    test "vertical separators appear for a vertical split" do
      state = base_state()
      win_id = state.workspace.windows.active
      windows = state.workspace.windows
      new_id = windows.next_id

      {:ok, new_tree} = WindowTree.split(windows.tree, win_id, :vertical, new_id)
      new_window = Window.new(new_id, state.workspace.buffers.active, 24, 40)

      new_windows = %Windows{
        windows
        | tree: new_tree,
          map: Map.put(windows.map, new_id, new_window),
          next_id: new_id + 1
      }

      workspace = %{state.workspace | windows: new_windows}
      state = %{state | workspace: workspace}

      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.separators

      # Separator draws should contain the vertical separator character
      sep_text = Enum.map_join(chrome.separators, fn {_r, _c, text, _f} -> text end)
      assert String.contains?(sep_text, "│")
    end
  end
end
