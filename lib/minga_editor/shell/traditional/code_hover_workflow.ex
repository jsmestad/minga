defmodule MingaEditor.Shell.Traditional.CodeHoverWorkflow do
  @moduledoc "Opens one source-bound hover and admits documentation only to that same offer."

  alias Minga.Buffer
  alias Minga.Buffer.CursorContext
  alias Minga.Buffer.InspectionSnapshot
  alias Minga.Core.PositionEncoding, as: ExactPosition
  alias Minga.Diagnostics
  alias Minga.LSP.{Client, HoverContent, PositionEncoding, SyncServer}
  alias Minga.Log
  alias MingaEditor.{FocusTree, HoverPopup, Layout, Viewport, Window}
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.HoverPopup.Builder
  alias MingaEditor.Mouse.HitTest
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.{HoverPopupWorkflow, NoticeWorkflow}
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.Mouse
  alias MingaEditor.State.Tab

  @typedoc "Pane identity and committed view captured when pointer dwell begins."
  @type dwell_view :: {Tab.id() | nil, Window.id(), pid(), Viewport.t()}

  @doc "Captures the pane view the pointer actually occupied when its dwell started."
  @spec dwell_view(State.t(), integer(), integer(), TextEvent.t() | nil) :: dwell_view() | nil
  def dwell_view(state, _row, _col, %TextEvent{window_id: window}), do: pane_view(state, window)

  def dwell_view(state, row, col, nil) do
    case HitTest.resolve_buffer(state, row, col) do
      {:buffer, %{window_id: window}} -> pane_view(state, window)
      _outside -> nil
    end
  end

  @doc "Tests a dwell's captured pane without retargeting its original text observation."
  @spec dwell_current?(State.t(), dwell_view()) :: boolean()
  def dwell_current?(state, {tab, window, buffer, viewport}),
    do: view_current?(state, tab, window, buffer, viewport)

  @spec pane_view(State.t(), Window.id()) :: dwell_view() | nil
  defp pane_view(state, window) do
    case Map.get(state.workspace.windows.map, window) do
      %Window{content: {:buffer, buffer}, viewport: viewport} ->
        {active_tab(state), window, buffer, viewport}

      _other ->
        nil
    end
  end

  @spec open_cursor(State.t()) :: State.t()
  def open_cursor(%{workspace: %{buffers: %{active: nil}}} = state),
    do: NoticeWorkflow.publish(state, "No active buffer")

  def open_cursor(
        %{
          shell_runtime: %{
            state: %ShellState{modal: :none, act_menu: nil, whichkey: %{node: nil}}
          }
        } =
          state
      ) do
    case SessionState.active_window_struct(state.workspace) do
      %Window{id: window, content: {:buffer, buffer}, viewport: viewport} ->
        cursor = Buffer.cursor_context(buffer)
        anchor = FocusTree.cursor_screen_pos(state, Layout.get(state))

        source = %{
          trigger: :cursor,
          tab: active_tab(state),
          window: window,
          viewport: viewport,
          buffer: buffer,
          version: cursor.version,
          position: CursorContext.position(cursor),
          anchor: anchor,
          path: cursor.file_path
        }

        open_at(state, source, cursor.line_text)

      _no_buffer ->
        NoticeWorkflow.publish(state, "No active buffer")
    end
  catch
    :exit, _gone -> NoticeWorkflow.publish(state, "No hover information")
  end

  def open_cursor(state), do: state

  @spec open_pointer(State.t()) :: State.t()
  def open_pointer(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{focused: true}}}} = state
      ),
      do: state

  def open_pointer(
        %{
          shell_runtime: %{
            state: %ShellState{modal: :none, act_menu: nil, whichkey: %{node: nil}}
          }
        } =
          state
      ) do
    case pointer_source(state) do
      %{buffer: buffer, version: version, position: {line, _col}} = source ->
        if Buffer.version(buffer) == version do
          open_at(state, source, List.first(Buffer.lines(buffer, line, 1), ""))
        else
          state
        end

      nil ->
        state
    end
  catch
    :exit, _gone -> state
  end

  def open_pointer(state), do: state

  @spec finish(State.t(), reference(), pid(), {:ok, term()} | {:error, term()}) :: State.t()
  def finish(
        %{shell_runtime: %{state: %ShellState{hover_popup: %HoverPopup{} = popup}}} = state,
        ref,
        client,
        result
      ) do
    case popup.pending_code do
      {^ref, sections} ->
        source = popup.code_source

        if source_current?(state, source) do
          result = admit_provider_result(source.buffer, client, result)

          popup = HoverPopup.highlight_code(popup, server_range(result, source, client))
          finish_current(state, popup, source.trigger, sections, result)
        else
          HoverPopupWorkflow.dismiss(state)
        end

      _superseded ->
        state
    end
  end

  def finish(state, _ref, _client, _result), do: state

  @doc "Dismisses a code hover when an edit advances its source buffer past the displayed revision."
  @spec source_edited(State.t(), pid(), non_neg_integer() | nil) ::
          {:dismissed, State.t()} | :unchanged
  def source_edited(
        %{
          shell_runtime: %{
            state: %ShellState{
              hover_popup: %HoverPopup{code_source: %{buffer: buffer, version: shown}}
            }
          }
        } = state,
        buffer,
        version
      )
      when is_integer(version) and version > shown do
    {:dismissed, HoverPopupWorkflow.dismiss(state)}
  end

  def source_edited(_state, _buffer, _version), do: :unchanged

  @doc "Dismisses a code hover when its pane view or keyboard source position changes."
  @spec reconcile_source(State.t()) :: State.t()
  def reconcile_source(
        %{
          shell_runtime: %{state: %ShellState{hover_popup: %HoverPopup{code_source: source}}}
        } = state
      )
      when is_map(source) do
    if source_viewport_current?(state, source) and cursor_origin_current?(state, source),
      do: state,
      else: HoverPopupWorkflow.dismiss(state)
  end

  def reconcile_source(state), do: state

  @doc "Checks whether a code hover's captured source can still be acted on."
  @spec source_live?(State.t(), HoverPopup.code_source() | nil) :: boolean()
  def source_live?(_state, nil), do: true

  def source_live?(state, source) do
    if source_viewport_current?(state, source) do
      cursor = Buffer.cursor_context(source.buffer)

      cursor.version == source.version and cursor.file_path == source.path and
        cursor_matches?(state, source, CursorContext.position(cursor))
    else
      false
    end
  catch
    :exit, _gone -> false
  end

  @spec cursor_origin_current?(State.t(), HoverPopup.code_source()) :: boolean()
  defp cursor_origin_current?(_state, %{trigger: :pointer}), do: true

  defp cursor_origin_current?(state, %{trigger: :cursor} = source) do
    cursor_matches?(state, source, Buffer.cursor(source.buffer))
  catch
    :exit, _gone -> false
  end

  @spec cursor_matches?(State.t(), HoverPopup.code_source(), Buffer.position()) :: boolean()
  defp cursor_matches?(_state, %{trigger: :pointer}, _position), do: true

  defp cursor_matches?(state, %{trigger: :cursor, window: window, position: position}, position),
    do: state.workspace.windows.active == window

  defp cursor_matches?(_state, _source, _position), do: false

  @spec source_viewport_current?(State.t(), HoverPopup.code_source()) :: boolean()
  defp source_viewport_current?(state, source) do
    view_current?(state, source.tab, source.window, source.buffer, source.viewport)
  end

  @spec view_current?(State.t(), Tab.id() | nil, Window.id(), pid(), Viewport.t()) :: boolean()
  defp view_current?(state, tab, window, buffer, viewport) do
    case Map.get(state.workspace.windows.map, window) do
      %Window{content: {:buffer, ^buffer}, viewport: current} ->
        tab == active_tab(state) and same_visible_view?(viewport, current)

      _other ->
        false
    end
  end

  # A new limit from the renderer is not a change in what is visible.
  @spec same_visible_view?(Viewport.t(), Viewport.t()) :: boolean()
  defp same_visible_view?(before, after_view) do
    before.top == after_view.top and before.left == after_view.left and
      before.visual_row_offset == after_view.visual_row_offset and
      before.mixed_row_anchor == after_view.mixed_row_anchor and before.rows == after_view.rows and
      before.cols == after_view.cols and before.reserved == after_view.reserved
  end

  @spec open_at(State.t(), HoverPopup.code_source(), String.t()) :: State.t()
  defp open_at(state, source, line_text) do
    uri = source.path && SyncServer.path_to_uri(source.path)
    diagnostics = diagnostic_lines(uri, elem(source.position, 0))
    {attribution, action} = attribution(state, source)
    sections = {diagnostics, attribution}
    local_lines = Builder.local_code(sections)
    range = source_character(source.position, line_text)

    case request_docs(source, uri, line_text) do
      {:ok, ref, client} ->
        lines =
          if local_lines == [], do: [{[{"Loading hover…", :plain}], :text}], else: local_lines

        popup =
          lines
          |> code_popup(source, action)
          |> HoverPopup.highlight_code(range)
          |> HoverPopup.await_code(ref, sections)

        %{state | lsp: LSPState.track_hover_request(state.lsp, ref, client)}
        |> HoverPopupWorkflow.show(popup)

      :unavailable when local_lines == [] ->
        no_content(state, source.trigger, "No hover information")

      :unavailable ->
        popup = local_lines |> code_popup(source, action) |> HoverPopup.highlight_code(range)
        HoverPopupWorkflow.show(state, popup)
    end
  end

  @spec source_character(Buffer.position(), binary()) :: HoverPopup.code_range() | nil
  defp source_character({row, col} = start, text) when col < byte_size(text) do
    case String.next_grapheme(binary_part(text, col, byte_size(text) - col)) do
      {grapheme, _} -> {start, {row, col + byte_size(grapheme)}}
      nil -> nil
    end
  end

  defp source_character(_position, _text), do: nil

  @spec server_range({:ok, term()} | {:error, term()}, HoverPopup.code_source(), pid()) ::
          HoverPopup.code_range() | nil
  defp server_range(
         {:ok, %{"range" => %{"start" => first, "end" => last}}},
         source,
         client
       ) do
    encoding = Client.encoding(client)

    with {:ok, start} <- exact_endpoint(source, first, encoding),
         {:ok, stop} <- exact_endpoint(source, last, encoding) do
      if start <= source.position and source.position < stop, do: {start, stop}
    else
      :error -> nil
    end
  catch
    :exit, _gone -> nil
  end

  defp server_range(_result, _source, _client), do: nil

  @spec exact_endpoint(HoverPopup.code_source(), term(), PositionEncoding.encoding()) ::
          {:ok, Buffer.position()} | :error
  defp exact_endpoint(
         %{buffer: buffer, version: version, position: position},
         %{"line" => line, "character" => col},
         encoding
       )
       when is_integer(line) and line >= 0 and is_integer(col) and col >= 0 do
    with %InspectionSnapshot{version: ^version, line_count: count, viewport_lines: [text]}
         when line < count <- Buffer.inspection_snapshot(buffer, line, 1, position),
         {:ok, byte} <- ExactPosition.exact_byte_column(text, col, encoding) do
      {:ok, {line, byte}}
    else
      _invalid -> :error
    end
  end

  defp exact_endpoint(_source, _endpoint, _encoding), do: :error

  @spec code_popup(
          [MingaAgent.Markdown.parsed_line()],
          HoverPopup.code_source(),
          HoverPopup.open_action() | nil
        ) ::
          HoverPopup.t()
  defp code_popup(lines, %{anchor: {row, col}} = source, action) do
    popup = lines |> HoverPopup.from_parsed_lines(row, col) |> HoverPopup.bind_code(source)
    if action, do: HoverPopup.with_open_action(popup, action), else: popup
  end

  @spec attribution(State.t(), HoverPopup.code_source()) ::
          {[MingaAgent.Markdown.parsed_line()], HoverPopup.open_action() | nil}
  defp attribution(state, source) do
    case Buffer.attribution_at(source.buffer, source.position, source.version) do
      {{:minga, :untasked}, nil, at, review} when is_integer(at) ->
        {attribution_lines("Minga · no task", review, at), nil}

      {{:minga, _review_owner}, nil, nil, review} ->
        {attribution_lines("Minga · writing task unknown", review, nil), nil}

      {{:minga, task_id}, key, at, review} ->
        name = Tasks.title_for(state.agent_connection.tasks, task_id) || "Task #{task_id}"
        step = if key, do: Minga.Buffer.Author.step(key)

        {attribution_lines("Minga · #{name}", review, at), {:open_session, task_id, step}}

      nil ->
        {[], nil}
    end
  end

  @spec attribution_lines(String.t(), :unreviewed | :kept | :recorded, integer() | nil) ::
          [MingaAgent.Markdown.parsed_line()]
  defp attribution_lines(author, review, at) do
    [
      {[{author, :bold}], :text},
      {[{"#{review_label(review)} · #{edit_age(at)}", :plain}], :text}
    ]
  end

  @spec review_label(:unreviewed | :kept | :recorded) :: String.t()
  defp review_label(:unreviewed), do: "Unreviewed"
  defp review_label(:kept), do: "Kept"
  defp review_label(:recorded), do: "Review state unknown"

  @spec edit_age(integer() | nil) :: String.t()
  defp edit_age(nil), do: "Edit time unknown"

  defp edit_age(at) do
    seconds = div(max(System.system_time(:millisecond) - at, 0), 1_000)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  @spec diagnostic_lines(String.t() | nil, non_neg_integer()) :: [
          MingaAgent.Markdown.parsed_line()
        ]
  defp diagnostic_lines(nil, _line), do: []

  defp diagnostic_lines(uri, line) do
    case Diagnostics.on_line(uri, line) do
      [diagnostic | _] ->
        Enum.map(String.split(diagnostic.message, "\n"), fn text -> {[{text, :plain}], :text} end)

      [] ->
        []
    end
  end

  @spec request_docs(HoverPopup.code_source(), String.t() | nil, String.t()) ::
          {:ok, reference(), pid()} | :unavailable
  defp request_docs(_source, nil, _line_text), do: :unavailable

  defp request_docs(source, uri, line_text) do
    case SyncServer.clients_for_buffer(source.buffer) do
      [client | _] ->
        position = PositionEncoding.to_lsp(source.position, line_text, Client.encoding(client))
        params = %{"textDocument" => %{"uri" => uri}, "position" => position}
        {:ok, Client.request(client, "textDocument/hover", params), client}

      [] ->
        :unavailable
    end
  catch
    :exit, reason ->
      Log.debug(:lsp, "Could not request hover: #{inspect(reason)}")
      :unavailable
  end

  @spec source_current?(State.t(), HoverPopup.code_source()) :: boolean()
  defp source_current?(state, source) do
    source_live?(state, source) and same_position?(state, source)
  catch
    :exit, _gone -> false
  end

  @spec admit_provider_result(pid(), pid(), {:ok, term()} | {:error, term()}) ::
          {:ok, term()} | {:error, term()}
  defp admit_provider_result(buffer, client, result) do
    if match?([^client | _], SyncServer.clients_for_buffer(buffer)),
      do: result,
      else: {:error, :hover_provider_changed}
  catch
    :exit, _gone -> {:error, :hover_provider_changed}
  end

  @spec same_position?(State.t(), HoverPopup.code_source()) :: boolean()
  defp same_position?(state, %{trigger: :cursor, anchor: anchor}),
    do: FocusTree.cursor_screen_pos(state, Layout.get(state)) == anchor

  defp same_position?(state, %{trigger: :pointer} = source) do
    %{window: window, buffer: buffer, version: version, position: position, anchor: anchor} =
      source

    case pointer_source(state) do
      %{window: ^window, buffer: ^buffer, version: ^version, position: ^position, anchor: ^anchor} =
          current ->
        Map.get(current, :presentation) == Map.get(source, :presentation) and
          Map.get(current, :terminal_caret_row) == Map.get(source, :terminal_caret_row)

      _moved ->
        false
    end
  end

  @spec pointer_source(State.t()) :: HoverPopup.code_source() | nil
  defp pointer_source(state) do
    case Mouse.hover_sample(state.workspace.mouse) do
      %TextEvent{} = event ->
        presented_pointer_source(state, event, state.render.text_interaction_reader)

      {row, col} ->
        legacy_pointer_source(state, row, col)

      nil ->
        nil
    end
  end

  @spec presented_pointer_source(State.t(), TextEvent.t(), Reader.t() | nil) ::
          HoverPopup.code_source() | nil
  defp presented_pointer_source(_state, _event, nil), do: nil

  defp presented_pointer_source(state, event, reader) do
    with {:ok, %TextTarget{} = target} <- Reader.resolve(reader, event),
         %Window{content: {:buffer, buffer}, viewport: viewport} when buffer == target.buffer <-
           Map.get(state.workspace.windows.map, target.window_id) do
      %{
        trigger: :pointer,
        tab: active_tab(state),
        window: target.window_id,
        viewport: viewport,
        buffer: buffer,
        version: target.source_version,
        position: TextTarget.position(target),
        anchor: event.anchor,
        terminal_caret_row: event.terminal_caret_row,
        path: Buffer.file_path(buffer),
        presentation: event.presentation_id
      }
    else
      _ -> nil
    end
  end

  @spec legacy_pointer_source(State.t(), integer(), integer()) :: HoverPopup.code_source() | nil
  defp legacy_pointer_source(state, row, col) do
    with {:buffer, target} <- HitTest.resolve_buffer(state, row, col),
         %Window{viewport: viewport} <- Map.get(state.workspace.windows.map, target.window_id) do
      %{
        trigger: :pointer,
        tab: active_tab(state),
        window: target.window_id,
        viewport: viewport,
        buffer: target.buffer,
        version: Buffer.version(target.buffer),
        position: {target.line, target.col},
        anchor: {row, col},
        path: Buffer.file_path(target.buffer)
      }
    else
      _ -> nil
    end
  end

  @spec active_tab(State.t()) :: Tab.id() | nil
  defp active_tab(state) do
    case Runtime.active_tab(state.shell_runtime) do
      %Tab{id: id} -> id
      nil -> nil
    end
  end

  @spec finish_current(
          State.t(),
          HoverPopup.t(),
          :cursor | :pointer,
          HoverPopup.code_sections(),
          {:ok, term()} | {:error, term()}
        ) :: State.t()
  defp finish_current(state, popup, trigger, sections, {:ok, %{"contents" => contents}}) do
    docs = HoverContent.markdown(contents)

    if docs == "" do
      finish_lines(state, popup, trigger, Builder.local_code(sections), "No hover information")
    else
      {full, compact} = Builder.code_document(sections, docs, state.appearance.theme)
      HoverPopupWorkflow.show(state, HoverPopup.resolve_code(popup, full, compact))
    end
  end

  defp finish_current(state, popup, trigger, sections, {:error, error}) do
    Log.debug(:lsp, "Hover request failed: #{inspect(error)}")
    finish_lines(state, popup, trigger, Builder.local_code(sections), "Hover request failed")
  end

  defp finish_current(state, popup, trigger, sections, {:ok, _unavailable}) do
    finish_lines(state, popup, trigger, Builder.local_code(sections), "No hover information")
  end

  @spec finish_lines(
          State.t(),
          HoverPopup.t(),
          :cursor | :pointer,
          [MingaAgent.Markdown.parsed_line()],
          String.t()
        ) :: State.t()
  defp finish_lines(state, _popup, trigger, [], message), do: no_content(state, trigger, message)

  defp finish_lines(state, popup, _trigger, lines, _message) do
    HoverPopupWorkflow.show(state, HoverPopup.resolve_code(popup, lines))
  end

  @spec no_content(State.t(), :cursor | :pointer, String.t()) :: State.t()
  defp no_content(state, :cursor, message),
    do: state |> HoverPopupWorkflow.dismiss() |> NoticeWorkflow.publish(message)

  defp no_content(state, :pointer, _message), do: HoverPopupWorkflow.dismiss(state)
end
