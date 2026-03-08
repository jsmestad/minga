defmodule Minga.Editor.RenderPipelineTest do
  @moduledoc """
  Per-stage tests for the render pipeline.

  Each stage is tested independently with constructed inputs, verifying
  it can be called without running the full pipeline.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Frame, WindowFrame}
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.RenderPipeline.{Chrome, Invalidation, WindowScroll}
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.{Agent, Buffers, Highlighting, Windows}
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Input
  alias Minga.Mode
  alias Minga.Theme

  # ── Test helpers ───────────────────────────────────────────────────────────

  defp base_state(opts \\ []) do
    rows = Keyword.get(opts, :rows, 24)
    cols = Keyword.get(opts, :cols, 80)
    content = Keyword.get(opts, :content, "line one\nline two\nline three")
    {:ok, buf} = BufferServer.start_link(content: content)

    win_id = 1
    window = Window.new(win_id, buf, rows, cols)

    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(rows, cols),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => window},
        active: win_id,
        next_id: win_id + 1
      },
      focus_stack: Input.default_stack(),
      agent: %Agent{
        session: nil,
        status: nil,
        panel: %Minga.Agent.PanelState{
          visible: false,
          input_focused: false,
          input_text: "",
          scroll_offset: 0,
          spinner_frame: 0,
          provider_name: "anthropic",
          model_name: "claude-sonnet-4",
          thinking_level: "medium"
        },
        error: nil,
        spinner_timer: nil,
        buffer: nil
      },
      agentic: %Minga.Agent.View.State{
        active: false,
        focus: :chat,
        file_viewer_scroll: 0,
        saved_windows: nil,
        pending_prefix: nil,
        saved_file_tree: nil
      },
      theme: Theme.get!(:doom_one),
      highlight: %Highlighting{}
    }
  end

  # ── Stage 1: Invalidation ─────────────────────────────────────────────────

  describe "invalidate/2" do
    test "always returns full_redraw: true (stub)" do
      state = base_state()
      inv = RenderPipeline.invalidate(state)
      assert %Invalidation{full_redraw: true} = inv
    end

    test "accepts an optional previous frame" do
      state = base_state()
      prev = %Frame{cursor: {0, 0}, cursor_shape: :block}
      inv = RenderPipeline.invalidate(state, prev)
      assert %Invalidation{full_redraw: true} = inv
    end
  end

  # ── Stage 2: Layout ────────────────────────────────────────────────────────

  describe "compute_layout/1" do
    test "returns state with cached layout" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      new_state = RenderPipeline.compute_layout(state)
      layout = Layout.get(new_state)
      assert %Layout{} = layout
    end

    test "layout contains minibuffer and editor_area" do
      state = base_state(rows: 30, cols: 100)
      state = EditorState.sync_active_window_cursor(state)
      new_state = RenderPipeline.compute_layout(state)
      layout = Layout.get(new_state)

      {mr, _mc, mw, mh} = layout.minibuffer
      assert mr == 29
      assert mw == 100
      assert mh == 1

      {er, _ec, ew, eh} = layout.editor_area
      assert er == 0
      assert ew == 100
      assert eh == 29
    end
  end

  # ── Stage 3: Scroll ────────────────────────────────────────────────────────

  describe "scroll_windows/2" do
    test "returns a scroll result for each window" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)

      scrolls = RenderPipeline.scroll_windows(state, layout)

      assert map_size(scrolls) == 1
      [{_win_id, scroll}] = Map.to_list(scrolls)
      assert %WindowScroll{} = scroll
    end

    test "scroll result contains buffer lines" do
      state = base_state(content: "alpha\nbeta\ngamma")
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)

      scrolls = RenderPipeline.scroll_windows(state, layout)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert "alpha" in scroll.lines
      assert "beta" in scroll.lines
      assert "gamma" in scroll.lines
    end

    test "scroll result has correct cursor at line 0" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)

      scrolls = RenderPipeline.scroll_windows(state, layout)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert scroll.cursor_line == 0
      assert scroll.first_line == 0
      assert scroll.is_active == true
    end

    test "gutter_w is non-negative" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)

      scrolls = RenderPipeline.scroll_windows(state, layout)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert scroll.gutter_w >= 0
      assert scroll.content_w >= 1
    end
  end

  # ── Stage 4: Content ──────────────────────────────────────────────────────

  describe "build_content/2" do
    test "returns WindowFrames and cursor info" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      scrolls = RenderPipeline.scroll_windows(state, layout)

      {frames, cursor_info} = RenderPipeline.build_content(state, scrolls)

      assert [%WindowFrame{} | _] = frames
      assert {row, col} = cursor_info
      assert is_integer(row)
      assert is_integer(col)
    end

    test "WindowFrame contains gutter and line layers" do
      state = base_state(content: "hello world")
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      scrolls = RenderPipeline.scroll_windows(state, layout)

      {[wf], _cursor} = RenderPipeline.build_content(state, scrolls)

      # Lines layer should have at least one row
      assert map_size(wf.lines) >= 1
    end

    test "modeline layer is empty (Chrome handles modeline)" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      scrolls = RenderPipeline.scroll_windows(state, layout)

      {[wf], _cursor} = RenderPipeline.build_content(state, scrolls)

      assert wf.modeline == %{}
    end
  end

  # ── Stage 5: Chrome ────────────────────────────────────────────────────────

  describe "build_chrome/4" do
    test "returns a Chrome struct" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      scrolls = RenderPipeline.scroll_windows(state, layout)
      {_frames, cursor_info} = RenderPipeline.build_content(state, scrolls)

      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
    end

    test "chrome contains minibuffer draw" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      scrolls = RenderPipeline.scroll_windows(state, layout)
      {_frames, cursor_info} = RenderPipeline.build_content(state, scrolls)

      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.minibuffer
      assert Enum.all?(chrome.minibuffer, &is_tuple/1)
    end

    test "chrome contains modeline draws per window" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      scrolls = RenderPipeline.scroll_windows(state, layout)
      {_frames, cursor_info} = RenderPipeline.build_content(state, scrolls)

      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      assert map_size(chrome.modeline_draws) == 1
      [{_win_id, draws}] = Map.to_list(chrome.modeline_draws)
      assert [_ | _] = draws
    end

    test "chrome regions is a list of binaries" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      scrolls = RenderPipeline.scroll_windows(state, layout)
      {_frames, cursor_info} = RenderPipeline.build_content(state, scrolls)

      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      assert is_list(chrome.regions)
      assert Enum.all?(chrome.regions, &is_binary/1)
    end
  end

  # ── Stage 6: Compose ──────────────────────────────────────────────────────

  describe "compose_windows/4" do
    test "returns a Frame struct" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      scrolls = RenderPipeline.scroll_windows(state, layout)
      {frames, cursor_info} = RenderPipeline.build_content(state, scrolls)
      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      frame = RenderPipeline.compose_windows(frames, chrome, cursor_info, state)

      assert %Frame{} = frame
      assert is_tuple(frame.cursor)
      assert frame.cursor_shape in [:block, :beam, :underline]
    end

    test "frame windows have modeline injected" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      scrolls = RenderPipeline.scroll_windows(state, layout)
      {frames, cursor_info} = RenderPipeline.build_content(state, scrolls)
      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      frame = RenderPipeline.compose_windows(frames, chrome, cursor_info, state)

      # After compose, modeline should be populated
      [wf | _] = frame.windows
      assert map_size(wf.modeline) >= 1
    end

    test "frame includes chrome elements" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      scrolls = RenderPipeline.scroll_windows(state, layout)
      {frames, cursor_info} = RenderPipeline.build_content(state, scrolls)
      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      frame = RenderPipeline.compose_windows(frames, chrome, cursor_info, state)

      assert frame.minibuffer != []
      assert is_list(frame.regions)
    end
  end

  # ── Stage 7: Emit ─────────────────────────────────────────────────────────

  describe "emit/2" do
    test "converts frame to commands and sends to port_manager" do
      frame = %Frame{
        cursor: {0, 0},
        cursor_shape: :block,
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      assert :ok = RenderPipeline.emit(frame, state)

      # PortManager.send_commands sends a gen_cast to port_manager (self())
      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert is_list(commands)
      assert Enum.all?(commands, &is_binary/1)
    end
  end

  # ── Full pipeline integration ──────────────────────────────────────────────

  describe "run/1 (full pipeline)" do
    test "produces :ok for a normal editor state" do
      state = base_state()
      assert :ok = RenderPipeline.run(state)

      # PortManager.send_commands sends gen_cast to port_manager (self())
      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [_ | _] = commands
    end

    test "produces :ok for different viewport sizes" do
      for {rows, cols} <- [{10, 40}, {24, 80}, {50, 200}] do
        state = base_state(rows: rows, cols: cols)
        assert :ok = RenderPipeline.run(state)
        assert_receive {:"$gen_cast", {:send_commands, _}}
      end
    end
  end
end
