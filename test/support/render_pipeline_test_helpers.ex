defmodule Minga.Editor.RenderPipeline.TestHelpers do
  @moduledoc """
  Shared helpers for render pipeline stage tests.

  Provides `base_state/1` to construct a minimal `EditorState` with
  a single buffer window, suitable for testing individual pipeline stages.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame, WindowFrame}
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.{Buffers, Highlighting, Windows}
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Input
  alias Minga.Frontend.Capabilities
  alias Minga.UI.Theme

  @doc """
  Constructs a minimal EditorState for pipeline stage tests.

  ## Options

  * `:rows` — viewport rows (default: 24)
  * `:cols` — viewport cols (default: 80)
  * `:content` — buffer content (default: "line one\\nline two\\nline three")
  """
  @spec base_state(keyword()) :: EditorState.t()
  def base_state(opts \\ []) do
    rows = Keyword.get(opts, :rows, 24)
    cols = Keyword.get(opts, :cols, 80)
    content = Keyword.get(opts, :content, "line one\nline two\nline three")
    {:ok, buf} = BufferServer.start_link(content: content)

    win_id = 1
    window = Window.new(win_id, buf, rows, cols)

    %EditorState{
      port_manager: self(),
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(rows, cols),
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => window},
          active: win_id,
          next_id: win_id + 1
        },
        highlight: %Highlighting{}
      },
      focus_stack: Input.default_stack(),
      theme: Theme.get!(:doom_one)
    }
  end

  @doc """
  Constructs a GUI-capable EditorState for pipeline stage tests.

  Same as `base_state/1` but with `frontend_type: :native_gui` capabilities.
  """
  @spec gui_state(keyword()) :: EditorState.t()
  def gui_state(opts \\ []) do
    state = base_state(opts)
    %{state | capabilities: %Capabilities{frontend_type: :native_gui}}
  end

  @doc """
  Generates content with `n` lines for testing scrolling and large buffers.
  """
  @spec long_content(pos_integer()) :: String.t()
  def long_content(n) do
    Enum.map_join(1..n, "\n", fn i -> "line #{i}: content here for testing" end)
  end

  @doc """
  Updates window tracking fields as if a render pass completed at the given
  viewport top. Ensures gutter_w and buf_version are consistent across frames.
  """
  @spec simulate_scroll(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def simulate_scroll(state, new_top) do
    win_id = state.workspace.windows.active
    window = Map.get(state.workspace.windows.map, win_id)

    updated_window = %{
      window
      | last_viewport_top: new_top,
        last_gutter_w: 4,
        last_buf_version: 1,
        last_line_count: 100,
        last_cursor_line: new_top
    }

    new_map = Map.put(state.workspace.windows.map, win_id, updated_window)
    put_in(state.workspace.windows.map, new_map)
  end

  @doc """
  Seeds the initial tracking state so the first frame has consistent values.
  Without this, the sentinel values (-1) cause spurious gutter-width mismatches.
  """
  @spec seed_state(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def seed_state(state, viewport_top) do
    simulate_scroll(state, viewport_top)
  end

  @doc """
  Builds a Frame with a single window for testing emit and content stages.
  """
  @spec build_frame_with_window(EditorState.t(), keyword()) :: Frame.t()
  def build_frame_with_window(state, opts) do
    viewport_top = Keyword.get(opts, :viewport_top, 0)
    layout = Layout.put(state) |> Layout.get()

    win_id = state.workspace.windows.active
    win_layout = Map.get(layout.window_layouts, win_id)
    {_row, _col, width, height} = win_layout.content

    content_draws =
      for row <- 0..(height - 1) do
        DisplayList.draw(
          row,
          4,
          "line #{viewport_top + row}: content",
          Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34)
        )
      end

    gutter_draws =
      for row <- 0..(height - 1) do
        DisplayList.draw(
          row,
          0,
          String.pad_leading("#{viewport_top + row + 1}", 3) <> " ",
          Minga.Core.Face.new(fg: 0x5B6268, bg: 0x282C34)
        )
      end

    win_frame = %WindowFrame{
      rect: {0, 0, width, height},
      gutter: DisplayList.draws_to_layer(gutter_draws),
      lines: DisplayList.draws_to_layer(content_draws),
      tilde_lines: %{},
      modeline: %{},
      cursor: nil
    }

    %Frame{
      cursor: Cursor.new(0, 4, :block),
      windows: [win_frame],
      minibuffer: [
        DisplayList.draw(height + 1, 0, " ", Minga.Core.Face.new(fg: 0xBBC2CF, bg: 0x282C34))
      ]
    }
  end
end
