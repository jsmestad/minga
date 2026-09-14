defmodule MingaEditor.NativeIPC.Navigation do
  @moduledoc "Bounded semantic inspection and exact navigation for authenticated local clients."

  alias Minga.Buffer
  alias Minga.Buffer.InspectionSnapshot
  alias Minga.Core.PositionEncoding
  alias Minga.Frontend.Protocol.Encoding
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.NativeIPC.Identity
  alias MingaEditor.NativeIPC.NativePresentationObservation
  alias MingaEditor.NativeIPC.NavigationCommand
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Picker
  alias MingaEditor.State.Picker.ActivationOffer
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.TabWorkflow
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.Window
  alias MingaEditor.WindowFocus

  @max_tabs 8
  @max_panes 8
  @max_viewport_lines 8
  @max_line_bytes 256
  @default_choice_page 25
  @max_choice_page 25

  @type apply_failure ::
          :app_replaced
          | :core_replaced
          | :tab_not_found
          | :pane_not_found
          | :target_replaced
          | :buffer_unavailable
          | :buffer_replaced
          | :stale_revision
          | :line_out_of_range
          | :column_out_of_range
          | :column_not_boundary
          | :picker_not_open
          | :picker_replaced
          | :choice_not_found

  @type continuation_cursor ::
          :first
          | {:tabs, non_neg_integer()}
          | {:panes, pos_integer(), non_neg_integer()}
          | {:picker, non_neg_integer()}

  @doc "Returns the finite shipping semantic API and its coordinate and bounding contracts."
  @spec capabilities(Identity.t()) :: map()
  def capabilities(%Identity{} = identity) do
    %{
      "version" => 1,
      "type" => "capabilities",
      "app_instance_id" => identity.app_instance_id,
      "core_instance_id" => identity.core_instance_id,
      "commands" => [
        "capabilities",
        "inspect",
        "focus_pane",
        "select_tab",
        "goto_location",
        "activate_picker_choice",
        "operation_lookup",
        "operation_wait"
      ],
      "coordinates" => %{"line_base" => 1, "column_base" => 0, "column_encoding" => "utf-16"},
      "limits" => %{
        "maximum_frame_bytes" => 65_536,
        "maximum_tabs" => @max_tabs,
        "maximum_panes" => @max_panes,
        "maximum_viewport_lines_per_pane" => @max_viewport_lines,
        "default_picker_choice_page" => @default_choice_page,
        "maximum_picker_choice_page" => @max_choice_page
      },
      "receipt_outcomes" => [
        "ready",
        "applied",
        "rejected",
        "presentation_failed",
        "hidden",
        "unavailable",
        "superseded",
        "app_replaced",
        "core_replaced",
        "indeterminate"
      ]
    }
  end

  @doc "Returns a revision-scoped bounded inspection of authoritative BEAM state and native presentation evidence."
  @spec inspect(EditorState.t(), Identity.t(), String.t() | nil, pos_integer()) ::
          {:ok, map()}
          | {:error,
             :invalid_inspect_request
             | :invalid_continuation
             | :stale_continuation
             | :inspection_changed}
  def inspect(%EditorState{} = state, %Identity{} = identity, continuation, choice_limit)
      when (is_nil(continuation) or is_binary(continuation)) and is_integer(choice_limit) and
             choice_limit > 0 do
    inspect_consistent(state, identity, continuation, choice_limit, 2)
  end

  def inspect(%EditorState{}, %Identity{}, _continuation, _choice_limit),
    do: {:error, :invalid_inspect_request}

  @spec inspect_consistent(
          EditorState.t(),
          Identity.t(),
          String.t() | nil,
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, map()}
          | {:error, :invalid_continuation | :stale_continuation | :inspection_changed}
  defp inspect_consistent(state, identity, continuation, choice_limit, retries) do
    tab_bar = tab_bar(state)
    revision = inspection_revision(state, identity, tab_bar)

    with {:ok, cursor} <- continuation_cursor(continuation, revision),
         limit <- min(max(choice_limit, 1), @max_choice_page) do
      {tabs, pane_count, tabs_truncated?, panes_truncated?, continuations} =
        inspect_tabs(state, identity, tab_bar, revision, cursor)

      picker = inspect_picker(state, identity, revision, picker_offset(cursor), limit)

      inspection = %{
        "version" => 1,
        "type" => "inspection",
        "app_instance_id" => identity.app_instance_id,
        "core_instance_id" => identity.core_instance_id,
        "revision" => Integer.to_string(revision),
        "freshness" => %{
          "scope" => "core_instance",
          "continuation_revision" => Integer.to_string(revision)
        },
        "authoritative" => %{
          "active_tab_id" => active_tab_id(tab_bar),
          "active_pane_id" => state.workspace.windows.active,
          "tabs" => tabs,
          "picker" => picker
        },
        "presented" => presented_state(state),
        "continuations" => Map.put(continuations, "picker_choices", picker_continuation(picker)),
        "truncation" => %{
          "tabs" => tabs_truncated?,
          "panes" => panes_truncated?,
          "pane_count" => pane_count,
          "picker_choices" => picker_truncated?(picker)
        }
      }

      finish_consistent_inspection(
        inspection,
        state,
        identity,
        tab_bar,
        revision,
        continuation,
        choice_limit,
        retries
      )
    end
  end

  @doc "Validates and applies one semantic operation inside the serialized Editor owner."
  @spec apply(EditorState.t(), Identity.t(), NavigationCommand.t()) ::
          {:ok, EditorState.t(), :editor_visible_focused | :beam_applied}
          | {:error, apply_failure()}
  def apply(%EditorState{} = state, %Identity{} = identity, %NavigationCommand{} = command) do
    with :ok <- validate_identity(command, identity) do
      apply_command(state, identity, command)
    end
  end

  @doc "Returns a core-scoped opaque semantic token safe for JSON string transport."
  @spec token(Identity.t() | String.t(), atom(), [term()]) :: non_neg_integer()
  def token(%Identity{core_instance_id: core}, kind, parts), do: token(core, kind, parts)

  def token(core_instance_id, kind, parts) when is_binary(core_instance_id) and is_list(parts) do
    encoded = :erlang.term_to_binary({core_instance_id, kind, parts})
    <<value::unsigned-64, _rest::binary>> = :crypto.hash(:sha256, encoded)
    value
  end

  @spec apply_command(EditorState.t(), Identity.t(), NavigationCommand.t()) ::
          {:ok, EditorState.t(), :editor_visible_focused | :beam_applied}
          | {:error, apply_failure()}
  defp apply_command(state, identity, %NavigationCommand{kind: :select_tab} = command) do
    with {:ok, _tab} <- exact_tab(state, identity, command) do
      {:ok, TabWorkflow.switch(state, command.tab_id), :editor_visible_focused}
    end
  end

  defp apply_command(state, identity, %NavigationCommand{kind: :focus_pane} = command) do
    with {:ok, _window} <- exact_pane(state, identity, command),
         switched <- TabWorkflow.switch(state, command.tab_id),
         {:ok, focused} <- focus_exact(switched, command.pane_id) do
      {:ok, focused, :editor_visible_focused}
    end
  end

  defp apply_command(state, identity, %NavigationCommand{kind: :goto_location} = command) do
    with {:ok, buffer, staged_tab, staged_focus} <- prepare_goto(state, identity, command),
         {:ok, _position} <-
           Buffer.move_to_utf16_if_version(
             buffer,
             command.buffer_revision,
             command.line,
             command.column
           ) do
      committed =
        TabWorkflow.commit_staged_switch(
          staged_tab,
          WindowFocus.prepared_buffer_focus_state(staged_focus)
        )

      committed = WindowFocus.commit_prepared_buffer_focus(staged_focus, committed)

      {:ok, committed, :editor_visible_focused}
    else
      {:error, reason} -> normalize_goto_failure(reason)
    end
  end

  defp apply_command(
         state,
         identity,
         %NavigationCommand{kind: :activate_picker_choice} = command
       ) do
    with {:ok, picker_state} <- current_picker(state),
         :ok <- exact_picker(identity, command, picker_state),
         :ok <- exact_choice(command, picker_state) do
      action = picker_action(command)
      {:ok, GuiActionHandler.dispatch(state, action), :beam_applied}
    end
  end

  @spec prepare_goto(EditorState.t(), Identity.t(), NavigationCommand.t()) ::
          {:ok, pid(), term(), term()} | {:error, apply_failure() | :stale | :target_mismatch}
  defp prepare_goto(state, identity, command) do
    with {:ok, %Window{content: {:buffer, buffer}}} <- exact_pane(state, identity, command),
         :ok <- exact_buffer(identity, command, buffer),
         {:ok, _position} <-
           Buffer.resolve_utf16_position_if_version(
             buffer,
             command.buffer_revision,
             command.line,
             command.column
           ),
         staged_tab <- TabWorkflow.stage_switch(state, command.tab_id),
         {:ok, staged_focus} <-
           staged_tab
           |> TabWorkflow.staged_state()
           |> WindowFocus.prepare_buffer_focus_result(command.pane_id, buffer) do
      {:ok, buffer, staged_tab, staged_focus}
    end
  catch
    :exit, _reason -> {:error, :buffer_unavailable}
  end

  @spec normalize_goto_failure(atom()) :: {:error, apply_failure()}
  defp normalize_goto_failure(:stale), do: {:error, :stale_revision}
  defp normalize_goto_failure(:target_mismatch), do: {:error, :target_replaced}
  defp normalize_goto_failure(:window_not_found), do: {:error, :pane_not_found}
  defp normalize_goto_failure(:cursor_source_mismatch), do: {:error, :target_replaced}
  defp normalize_goto_failure(reason), do: {:error, reason}

  @spec validate_identity(NavigationCommand.t(), Identity.t()) ::
          :ok | {:error, :app_replaced | :core_replaced}
  defp validate_identity(
         %NavigationCommand{app_instance_id: app, core_instance_id: core},
         %Identity{app_instance_id: app, core_instance_id: core}
       ),
       do: :ok

  defp validate_identity(
         %NavigationCommand{app_instance_id: app},
         %Identity{app_instance_id: current_app}
       )
       when app != current_app,
       do: {:error, :app_replaced}

  defp validate_identity(%NavigationCommand{}, %Identity{}), do: {:error, :core_replaced}

  @spec exact_tab(EditorState.t(), Identity.t(), NavigationCommand.t()) ::
          {:ok, Tab.t()} | {:error, :tab_not_found | :target_replaced}
  defp exact_tab(state, identity, command) do
    with {:ok, tab} <- find_tab(tab_bar(state), command.tab_id) do
      if command.target_token == tab_token(identity, tab.id),
        do: {:ok, tab},
        else: {:error, :target_replaced}
    end
  end

  @spec exact_pane(EditorState.t(), Identity.t(), NavigationCommand.t()) ::
          {:ok, Window.t()} | {:error, :tab_not_found | :pane_not_found | :target_replaced}
  defp exact_pane(state, identity, command) do
    with {:ok, tab} <- exact_tab_with_pane_token(state, identity, command),
         %Windows{} = windows <- windows_for_tab(state, tab, active_tab_id(tab_bar(state))),
         {:ok, %Window{} = window} <- Windows.fetch(windows, command.pane_id),
         true <- command.target_token == pane_token(identity, tab.id, window) do
      {:ok, window}
    else
      nil -> {:error, :pane_not_found}
      :error -> {:error, :pane_not_found}
      false -> {:error, :target_replaced}
      {:error, _reason} = error -> error
    end
  end

  @spec exact_tab_with_pane_token(EditorState.t(), Identity.t(), NavigationCommand.t()) ::
          {:ok, Tab.t()} | {:error, :tab_not_found}
  defp exact_tab_with_pane_token(state, _identity, command),
    do: find_tab(tab_bar(state), command.tab_id)

  @spec find_tab(TabBar.t() | nil, Tab.id()) :: {:ok, Tab.t()} | {:error, :tab_not_found}
  defp find_tab(nil, _tab_id), do: {:error, :tab_not_found}

  defp find_tab(%TabBar{} = tab_bar, tab_id) do
    case TabBar.get(tab_bar, tab_id) do
      %Tab{} = tab -> {:ok, tab}
      nil -> {:error, :tab_not_found}
    end
  end

  @spec exact_buffer(Identity.t(), NavigationCommand.t(), pid()) ::
          :ok | {:error, :buffer_replaced | :stale_revision}
  defp exact_buffer(identity, command, buffer) do
    if command.buffer_id == buffer_id(identity, buffer),
      do: exact_buffer_revision(command, buffer),
      else: {:error, :buffer_replaced}
  catch
    :exit, _reason -> {:error, :buffer_replaced}
  end

  @spec exact_buffer_revision(NavigationCommand.t(), pid()) ::
          :ok | {:error, :stale_revision}
  defp exact_buffer_revision(command, buffer) do
    if command.buffer_revision == Buffer.version(buffer),
      do: :ok,
      else: {:error, :stale_revision}
  end

  @spec focus_exact(EditorState.t(), pos_integer()) ::
          {:ok, EditorState.t()} | {:error, apply_failure()}
  defp focus_exact(state, pane_id) do
    case WindowFocus.focus_result(state, pane_id) do
      {:ok, focused} -> {:ok, focused}
      {:error, :window_not_found} -> {:error, :pane_not_found}
      {:error, _reason} -> {:error, :target_replaced}
    end
  end

  @spec current_picker(EditorState.t()) :: {:ok, Picker.t()} | {:error, :picker_not_open}
  defp current_picker(%EditorState{
         shell_runtime: %{state: %{modal: {:picker, %PickerPayload{picker_ui: picker_state}}}}
       }),
       do: {:ok, picker_state}

  defp current_picker(%EditorState{}), do: {:error, :picker_not_open}

  @spec exact_picker(Identity.t(), NavigationCommand.t(), Picker.t()) ::
          :ok | {:error, :picker_replaced}
  defp exact_picker(identity, command, %Picker{activation_offer: offer}) do
    if command.target_token == picker_token(identity, offer.generation) and
         command.picker_generation == offer.generation,
       do: :ok,
       else: {:error, :picker_replaced}
  end

  @spec exact_choice(NavigationCommand.t(), Picker.t()) :: :ok | {:error, :choice_not_found}
  defp exact_choice(%NavigationCommand{choice_kind: :item} = command, picker_state) do
    case Picker.resolve_item_activation(
           picker_state,
           command.picker_generation,
           command.activation_id
         ) do
      {:ok, _index, %Item{}} -> :ok
      :error -> {:error, :choice_not_found}
    end
  end

  defp exact_choice(%NavigationCommand{choice_kind: :action} = command, picker_state) do
    case Picker.resolve_action_activation(
           picker_state,
           command.picker_generation,
           command.activation_id
         ) do
      {:ok, _action, %Item{}} -> :ok
      :error -> {:error, :choice_not_found}
    end
  end

  @spec picker_action(NavigationCommand.t()) :: tuple()
  defp picker_action(%NavigationCommand{choice_kind: :item} = command),
    do: {:picker_item_activate, command.picker_generation, command.activation_id}

  defp picker_action(%NavigationCommand{choice_kind: :action} = command),
    do: {:picker_action_activate, command.picker_generation, command.activation_id}

  @spec inspect_tabs(
          EditorState.t(),
          Identity.t(),
          TabBar.t() | nil,
          non_neg_integer(),
          continuation_cursor()
        ) :: {[map()], non_neg_integer(), boolean(), boolean(), map()}
  defp inspect_tabs(_state, _identity, nil, _revision, _cursor),
    do: {[], 0, false, false, %{"tabs" => nil, "panes" => %{}}}

  defp inspect_tabs(state, identity, %TabBar{} = tab_bar, revision, cursor) do
    active_id = active_tab_id(tab_bar)
    {visible_tabs, tab_offset} = visible_tabs(tab_bar.tabs, cursor)

    {tabs, pane_count, panes_truncated?, pane_continuations} =
      Enum.reduce(visible_tabs, {[], 0, false, %{}}, fn
        tab, {tabs, count, truncated?, continuations} ->
          remaining = max(@max_panes - count, 0)
          windows = windows_for_tab(state, tab, active_id)
          pane_offset = pane_offset(cursor, tab.id)

          {pane_maps, total_panes} =
            inspect_panes(
              identity,
              tab.id,
              windows,
              pane_offset,
              remaining,
              tab.id == active_id
            )

          next_pane_offset = pane_offset + length(pane_maps)
          pane_truncated? = next_pane_offset < total_panes

          pane_continuation =
            if pane_truncated?,
              do: encode_continuation(revision, :panes, tab.id, next_pane_offset),
              else: nil

          tab_map = %{
            "id" => tab.id,
            "target_token" => encode_token(tab_token(identity, tab.id)),
            "kind" => Atom.to_string(tab.kind),
            "label" => bounded_string(tab.label),
            "active" => tab.id == active_id,
            "active_pane_id" => active_pane_id(windows),
            "panes" => pane_maps,
            "panes_truncated" => pane_truncated?,
            "pane_continuation" => pane_continuation
          }

          continuations = Map.put(continuations, Integer.to_string(tab.id), pane_continuation)

          {
            [tab_map | tabs],
            count + length(pane_maps),
            truncated? or pane_truncated?,
            continuations
          }
      end)

    {tabs_truncated?, tab_continuation} =
      tab_continuation(cursor, tab_bar.tabs, tab_offset, length(visible_tabs), revision)

    {
      Enum.reverse(tabs),
      pane_count,
      tabs_truncated?,
      panes_truncated?,
      %{"tabs" => tab_continuation, "panes" => pane_continuations}
    }
  end

  @spec inspect_panes(
          Identity.t(),
          Tab.id(),
          Windows.t() | nil,
          non_neg_integer(),
          non_neg_integer(),
          boolean()
        ) ::
          {[map()], non_neg_integer()}
  defp inspect_panes(_identity, _tab_id, nil, _offset, _limit, _tab_active?), do: {[], 0}

  defp inspect_panes(identity, tab_id, %Windows{} = windows, offset, limit, tab_active?) do
    entries = windows.map |> Enum.sort_by(&elem(&1, 0))

    maps =
      entries
      |> Enum.slice(offset, limit)
      |> Enum.map(fn {_id, window} ->
        inspect_pane(identity, tab_id, windows.active, window, tab_active?)
      end)

    {maps, length(entries)}
  end

  @spec visible_tabs([Tab.t()], continuation_cursor()) :: {[Tab.t()], non_neg_integer()}
  defp visible_tabs(tabs, {:panes, tab_id, _offset}) do
    {Enum.filter(tabs, &(&1.id == tab_id)), 0}
  end

  defp visible_tabs(tabs, {:tabs, offset}),
    do: {Enum.slice(tabs, offset, @max_tabs), offset}

  defp visible_tabs(tabs, _cursor), do: {Enum.take(tabs, @max_tabs), 0}

  @spec pane_offset(continuation_cursor(), Tab.id()) :: non_neg_integer()
  defp pane_offset({:panes, tab_id, offset}, tab_id), do: offset
  defp pane_offset(_cursor, _tab_id), do: 0

  @spec tab_continuation(
          continuation_cursor(),
          [Tab.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {boolean(), String.t() | nil}
  defp tab_continuation({:panes, _tab_id, _pane_offset}, _tabs, _tab_offset, _count, _revision),
    do: {false, nil}

  defp tab_continuation(_cursor, tabs, offset, count, revision) do
    next_offset = offset + count
    truncated? = next_offset < length(tabs)
    continuation = if truncated?, do: encode_continuation(revision, :tabs, 0, next_offset)
    {truncated?, continuation}
  end

  @spec inspect_pane(Identity.t(), Tab.id(), pos_integer(), Window.t(), boolean()) :: map()
  defp inspect_pane(identity, tab_id, active_pane_id, %Window{} = window, tab_active?) do
    active? = window.id == active_pane_id
    {buffer, viewport} = inspect_window(identity, window, tab_active? and active?)

    %{
      "id" => window.id,
      "target_token" => encode_token(pane_token(identity, tab_id, window)),
      "active" => active?,
      "viewport" => viewport,
      "buffer" => buffer
    }
  end

  @spec inspect_window(Identity.t(), Window.t(), boolean()) :: {map(), map()}
  defp inspect_window(
         identity,
         %Window{content: {:buffer, buffer}, viewport: viewport} = window,
         active?
       ) do
    line_limit = min(max(viewport.rows - viewport.reserved, 1), @max_viewport_lines)
    cursor_source = if active?, do: :live, else: window.cursor
    snapshot = Buffer.inspection_snapshot(buffer, viewport.top, line_limit, cursor_source)

    {inspect_buffer(identity, buffer, snapshot),
     inspect_buffer_viewport(viewport, snapshot, line_limit)}
  catch
    :exit, _reason ->
      {%{"kind" => "buffer", "available" => false},
       %{"available" => false, "lines" => [], "truncated" => false}}
  end

  defp inspect_window(_identity, %Window{content: {kind, _value}, viewport: viewport}, _active?),
    do: {%{"kind" => Atom.to_string(kind)}, empty_viewport(viewport)}

  defp inspect_window(_identity, %Window{viewport: viewport}, _active?),
    do: {%{"kind" => "unknown"}, empty_viewport(viewport)}

  @spec inspect_buffer(Identity.t(), pid(), InspectionSnapshot.t()) :: map()
  defp inspect_buffer(identity, buffer, %InspectionSnapshot{} = snapshot) do
    {line, byte_column} = snapshot.cursor
    external = PositionEncoding.to_lsp({line, byte_column}, snapshot.cursor_line_text, :utf16)

    %{
      "kind" => "buffer",
      "id" => encode_token(buffer_id(identity, buffer)),
      "revision" => snapshot.version,
      "name" => bounded_string(snapshot.display_name),
      "path" => snapshot.file_path,
      "line_count" => snapshot.line_count,
      "cursor" => %{"line" => external["line"] + 1, "column" => external["character"]}
    }
  end

  @spec inspect_buffer_viewport(MingaEditor.Viewport.t(), InspectionSnapshot.t(), pos_integer()) ::
          map()
  defp inspect_buffer_viewport(viewport, snapshot, line_limit) do
    lines = snapshot.viewport_lines

    %{
      "start_line" => snapshot.viewport_start + 1,
      "left_column" => viewport.left,
      "lines" => Enum.map(lines, &bounded_line/1),
      "truncated" =>
        length(lines) == line_limit and snapshot.line_count > viewport.top + line_limit
    }
  end

  @spec empty_viewport(MingaEditor.Viewport.t()) :: map()
  defp empty_viewport(viewport) do
    %{
      "start_line" => viewport.top + 1,
      "left_column" => viewport.left,
      "lines" => [],
      "truncated" => false
    }
  end

  @spec inspect_picker(
          EditorState.t(),
          Identity.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) ::
          map() | nil
  defp inspect_picker(state, identity, revision, offset, limit) do
    case current_picker(state) do
      {:ok, %Picker{activation_offer: offer, picker: picker}} ->
        choices = picker_choices(offer)
        page = Enum.slice(choices, offset, limit)
        next_offset = offset + length(page)
        truncated? = next_offset < length(choices)

        %{
          "target_token" => encode_token(picker_token(identity, offer.generation)),
          "generation" => offer.generation,
          "title" => if(picker, do: bounded_string(picker.title), else: ""),
          "query" => if(picker, do: bounded_string(picker.query), else: ""),
          "choice_offset" => offset,
          "choices" => page,
          "truncated" => truncated?,
          "continuation" =>
            if(truncated?, do: encode_continuation(revision, :picker, 0, next_offset), else: nil)
        }

      {:error, :picker_not_open} ->
        nil
    end
  end

  @spec picker_offset(continuation_cursor()) :: non_neg_integer()
  defp picker_offset({:picker, offset}), do: offset
  defp picker_offset(_cursor), do: 0

  @spec picker_continuation(map() | nil) :: String.t() | nil
  defp picker_continuation(%{"continuation" => continuation}), do: continuation
  defp picker_continuation(nil), do: nil

  @spec picker_truncated?(map() | nil) :: boolean()
  defp picker_truncated?(%{"truncated" => truncated?}), do: truncated?
  defp picker_truncated?(nil), do: false

  @spec picker_choices(ActivationOffer.t()) :: [map()]
  defp picker_choices(offer) do
    items =
      Enum.map(ActivationOffer.offered_items(offer), fn {activation_id, _index, item} ->
        choice_map("item", activation_id, item)
      end)

    actions =
      Enum.map(ActivationOffer.offered_actions(offer), fn {activation_id, {label, _action}, item} ->
        action_label = bounded_string(label)
        choice_map("action", activation_id, item) |> Map.put("action", action_label)
      end)

    items ++ actions
  end

  @spec choice_map(String.t(), pos_integer(), Item.t()) :: map()
  defp choice_map(kind, activation_id, %Item{} = item) do
    %{
      "kind" => kind,
      "activation_id" => activation_id,
      "label" => bounded_string(item.label),
      "description" => bounded_string(item.description),
      "annotation" =>
        if(is_binary(item.annotation), do: bounded_string(item.annotation), else: nil),
      "active" => item.active
    }
  end

  @spec windows_for_tab(EditorState.t(), Tab.t(), Tab.id() | nil) :: Windows.t() | nil
  defp windows_for_tab(state, %Tab{id: id}, id), do: state.workspace.windows

  defp windows_for_tab(_state, %Tab{context: %TabContext{windows: windows}}, _active_id),
    do: windows

  @spec tab_bar(EditorState.t()) :: TabBar.t() | nil
  defp tab_bar(%EditorState{shell_runtime: runtime}) do
    case Runtime.state(runtime) do
      %TraditionalState{} = shell_state -> TraditionalState.tab_bar(shell_state)
      _other -> nil
    end
  end

  @spec active_tab_id(TabBar.t() | nil) :: Tab.id() | nil
  defp active_tab_id(%TabBar{active_id: id}), do: id
  defp active_tab_id(nil), do: nil

  @spec active_pane_id(Windows.t() | nil) :: pos_integer() | nil
  defp active_pane_id(%Windows{active: id}), do: id
  defp active_pane_id(nil), do: nil

  @spec tab_token(Identity.t(), Tab.id()) :: non_neg_integer()
  defp tab_token(identity, tab_id), do: token(identity, :tab, [tab_id])

  @spec pane_token(Identity.t(), Tab.id(), Window.t()) :: non_neg_integer()
  defp pane_token(identity, tab_id, %Window{} = window) do
    token(identity, :pane, [tab_id, window.id, window_content_identity(identity, window)])
  end

  @spec window_content_identity(Identity.t(), Window.t()) :: term()
  defp window_content_identity(identity, %Window{content: {:buffer, buffer}}),
    do: {:buffer, buffer_id(identity, buffer)}

  defp window_content_identity(_identity, %Window{content: content}), do: content

  @spec buffer_id(Identity.t(), pid()) :: non_neg_integer()
  defp buffer_id(identity, buffer), do: token(identity, :buffer, [inspect(buffer)])

  @spec picker_token(Identity.t(), pos_integer()) :: non_neg_integer()
  defp picker_token(identity, generation), do: token(identity, :picker, [generation])

  @spec inspection_revision(EditorState.t(), Identity.t(), TabBar.t() | nil) :: non_neg_integer()
  defp inspection_revision(state, identity, tab_bar) do
    tabs =
      case tab_bar do
        %TabBar{} = value ->
          Enum.map(value.tabs, fn tab ->
            windows = windows_for_tab(state, tab, value.active_id)
            {tab.id, tab.kind, tab.label, window_revision(identity, windows)}
          end)

        nil ->
          []
      end

    picker_generation =
      case current_picker(state) do
        {:ok, %Picker{activation_offer: offer}} -> offer.generation
        {:error, :picker_not_open} -> nil
      end

    render_revision =
      RenderCorrelation.latest_intent_revision(state.render.render_correlation)

    token(identity, :inspection, [
      render_revision,
      active_tab_id(tab_bar),
      tabs,
      picker_generation,
      state.frontend.native_presentation
    ])
  end

  @spec window_revision(Identity.t(), Windows.t() | nil) :: term()
  defp window_revision(_identity, nil), do: []

  defp window_revision(identity, %Windows{} = windows) do
    entries =
      windows.map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, window} ->
        {id, window_content_identity(identity, window), window.viewport, window.cursor,
         content_revision(window)}
      end)

    {windows.active, entries}
  end

  @spec content_revision(Window.t()) :: {non_neg_integer(), Minga.Buffer.position()} | nil
  defp content_revision(%Window{content: {:buffer, buffer}}) do
    Buffer.inspection_marker(buffer)
  catch
    :exit, _reason -> nil
  end

  defp content_revision(%Window{}), do: nil

  @spec continuation_cursor(String.t() | nil, non_neg_integer()) ::
          {:ok, continuation_cursor()}
          | {:error, :invalid_continuation | :stale_continuation}
  defp continuation_cursor(nil, _revision), do: {:ok, :first}

  defp continuation_cursor(continuation, revision) do
    with {:ok, decoded} <- Base.url_decode64(continuation, padding: false),
         [encoded_revision, scope, encoded_owner, encoded_offset] <- String.split(decoded, ":"),
         {parsed_revision, ""} <- Integer.parse(encoded_revision),
         {owner, ""} when owner >= 0 <- Integer.parse(encoded_owner),
         {offset, ""} when offset >= 0 <- Integer.parse(encoded_offset) do
      if parsed_revision == revision,
        do: decode_continuation_cursor(scope, owner, offset),
        else: {:error, :stale_continuation}
    else
      _failure -> {:error, :invalid_continuation}
    end
  end

  @spec decode_continuation_cursor(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, continuation_cursor()} | {:error, :invalid_continuation}
  defp decode_continuation_cursor("tabs", _owner, offset), do: {:ok, {:tabs, offset}}

  defp decode_continuation_cursor("panes", owner, offset) when owner > 0,
    do: {:ok, {:panes, owner, offset}}

  defp decode_continuation_cursor("picker", _owner, offset), do: {:ok, {:picker, offset}}
  defp decode_continuation_cursor(_scope, _owner, _offset), do: {:error, :invalid_continuation}

  @spec encode_continuation(
          non_neg_integer(),
          :tabs | :panes | :picker,
          non_neg_integer(),
          non_neg_integer()
        ) ::
          String.t()
  defp encode_continuation(revision, scope, owner, offset) do
    Base.url_encode64("#{revision}:#{scope}:#{owner}:#{offset}", padding: false)
  end

  @spec finish_consistent_inspection(
          map(),
          EditorState.t(),
          Identity.t(),
          TabBar.t() | nil,
          non_neg_integer(),
          String.t() | nil,
          pos_integer(),
          non_neg_integer()
        ) :: {:ok, map()} | {:error, :stale_continuation | :inspection_changed}
  defp finish_consistent_inspection(
         inspection,
         state,
         identity,
         tab_bar,
         revision,
         continuation,
         choice_limit,
         retries
       ) do
    case inspection_revision(state, identity, tab_bar) do
      ^revision ->
        {:ok, inspection}

      _changed when is_binary(continuation) ->
        {:error, :stale_continuation}

      _changed when retries > 0 ->
        inspect_consistent(state, identity, nil, choice_limit, retries - 1)

      _changed ->
        {:error, :inspection_changed}
    end
  end

  @spec presented_state(EditorState.t()) :: map()
  defp presented_state(%EditorState{
         frontend: %{native_presentation: %NativePresentationObservation{} = observation}
       }),
       do: NativePresentationObservation.to_map(observation)

  defp presented_state(%EditorState{} = state) do
    correlation = state.render.render_correlation

    %{
      "status" => "committed_not_native_observed",
      "latest_intent_revision" => RenderCorrelation.latest_intent_revision(correlation),
      "last_receipt_revision" => RenderCorrelation.last_receipt_revision(correlation),
      "last_receipt_frame_sequence" => RenderCorrelation.last_receipt_sequence(correlation),
      "native_focus" => "unknown"
    }
  end

  @spec bounded_line(String.t()) :: map()
  defp bounded_line(line) do
    bounded = bounded_string(line)
    %{"text" => bounded, "truncated" => byte_size(bounded) < byte_size(line)}
  end

  @spec bounded_string(String.t()) :: String.t()
  defp bounded_string(value) when byte_size(value) <= @max_line_bytes, do: value
  defp bounded_string(value), do: Encoding.utf8_prefix_bytes(value, @max_line_bytes)

  @spec encode_token(non_neg_integer()) :: String.t()
  defp encode_token(value), do: Integer.to_string(value)
end
