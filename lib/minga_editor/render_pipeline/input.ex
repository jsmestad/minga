defmodule MingaEditor.RenderPipeline.Input do
  @moduledoc """
  Renderer-local frame wrapper.

  The accepted Editor-to-Renderer value is `intent`. Materialization attaches only renderer-owned working values beside it: materialized windows, mutable frame-local workspace, caches, font registry, message store, layout, focus tree, and frame sequence.
  """

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FocusTree
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.WindowIntent
  alias MingaEditor.RenderPipeline.WorkspaceIntent
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.Panel.MessageStore

  @enforce_keys [:intent, :workspace, :windows, :caches, :font_registry, :message_store]
  defstruct [
    :intent,
    :workspace,
    :windows,
    :layout,
    :focus_tree,
    :caches,
    :font_registry,
    :message_store,
    :frame_seq
  ]

  @type t :: %__MODULE__{
          intent: Intent.t(),
          workspace: WorkspaceIntent.t(),
          windows: Windows.t(RenderWindow.t()),
          layout: Layout.t() | nil,
          focus_tree: FocusTree.t() | nil,
          caches: Caches.t(),
          font_registry: FontRegistry.t(),
          message_store: MessageStore.t(),
          frame_seq: non_neg_integer() | nil
        }

  @type workspace :: WorkspaceIntent.t()

  @spec from_intent(
          Intent.t(),
          Windows.t(RenderWindow.t()),
          Caches.t(),
          FontRegistry.t(),
          MessageStore.t()
        ) ::
          t()
  def from_intent(
        %Intent{} = intent,
        %Windows{} = windows,
        %Caches{} = caches,
        %FontRegistry{} = font_registry,
        %MessageStore{} = message_store
      ) do
    %__MODULE__{
      intent: intent,
      workspace: intent.workspace,
      windows: windows,
      layout: intent.frame.layout,
      focus_tree: intent.frame.focus_tree,
      caches: caches,
      font_registry: font_registry,
      message_store: message_store,
      frame_seq: nil
    }
    |> sync_active_window_cursor()
  end

  @spec from_editor_state(MingaEditor.State.t()) :: t()
  def from_editor_state(%MingaEditor.State{} = state) do
    intent = Intent.from_editor_state(state)

    windows =
      Map.new(intent.windows, fn {id, %WindowIntent{} = carrier} ->
        {id, WindowIntent.materialize(id, carrier, MingaEditor.Renderer.WindowCache.reset())}
      end)

    from_intent(
      intent,
      Windows.new(
        intent.window_layout.tree,
        intent.window_layout.active,
        intent.window_layout.next_id,
        windows
      ),
      %Caches{},
      FontRegistry.new(),
      intent.frame.message_store
    )
  end

  @spec file_tree_state(t()) :: FileTreeState.t()
  def file_tree_state(%__MODULE__{
        workspace: %WorkspaceIntent{file_tree: %FileTreeState{} = file_tree}
      }),
      do: file_tree

  def file_tree_state(%__MODULE__{}), do: %FileTreeState{}

  @spec record_render_window(t(), RenderWindow.id(), RenderWindow.t()) :: t()
  def record_render_window(
        %__MODULE__{windows: %Windows{} = windows} = input,
        id,
        %RenderWindow{} = window
      ) do
    %{input | windows: Windows.set_map(windows, Map.put(windows.map, id, window))}
  end

  @spec with_frame_seq(t(), non_neg_integer()) :: t()
  def with_frame_seq(%__MODULE__{} = input, frame_seq)
      when is_integer(frame_seq) and frame_seq >= 0,
      do: %{input | frame_seq: frame_seq}

  @spec with_layout(t(), Layout.t()) :: t()
  def with_layout(%__MODULE__{} = input, %Layout{} = layout), do: %{input | layout: layout}

  @spec with_focus_tree(t(), FocusTree.t()) :: t()
  def with_focus_tree(%__MODULE__{} = input, focus_tree), do: %{input | focus_tree: focus_tree}

  @spec refresh_focus_tree(t()) :: t()
  def refresh_focus_tree(%__MODULE__{} = input),
    do: with_focus_tree(input, FocusTree.from_state(input))

  @spec accept_emit_results(t(), Caches.t(), FontRegistry.t(), MessageStore.t()) :: t()
  def accept_emit_results(
        %__MODULE__{} = input,
        %Caches{} = caches,
        %FontRegistry{} = font_registry,
        %MessageStore{} = message_store
      ) do
    %{input | caches: caches, font_registry: font_registry, message_store: message_store}
  end

  @spec reset_frame_rows_rasterized(t()) :: t()
  def reset_frame_rows_rasterized(%__MODULE__{caches: caches} = input),
    do: %{input | caches: Caches.reset_frame_rows_rasterized(caches)}

  @spec add_frame_rows_rasterized(t(), non_neg_integer()) :: t()
  def add_frame_rows_rasterized(%__MODULE__{caches: caches} = input, count),
    do: %{input | caches: Caches.add_frame_rows_rasterized(caches, count)}

  @spec record_frame_render_path(t(), MingaEditor.RenderPipeline.Classifier.path()) :: t()
  def record_frame_render_path(%__MODULE__{caches: caches} = input, path),
    do: %{input | caches: Caches.record_frame_render_path(caches, path)}

  @spec record_chrome_result(t(), integer(), term()) :: t()
  def record_chrome_result(%__MODULE__{caches: caches} = input, fingerprint, chrome),
    do: %{input | caches: Caches.record_chrome_result(caches, fingerprint, chrome)}

  @spec record_content_decoration_caches(t(), term(), term(), term()) :: t()
  def record_content_decoration_caches(
        %__MODULE__{caches: caches} = input,
        search_cache,
        doc_highlight_cache,
        cmd_hover_link_cache
      ) do
    %{
      input
      | caches:
          Caches.record_content_decoration_caches(
            caches,
            search_cache,
            doc_highlight_cache,
            cmd_hover_link_cache
          )
    }
  end

  @spec record_agent_scroll_metrics(t(), non_neg_integer(), pos_integer()) :: t()
  def record_agent_scroll_metrics(
        %__MODULE__{workspace: %WorkspaceIntent{} = workspace} = input,
        total_lines,
        visible_height
      ) do
    %{
      input
      | workspace:
          WorkspaceIntent.record_agent_scroll_metrics(workspace, total_lines, visible_height)
    }
  end

  @spec with_font_registry(t(), FontRegistry.t()) :: t()
  def with_font_registry(%__MODULE__{} = input, %FontRegistry{} = font_registry) do
    %{input | font_registry: font_registry}
  end

  @spec chrome_fingerprint(t()) :: integer()
  def chrome_fingerprint(%__MODULE__{} = input) do
    buf = input.workspace.buffers.active
    chrome_fingerprint(input, buffer_fingerprint_data(buf))
  end

  @spec chrome_fingerprint(t(), map()) :: integer()
  def chrome_fingerprint(%__MODULE__{} = input, scrolls) when is_map(scrolls) do
    active = input.windows.active

    fingerprint_data =
      case Map.get(scrolls, active) do
        %{cursor_line: line, cursor_byte_col: col, snapshot: %{version: version}} ->
          {{line, col}, version}

        _ ->
          buffer_fingerprint_data(input.workspace.buffers.active)
      end

    chrome_fingerprint(input, fingerprint_data)
  end

  @spec chrome_fingerprint(t(), {{non_neg_integer(), non_neg_integer()}, non_neg_integer()}) ::
          integer()
  def chrome_fingerprint(%__MODULE__{} = input, {buf_cursor, buf_version}) do
    frame = input.intent.frame

    :erlang.phash2({
      input.workspace.buffers.active,
      buf_cursor,
      buf_version,
      frame.theme,
      status_bar_fingerprint(input),
      input.workspace.editing.mode,
      input.workspace.editing.mode_state,
      Sidebar.all(frame.sidebar_registry),
      input.workspace.file_tree,
      frame.terminal_viewport.rows,
      frame.terminal_viewport.cols,
      input.windows.tree,
      frame.notifications,
      frame.shell.chrome_fingerprint(input)
    })
  end

  @spec status_bar_fingerprint(t()) :: integer()
  defp status_bar_fingerprint(%__MODULE__{} = input) do
    :erlang.phash2(input.intent.frame.status_bar_data)
  end

  @spec buffer_fingerprint_data(pid() | nil) ::
          {{non_neg_integer(), non_neg_integer()}, non_neg_integer()}
  defp buffer_fingerprint_data(nil), do: {{0, 0}, 0}

  defp buffer_fingerprint_data(buf) when is_pid(buf) do
    {Minga.Buffer.cursor(buf), Minga.Buffer.version(buf)}
  catch
    :exit, _ -> {{0, 0}, 0}
  end

  @spec sync_active_window_cursor(t()) :: t()
  def sync_active_window_cursor(
        %__MODULE__{workspace: %WorkspaceIntent{buffers: %Buffers{active: nil}}} = input
      ),
      do: input

  def sync_active_window_cursor(
        %__MODULE__{
          windows: %Windows{map: windows, active: id} = window_set,
          workspace: %WorkspaceIntent{buffers: %Buffers{active: buf}}
        } = input
      ) do
    case Map.fetch(windows, id) do
      {:ok, %{content: {:buffer, ^buf}} = window} ->
        cursor = Minga.Buffer.cursor(buf)

        %{
          input
          | windows:
              Windows.set_map(
                window_set,
                Map.put(windows, id, RenderWindow.set_cursor(window, cursor))
              )
        }

      {:ok, _window} ->
        input

      :error ->
        input
    end
  catch
    :exit, _ -> input
  end
end
