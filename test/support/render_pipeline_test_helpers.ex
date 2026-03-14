defmodule Minga.Editor.RenderPipeline.TestHelpers do
  @moduledoc """
  Shared helpers for render pipeline stage tests.

  Provides `base_state/1` to construct a minimal `EditorState` with
  a single buffer window, suitable for testing individual pipeline stages.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.{Buffers, Highlighting, Windows}
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Input
  alias Minga.Theme

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
      viewport: Viewport.new(rows, cols),
      vim: VimState.new(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => window},
        active: win_id,
        next_id: win_id + 1
      },
      focus_stack: Input.default_stack(),
      theme: Theme.get!(:doom_one),
      highlight: %Highlighting{}
    }
  end
end
