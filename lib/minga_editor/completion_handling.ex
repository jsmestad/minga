defmodule MingaEditor.CompletionHandling do
  @moduledoc """
  Completion accept, filter, trigger, and dismiss logic.

  Handles both LSP completions (async, debounced) and config file
  completions (synchronous, from the Options registry). Extracted
  from `MingaEditor` to keep the GenServer module focused on
  orchestration. All functions are pure state transforms.
  """

  alias Minga.Buffer
  alias Minga.Buffer.CursorContext
  alias Minga.Config
  alias Minga.Editing.Completion
  alias Minga.Editing.Completion.Item
  alias Minga.Editing.Completion.ProviderBatch
  alias Minga.Editing.Completion.Session
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.SignatureHelpWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.SignatureHelp
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.Tab
  alias Minga.LSP.Client
  alias Minga.LSP.PositionEncoding
  alias Minga.LSP.SyncServer

  @resolve_debounce_ms 150

  @spec maybe_resolve_selected(EditorState.t()) :: EditorState.t()
  def maybe_resolve_selected(%{shell_runtime: %{state: %ShellState{}}} = state) do
    case ModalWorkflow.completion(state) do
      nil ->
        state

      completion ->
        do_maybe_resolve_selected(state, completion)
    end
  end

  def maybe_resolve_selected(state), do: state

  @spec do_maybe_resolve_selected(EditorState.t(), Completion.t()) :: EditorState.t()
  defp do_maybe_resolve_selected(state, completion) do
    item = Completion.selected_item(completion)
    maybe_schedule_resolve(state, completion, item)
  end

  @spec maybe_schedule_resolve(EditorState.t(), Completion.t(), Item.t() | nil) :: EditorState.t()
  defp maybe_schedule_resolve(state, _completion, nil), do: state

  defp maybe_schedule_resolve(state, _completion, %Item{raw: nil}), do: state

  defp maybe_schedule_resolve(state, _completion, %Item{documentation: documentation})
       when documentation != "",
       do: state

  defp maybe_schedule_resolve(state, completion, %Item{} = item) do
    trigger = ModalWorkflow.completion_trigger(state)

    case CompletionTrigger.session(trigger) do
      %Session{} -> schedule_session_resolve(state, completion, item, trigger)
      nil -> schedule_legacy_resolve(state, completion, item, trigger)
    end
  end

  @spec schedule_session_resolve(
          EditorState.t(),
          Completion.t(),
          Item.t(),
          CompletionTrigger.t()
        ) :: EditorState.t()
  defp schedule_session_resolve(state, completion, item, trigger) do
    timer =
      if state.frontend.backend != :headless do
        Process.send_after(
          self(),
          {:completion_resolve, session_id(trigger), CompletionTrigger.generation(trigger),
           item.provider_id, item.id},
          @resolve_debounce_ms
        )
      end

    case CompletionTrigger.begin_resolve(trigger, item, timer) do
      {:ok, trigger, _identity} ->
        state
        |> ModalWorkflow.put_completion_trigger(trigger)
        |> ModalWorkflow.update_completion(fn _ -> %{completion | resolve_timer: timer} end)

      :stale ->
        if is_reference(timer), do: Process.cancel_timer(timer)
        state
    end
  end

  @spec schedule_legacy_resolve(
          EditorState.t(),
          Completion.t(),
          Item.t(),
          CompletionTrigger.t()
        ) :: EditorState.t()
  defp schedule_legacy_resolve(state, completion, item, trigger) do
    if completion.resolve_timer, do: Process.cancel_timer(completion.resolve_timer)

    timer =
      if state.frontend.backend != :headless do
        Process.send_after(
          self(),
          {:completion_resolve, CompletionTrigger.generation(trigger), item.raw},
          @resolve_debounce_ms
        )
      end

    ModalWorkflow.update_completion(state, fn _ -> %{completion | resolve_timer: timer} end)
  end

  @spec flush_resolve(
          EditorState.t(),
          reference(),
          non_neg_integer(),
          Item.provider_id(),
          Item.id()
        ) :: EditorState.t()
  def flush_resolve(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        session_id,
        gen,
        provider_id,
        item_id
      ) do
    do_flush_resolve(state, session_id, gen, provider_id, item_id)
  end

  def flush_resolve(state, _session_id, _gen, _provider_id, _item_id), do: state

  @doc "Flushes a legacy positional completion resolve timer."
  @spec flush_resolve(EditorState.t(), non_neg_integer(), map()) :: EditorState.t()
  def flush_resolve(
        %{shell_runtime: %{state: %ShellState{}}, workspace: %{buffers: %{active: buf}}} = state,
        gen,
        raw_item
      ) do
    completion = ModalWorkflow.completion(state)
    trigger = ModalWorkflow.completion_trigger(state)

    if match?(%Completion{}, completion) and CompletionTrigger.generation(trigger) == gen and
         Completion.selected_raw?(completion, raw_item) do
      case {lsp_client_for(state, buf), buffer_value(buf, &Buffer.version/1)} do
        {client, version} when is_pid(client) and is_integer(version) and version >= 0 ->
          ref = Client.request(client, "completionItem/resolve", raw_item)
          track_legacy_completion_resolve_request(state, ref, client, buf, version, gen, raw_item)

        _ ->
          state
      end
    else
      state
    end
  end

  def flush_resolve(state, _gen, _raw_item), do: state

  @spec do_flush_resolve(
          EditorState.t(),
          reference(),
          non_neg_integer(),
          Item.provider_id(),
          Item.id()
        ) :: EditorState.t()
  defp do_flush_resolve(
         %{workspace: %{buffers: %{active: buf}}} = state,
         session_id,
         gen,
         provider_id,
         item_id
       ) do
    trigger = ModalWorkflow.completion_trigger(state)
    identity = {session_id, provider_id, item_id}

    if Minga.Editing.inserting?(state) do
      case CompletionTrigger.session(trigger) do
        %Session{id: ^session_id, generation: ^gen, selected_item_id: ^item_id} = session ->
          flush_resolve_request(state, trigger, session, identity, buf)

        _ ->
          state
      end
    else
      state
    end
  end

  @spec flush_resolve_request(
          EditorState.t(),
          CompletionTrigger.t(),
          Session.t(),
          Session.resolve_identity(),
          pid()
        ) :: EditorState.t()
  defp flush_resolve_request(state, trigger, session, identity, buf) do
    {_session_id, provider_id, item_id} = identity
    item = Session.find_item(session, item_id)

    case {resolve_client(session, provider_id), item, buffer_value(buf, &Buffer.version/1)} do
      {client, %Item{raw: raw_item}, version}
      when is_pid(client) and is_map(raw_item) and is_integer(version) and version >= 0 ->
        ref = Client.request(client, "completionItem/resolve", raw_item)

        case CompletionTrigger.track_resolve(trigger, identity, ref) do
          {:ok, trigger} ->
            state
            |> ModalWorkflow.put_completion_trigger(trigger)
            |> track_completion_resolve_request(
              {ref, client, buf, version, session.id, session.generation, provider_id, item_id,
               raw_item}
            )

          :stale ->
            Client.cancel_request(client, ref)
            state
        end

      _ ->
        state
    end
  end

  @spec handle_resolve_response(
          EditorState.t(),
          Session.resolve_identity(),
          reference(),
          {:ok, term()} | {:error, term()}
        ) ::
          EditorState.t()
  def handle_resolve_response(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        identity,
        request_ref,
        {:error, _error}
      ) do
    trigger = ModalWorkflow.completion_trigger(state)

    case CompletionTrigger.session(trigger) do
      %Session{} = session ->
        case Session.fail_resolve(session, identity, request_ref) do
          {:ok, session} ->
            install_resolve_session(state, trigger, session)

          :stale ->
            state
        end

      nil ->
        state
    end
  end

  def handle_resolve_response(state, _identity, _request_ref, {:error, _error}), do: state

  def handle_resolve_response(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        identity,
        request_ref,
        {:ok, resolved}
      ) do
    trigger = ModalWorkflow.completion_trigger(state)
    doc_text = extract_resolve_documentation(resolved)

    case CompletionTrigger.session(trigger) do
      %Session{} = session ->
        apply_resolved_item(state, trigger, session, identity, request_ref, doc_text)

      nil ->
        state
    end
  end

  def handle_resolve_response(state, _identity, _request_ref, {:ok, _resolved}), do: state

  @spec apply_resolved_item(
          EditorState.t(),
          CompletionTrigger.t(),
          Session.t(),
          Session.resolve_identity(),
          reference(),
          String.t()
        ) :: EditorState.t()
  defp apply_resolved_item(state, trigger, session, identity, request_ref, doc_text) do
    case Session.resolve_item(session, identity, request_ref, doc_text) do
      {:ok, session} -> install_resolved_item(state, trigger, session, identity, doc_text)
      :stale -> state
    end
  end

  @spec install_resolved_item(
          EditorState.t(),
          CompletionTrigger.t(),
          Session.t(),
          Session.resolve_identity(),
          String.t()
        ) :: EditorState.t()
  defp install_resolved_item(state, trigger, session, identity, doc_text) do
    {_session_id, _provider_id, item_id} = identity

    state
    |> ModalWorkflow.put_completion_trigger(CompletionTrigger.put_session(trigger, session))
    |> ModalWorkflow.update_completion(fn completion ->
      Completion.update_item_documentation(completion, item_id, doc_text)
    end)
  end

  @spec install_resolve_session(EditorState.t(), CompletionTrigger.t(), Session.t()) ::
          EditorState.t()
  defp install_resolve_session(state, trigger, session),
    do:
      ModalWorkflow.put_completion_trigger(state, CompletionTrigger.put_session(trigger, session))

  @doc "Applies a legacy completion resolve response by raw item identity."
  @spec handle_resolve_response(EditorState.t(), map(), {:ok, term()} | {:error, term()}) ::
          EditorState.t()
  def handle_resolve_response(state, _raw_item, {:error, _error}), do: state

  def handle_resolve_response(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        raw_item,
        {:ok, resolved}
      )
      when is_map(raw_item) do
    doc_text = extract_resolve_documentation(resolved)

    ModalWorkflow.update_completion(state, fn completion ->
      Completion.update_selected_documentation(completion, raw_item, doc_text)
    end)
  end

  def handle_resolve_response(state, _raw_item, {:ok, _resolved}), do: state

  @spec accept(EditorState.t(), Completion.t()) :: EditorState.t()
  def accept(state, completion) do
    case Completion.accept(completion) do
      nil ->
        dismiss(state)

      {:insert_text, text} ->
        state |> accept_text(completion, text) |> dismiss()

      {:text_edit, edit} ->
        state |> apply_completion_edit(edit) |> dismiss()
    end
  end

  @spec maybe_handle(EditorState.t(), boolean(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  def maybe_handle(
        %{shell_runtime: %{state: %MingaEditor.Shell.Traditional.State{}}} = state,
        was_inserting,
        codepoint,
        modifiers
      ) do
    if Minga.Editing.inserting?(state) and was_inserting do
      maybe_update(state, codepoint, modifiers)
    else
      state
      |> dismiss()
      |> SignatureHelpWorkflow.dismiss()
    end
  end

  def maybe_handle(state, _was_inserting, _codepoint, _modifiers), do: state

  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(%{shell_runtime: %{state: %ShellState{}}} = state) do
    if ModalOverlay.match(state.shell_runtime.state.modal, :completion) do
      state
      |> Map.update!(:lsp, &LSPState.drop_completion_requests/1)
      |> ModalWorkflow.dismiss()
    else
      state
    end
  end

  def dismiss(state), do: state

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec install_completion_tracking(EditorState.t(), [CompletionTrigger.tracking_fact()]) ::
          EditorState.t()
  def install_completion_tracking(state, []), do: state

  def install_completion_tracking(state, facts) do
    state = %{state | lsp: LSPState.drop_completion_requests(state.lsp)}

    Enum.reduce(facts, state, fn
      {_ref, _role, _provider_id, _client, _buffer, _version, _session_id, _gen, _pos} =
          fact,
      state ->
        %{
          state
          | lsp: LSPState.track_completion_result_request(state.lsp, fact)
        }
    end)
  end

  @spec track_completion_resolve_request(EditorState.t(), LSPState.resolve_tracking_fact()) ::
          EditorState.t()
  defp track_completion_resolve_request(state, fact) do
    %{
      state
      | lsp: LSPState.track_completion_resolve_request(state.lsp, fact)
    }
  end

  @spec track_legacy_completion_resolve_request(
          EditorState.t(),
          reference(),
          pid(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          map()
        ) :: EditorState.t()
  defp track_legacy_completion_resolve_request(
         state,
         ref,
         client,
         buffer,
         version,
         gen,
         raw_item
       ) do
    %{
      state
      | lsp:
          LSPState.track_completion_resolve_request(
            state.lsp,
            ref,
            client,
            buffer,
            version,
            gen,
            raw_item
          )
    }
  end

  @spec track_signature_help_request(
          EditorState.t(),
          reference(),
          pid(),
          pid(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()}
        ) :: EditorState.t()
  defp track_signature_help_request(state, ref, client, buffer, version, cursor) do
    %{
      state
      | lsp:
          LSPState.track_signature_help_request(state.lsp, ref, client, buffer, version, cursor)
    }
  end

  @spec accept_text(EditorState.t(), Completion.t(), String.t()) :: EditorState.t()
  defp accept_text(%{workspace: %{buffers: %{active: buf}}} = state, completion, text)
       when is_pid(buf) do
    {trigger_line, trigger_col} = completion.trigger_position
    %CursorContext{line: cursor_line, byte_column: cursor_col} = Buffer.cursor_context(buf)

    if cursor_line == trigger_line and cursor_col > trigger_col do
      Buffer.apply_edit(buf, trigger_line, trigger_col, cursor_line, cursor_col, text)
    else
      Buffer.insert_text(buf, text)
    end

    # Buffer.Process now broadcasts :buffer_changed with delta from record_edit
    state
  end

  defp accept_text(state, _completion, _text), do: state

  @spec apply_completion_edit(EditorState.t(), Completion.text_edit()) :: EditorState.t()
  defp apply_completion_edit(%{workspace: %{buffers: %{active: buf}}} = state, edit)
       when is_pid(buf) do
    Buffer.apply_edit(
      buf,
      edit.range.start_line,
      edit.range.start_col,
      edit.range.end_line,
      edit.range.end_col,
      edit.new_text
    )

    # Buffer.Process now broadcasts :buffer_changed with delta from record_edit
    state
  end

  defp apply_completion_edit(state, _edit), do: state

  @spec maybe_update(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  defp maybe_update(state, codepoint, _mods) do
    buf = state.workspace.buffers.active
    if buf == nil, do: state, else: do_update(state, buf, codepoint)
  end

  @spec do_update(EditorState.t(), pid(), non_neg_integer()) :: EditorState.t()
  defp do_update(state, buf, codepoint) do
    case buffer_value(buf, &Buffer.cursor_context/1) do
      %CursorContext{} = context -> do_update(state, buf, context, codepoint)
      :stale -> state
    end
  end

  @spec do_update(EditorState.t(), pid(), CursorContext.t(), non_neg_integer()) :: EditorState.t()
  defp do_update(state, buf, context, codepoint) do
    state = update_filter(state, context)

    state =
      case config_completion_context(context) do
        :none ->
          maybe_trigger(state, buf, context, codepoint)

        config_context ->
          maybe_trigger_config_completion(state, context, config_context)
      end

    maybe_trigger_signature_help(state, buf, context, codepoint)
  end

  @spec update_filter(EditorState.t(), CursorContext.t()) :: EditorState.t()
  defp update_filter(state, context) do
    case ModalWorkflow.completion(state) do
      nil ->
        state

      %Completion{} = completion ->
        prefix = completion_prefix(context, completion.trigger_position)
        apply_filter(state, completion, prefix)
    end
  end

  @spec apply_filter(EditorState.t(), Completion.t(), String.t() | nil) :: EditorState.t()
  defp apply_filter(state, _completion, nil), do: dismiss(state)
  defp apply_filter(state, _completion, ""), do: dismiss(state)

  defp apply_filter(state, completion, prefix) do
    filtered = Completion.filter(completion, prefix)

    if Completion.active?(filtered) do
      ModalWorkflow.update_completion(state, fn _ -> filtered end)
    else
      retain_retriggerable_completion(state, filtered)
    end
  end

  @spec retain_retriggerable_completion(EditorState.t(), Completion.t()) :: EditorState.t()
  defp retain_retriggerable_completion(state, filtered) do
    if CompletionTrigger.retriggerable?(ModalWorkflow.completion_trigger(state)) do
      ModalWorkflow.update_completion(state, fn _ -> filtered end)
    else
      dismiss(state)
    end
  end

  @spec maybe_trigger(EditorState.t(), pid(), CursorContext.t(), non_neg_integer()) ::
          EditorState.t()
  defp maybe_trigger(state, buf, context, codepoint) do
    case codepoint_to_char(codepoint) do
      nil ->
        state

      char ->
        bridge = ModalWorkflow.completion_trigger(state)
        {new_bridge, facts} = trigger_for_completion(state, bridge, char, buf, context)

        state
        |> ModalWorkflow.put_completion_trigger(new_bridge)
        |> install_completion_tracking(facts)
    end
  end

  @spec trigger_for_completion(
          EditorState.t(),
          CompletionTrigger.t(),
          String.t(),
          pid(),
          CursorContext.t()
        ) :: {CompletionTrigger.t(), [CompletionTrigger.tracking_fact()]}
  defp trigger_for_completion(state, bridge, char, buf, context) do
    case ModalWorkflow.completion(state) do
      %Completion{} -> CompletionTrigger.maybe_retrigger(bridge, char, buf, context)
      nil -> CompletionTrigger.maybe_trigger(bridge, char, buf, context)
    end
  end

  # ── Config file completion ──────────────────────────────────────────────

  @typedoc "Config completion context detected from cursor position."
  @type config_context :: :option_name | {:option_value, atom()} | :filetype | :none

  @doc "Returns completion context for a config buffer or captured cursor context."
  @spec config_completion_context(pid() | CursorContext.t()) :: config_context()
  def config_completion_context(buf) when is_pid(buf) do
    buf |> Buffer.cursor_context() |> config_completion_context()
  end

  def config_completion_context(%CursorContext{file_path: nil}), do: :none

  def config_completion_context(%CursorContext{file_path: file_path} = context) do
    if config_file?(file_path), do: detect_from_prefix(context.line_prefix), else: :none
  end

  @spec config_file?(String.t()) :: boolean()
  defp config_file?(path) do
    case Path.basename(path) do
      ".minga.exs" -> true
      "config.exs" -> matches_config_path?(path)
      _ -> false
    end
  end

  @spec matches_config_path?(String.t()) :: boolean()
  defp matches_config_path?(path) do
    config_path =
      try do
        Minga.Config.config_path()
      catch
        :exit, _ -> nil
      end

    config_path != nil and Path.expand(path) == Path.expand(config_path)
  end

  @doc """
  Detects the config DSL context from a line of text and cursor position.

  Returns `:option_name`, `{:option_value, atom()}`, `:filetype`, or `:none`.
  Used internally by `config_completion_context/1` after determining the
  buffer is a config file. Exposed for testing.
  """
  @spec detect_config_context(String.t(), non_neg_integer()) :: config_context()
  def detect_config_context(line_text, cursor_col) do
    before_cursor = binary_part(line_text, 0, min(cursor_col, byte_size(line_text)))
    detect_from_prefix(before_cursor)
  end

  @spec detect_from_prefix(String.t()) :: config_context()
  defp detect_from_prefix(before_cursor) do
    trimmed = String.trim_leading(before_cursor)
    detect_from_trimmed(trimmed)
  end

  @spec detect_from_trimmed(String.t()) :: config_context()
  defp detect_from_trimmed("set " <> rest) do
    if String.contains?(rest, ",") do
      # Past the option name; check if we know this option for value completion
      case match_set_value_context("set " <> rest) do
        {:option_value, _} = ctx -> ctx
        nil -> :none
      end
    else
      detect_set_option_name("set " <> rest)
    end
  end

  defp detect_from_trimmed("for_filetype :" <> _), do: :filetype
  defp detect_from_trimmed(_), do: :none

  @spec detect_set_option_name(String.t()) :: config_context()
  defp detect_set_option_name("set :" <> _), do: :option_name
  defp detect_set_option_name(_), do: :none

  @spec match_set_value_context(String.t()) :: {:option_value, atom()} | nil
  defp match_set_value_context(text) do
    # Match: "set :option_name, " with optional value start
    case Regex.run(~r/^set\s+:([a-z_]+)\s*,\s*:?/, text) do
      [_full, name_str] ->
        name = String.to_existing_atom(name_str)

        if name in Config.valid_option_names() do
          {:option_value, name}
        else
          nil
        end

      nil ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec maybe_trigger_config_completion(
          EditorState.t(),
          CursorContext.t(),
          active_config_context()
        ) ::
          EditorState.t()
  defp maybe_trigger_config_completion(state, cursor_context, context) do
    if ModalWorkflow.completion(state) != nil do
      # Already showing a completion; update_filter handles narrowing.
      state
    else
      case config_items_for_context(context) do
        [] -> state
        items -> build_config_completion(state, cursor_context, items, context)
      end
    end
  end

  @spec build_config_completion(
          EditorState.t(),
          CursorContext.t(),
          [Completion.item()],
          active_config_context()
        ) :: EditorState.t()
  defp build_config_completion(state, cursor_context, items, context) do
    {cursor_line, _cursor_col} = CursorContext.position(cursor_context)
    trigger_col = config_trigger_col(cursor_context, context)
    completion = Completion.new(items, {cursor_line, trigger_col})

    prefix = CursorContext.text_since(cursor_context, {cursor_line, trigger_col}) || ""
    completion = Completion.filter(completion, prefix)

    if Completion.active?(completion) do
      open_completion(state, completion)
    else
      state
    end
  end

  @spec open_completion(EditorState.t(), Completion.t()) :: EditorState.t()
  defp open_completion(state, completion) do
    {state, active_tab} = MingaEditor.Shell.Workflow.resolve_active_tab(state)
    active_tab_id = if match?(%Tab{}, active_tab), do: active_tab.id, else: nil

    payload =
      MingaEditor.State.ModalOverlay.Completion.new(active_tab_id,
        completion: completion,
        trigger: ModalWorkflow.completion_trigger(state)
      )

    ModalWorkflow.open(state, {:completion, payload})
  end

  @typedoc "Config contexts that produce completion items (excludes :none)."
  @type active_config_context :: :option_name | {:option_value, atom()} | :filetype

  @spec config_items_for_context(active_config_context()) :: [Completion.item()]
  defp config_items_for_context(:option_name),
    do: Enum.map(Config.option_name_completions(), &Item.from_fields(:config, &1))

  defp config_items_for_context({:option_value, name}),
    do: Enum.map(Config.option_value_completions(name), &Item.from_fields(:config, &1))

  defp config_items_for_context(:filetype),
    do: Enum.map(Config.filetype_completions(), &Item.from_fields(:config, &1))

  @spec config_trigger_col(CursorContext.t(), active_config_context()) :: non_neg_integer()
  defp config_trigger_col(%CursorContext{} = cursor_context, context) do
    before_cursor = cursor_context.line_prefix
    cursor_col = cursor_context.byte_column

    case context do
      :option_name ->
        # Trigger after "set :" — find the colon
        case :binary.match(before_cursor, "set :") do
          {pos, 5} -> pos + 5
          :nomatch -> cursor_col
        end

      {:option_value, _} ->
        # Trigger after the ", " or ", :" — find the last comma+space
        case Regex.run(~r/,\s*:?/, before_cursor, return: :index) do
          [{pos, len} | _] -> pos + len
          nil -> cursor_col
        end

      :filetype ->
        # Trigger after "for_filetype :" — find the colon
        case :binary.match(before_cursor, "for_filetype :") do
          {pos, 14} -> pos + 14
          :nomatch -> cursor_col
        end
    end
  end

  @spec completion_prefix(CursorContext.t(), {non_neg_integer(), non_neg_integer()}) ::
          String.t() | nil
  defp completion_prefix(%CursorContext{} = context, trigger_position),
    do: CursorContext.text_since(context, trigger_position)

  @doc "Starts background processing for one identity-checked provider response."
  @spec handle_completion_result(EditorState.t(), CompletionTrigger.tracking_fact(), term()) ::
          EditorState.t()
  def handle_completion_result(
        state,
        {_request_ref, role, _provider_id, _client, buffer, version, _session_id, _gen,
         trigger_pos} = fact,
        result
      ) do
    with %CursorContext{version: ^version} = context <-
           buffer_value(buffer, &Buffer.cursor_context/1),
         true <- completion_result_current?(state, fact),
         {:ok, prefix} <- completion_prefix_from_trigger(context, trigger_pos) do
      mode = if role == :primary, do: :primary, else: :merge
      start_completion_task(self(), mode, result, prefix, fact)
    end

    state
  end

  @doc "Handles a legacy completion response that predates stable session ownership."
  @spec handle_completion_result(
          EditorState.t(),
          CompletionTrigger.response_role(),
          pid(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()},
          term()
        ) :: EditorState.t()
  def handle_completion_result(state, role, client, buffer, version, gen, trigger_pos, result) do
    with %CursorContext{version: ^version} = context <-
           buffer_value(buffer, &Buffer.cursor_context/1),
         true <- legacy_completion_result_current?(state, client, buffer, gen),
         {:ok, prefix} <- completion_prefix_from_trigger(context, trigger_pos) do
      editor = self()
      mode = if role == :primary, do: :primary, else: :merge

      Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
        payload = legacy_processed_payload(mode, result, trigger_pos, prefix)
        send(editor, {:completion_processed, gen, mode, payload, trigger_pos, buffer, version})
      end)
    end

    state
  end

  defp completion_result_current?(
         %{shell_runtime: %{state: %ShellState{}}} = state,
         {_ref, _role, _provider_id, client, buffer, version, session_id, gen, _position}
       ) do
    trigger = ModalWorkflow.completion_trigger(state)

    ModalOverlay.match(state.shell_runtime.state.modal, :completion) and
      Minga.Editing.inserting?(state) and
      match?(%Session{}, CompletionTrigger.session(trigger)) and
      Session.current?(CompletionTrigger.session(trigger), session_id, gen, buffer, version) and
      state.workspace.buffers.active == buffer and
      client in SyncServer.clients_for_buffer(buffer)
  end

  defp completion_result_current?(_state, _fact), do: false

  @spec legacy_completion_result_current?(EditorState.t(), pid(), pid(), non_neg_integer()) ::
          boolean()
  defp legacy_completion_result_current?(
         %{shell_runtime: %{state: %ShellState{}}} = state,
         client,
         buffer,
         gen
       ) do
    ModalOverlay.match(state.shell_runtime.state.modal, :completion) and
      CompletionTrigger.generation(ModalWorkflow.completion_trigger(state)) == gen and
      state.workspace.buffers.active == buffer and client in SyncServer.clients_for_buffer(buffer)
  end

  defp legacy_completion_result_current?(_state, _client, _buffer, _gen), do: false

  @spec legacy_processed_payload(
          :primary | :merge,
          term(),
          CompletionTrigger.position(),
          String.t()
        ) :: Completion.t() | [Completion.item()] | :failed
  defp legacy_processed_payload(:primary, {:ok, result}, trigger_pos, prefix) do
    result
    |> Completion.parse_response()
    |> Completion.new(trigger_pos)
    |> Completion.filter(prefix)
  rescue
    _error -> :failed
  end

  defp legacy_processed_payload(:merge, {:ok, result}, _trigger_pos, _prefix) do
    Completion.parse_response(result)
  rescue
    _error -> :failed
  end

  defp legacy_processed_payload(_mode, _result, _trigger_pos, _prefix), do: :failed

  @spec completion_prefix_from_trigger(CursorContext.t(), CompletionTrigger.position()) ::
          {:ok, String.t()} | :stale
  defp completion_prefix_from_trigger(context, trigger_pos),
    do: {:ok, CompletionTrigger.get_typed_since_trigger(context, trigger_pos)}

  @spec start_completion_task(
          pid(),
          :primary | :merge,
          term(),
          String.t(),
          CompletionTrigger.tracking_fact()
        ) :: :ok
  defp start_completion_task(editor, mode, result, prefix, fact) do
    {_request_ref, _role, _provider_id, _client, _buffer, _version, _session_id, gen,
     _trigger_pos} = fact

    case Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
           run_completion_task(editor, mode, result, prefix, fact)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        # No Task means no {:completion_processed, ...} will arrive on its own;
        # signal failure so the Editor clears the stuck pending modal.
        Minga.Log.warning(:lsp, fn ->
          "Completion Task failed to start (gen=#{gen}, mode=#{mode}): #{inspect(reason)}"
        end)

        send(editor, {:completion_processed, fact, :failed})

        :ok
    end
  end

  @spec run_completion_task(
          pid(),
          :primary | :merge,
          term(),
          String.t(),
          CompletionTrigger.tracking_fact()
        ) :: :ok
  defp run_completion_task(editor, mode, result, _prefix, fact) do
    {request_ref, _role, provider_id, client, _buffer, _version, session_id, gen, _trigger_pos} =
      fact

    payload =
      try do
        build_processed(
          mode,
          result,
          session_id,
          gen,
          provider_id,
          client,
          request_ref
        )
      rescue
        e ->
          Minga.Log.warning(:lsp, fn ->
            "Completion processing crashed (gen=#{gen}, mode=#{mode}): #{Exception.message(e)}"
          end)

          :failed
      catch
        kind, reason ->
          Minga.Log.warning(:lsp, fn ->
            "Completion processing failed (gen=#{gen}, mode=#{mode}): #{inspect({kind, reason})}"
          end)

          :failed
      end

    send(editor, {:completion_processed, fact, payload})

    :ok
  end

  @spec build_processed(
          :primary | :merge,
          term(),
          reference(),
          non_neg_integer(),
          Item.provider_id(),
          pid(),
          reference()
        ) :: ProviderBatch.t()
  defp build_processed(
         _mode,
         {:ok, result},
         session_id,
         gen,
         provider_id,
         client,
         request_ref
       ) do
    ProviderBatch.from_response(session_id, gen, provider_id, client, request_ref, result)
  end

  @doc "Applies one processed provider batch only while its full request identity is current."
  @spec apply_processed(
          EditorState.t(),
          CompletionTrigger.tracking_fact(),
          ProviderBatch.t() | :failed
        ) :: EditorState.t()
  def apply_processed(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        {request_ref, role, provider_id, _client, buffer, version, session_id, gen, trigger_pos},
        payload
      ) do
    trigger = ModalWorkflow.completion_trigger(state)
    mode = if role == :primary, do: :primary, else: :merge

    if ModalOverlay.match(state.shell_runtime.state.modal, :completion) and
         Minga.Editing.inserting?(state) and
         match?(%Session{}, CompletionTrigger.session(trigger)) and
         Session.current?(CompletionTrigger.session(trigger), session_id, gen, buffer, version) and
         provider_request_current?(trigger, provider_id, request_ref) and
         state.workspace.buffers.active == buffer and
         buffer_value(buffer, &Buffer.version/1) == version do
      apply_processed_current(
        state,
        trigger,
        mode,
        provider_id,
        request_ref,
        payload,
        trigger_pos
      )
    else
      state
    end
  end

  def apply_processed(state, _fact, _payload), do: state

  @doc "Applies a legacy processed completion batch that predates stable session ownership."
  @spec apply_processed(
          EditorState.t(),
          non_neg_integer(),
          :primary | :merge,
          Completion.t() | [Completion.item()] | :failed,
          CompletionTrigger.position(),
          pid(),
          non_neg_integer()
        ) :: EditorState.t()
  def apply_processed(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        gen,
        mode,
        payload,
        trigger_pos,
        buffer,
        version
      ) do
    trigger = ModalWorkflow.completion_trigger(state)

    if ModalOverlay.match(state.shell_runtime.state.modal, :completion) and
         CompletionTrigger.generation(trigger) == gen and state.workspace.buffers.active == buffer and
         buffer_value(buffer, &Buffer.version/1) == version do
      apply_legacy_processed(state, mode, payload, trigger_pos)
    else
      state
    end
  end

  def apply_processed(state, _gen, _mode, _payload, _trigger_pos, _buffer, _version), do: state

  @spec apply_processed_current(
          EditorState.t(),
          CompletionTrigger.t(),
          :primary | :merge,
          Item.provider_id(),
          reference(),
          ProviderBatch.t() | :failed,
          {non_neg_integer(), non_neg_integer()}
        ) :: EditorState.t()
  defp apply_processed_current(
         state,
         trigger,
         _mode,
         provider_id,
         request_ref,
         :failed,
         _trigger_pos
       ) do
    case Session.fail_request(CompletionTrigger.session(trigger), provider_id, request_ref) do
      {:ok, session} ->
        state
        |> ModalWorkflow.put_completion_trigger(CompletionTrigger.put_session(trigger, session))
        |> maybe_finish_failed()

      :stale ->
        state
    end
  end

  defp apply_processed_current(
         state,
         trigger,
         _mode,
         _provider_id,
         _request_ref,
         %ProviderBatch{} = batch,
         trigger_pos
       ) do
    case CompletionTrigger.accept_batch(trigger, batch) do
      {:ok, trigger} -> install_session_completion(state, trigger, trigger_pos)
      :stale -> state
    end
  end

  @spec apply_legacy_processed(
          EditorState.t(),
          :primary | :merge,
          Completion.t() | [Completion.item()] | :failed,
          CompletionTrigger.position()
        ) :: EditorState.t()
  defp apply_legacy_processed(state, :primary, :failed, _trigger_pos) do
    case ModalWorkflow.completion(state) do
      nil -> dismiss(state)
      %Completion{} -> state
    end
  end

  defp apply_legacy_processed(state, :merge, :failed, _trigger_pos), do: state

  defp apply_legacy_processed(state, :primary, %Completion{items: []}, _trigger_pos), do: state

  defp apply_legacy_processed(state, :primary, %Completion{} = completion, trigger_pos),
    do: merge_legacy_completion(state, completion.items, trigger_pos)

  defp apply_legacy_processed(state, :merge, items, trigger_pos) when is_list(items),
    do: merge_legacy_completion(state, items, trigger_pos)

  @spec merge_legacy_completion(
          EditorState.t(),
          [Completion.item()],
          CompletionTrigger.position()
        ) ::
          EditorState.t()
  defp merge_legacy_completion(state, [], _trigger_pos), do: state

  defp merge_legacy_completion(state, new_items, trigger_pos) do
    context = buffer_value(state.workspace.buffers.active, &Buffer.cursor_context/1)

    case ModalWorkflow.completion(state) do
      nil ->
        completion = Completion.new(new_items, trigger_pos)

        open_completion(
          state,
          Completion.filter(completion, typed_since_trigger(context, trigger_pos))
        )

      %Completion{} = existing ->
        completion = Completion.new(existing.items ++ new_items, existing.trigger_position)
        prefix = typed_since_trigger(context, existing.trigger_position)
        ModalWorkflow.update_completion(state, fn _ -> Completion.filter(completion, prefix) end)
    end
  end

  @spec install_session_completion(
          EditorState.t(),
          CompletionTrigger.t(),
          CompletionTrigger.position()
        ) ::
          EditorState.t()
  defp install_session_completion(state, trigger, trigger_pos) do
    session = CompletionTrigger.session(trigger)
    index = Session.index(session)

    if index.total_count == 0 and session.provider_requests == %{} do
      dismiss(state)
    else
      context = buffer_value(state.workspace.buffers.active, &Buffer.cursor_context/1)
      prefix = typed_since_trigger(context, trigger_pos)

      completion =
        Completion.new(index, trigger_pos, session.selected_item_id)
        |> Completion.filter(prefix)
        |> Completion.select_item(session.selected_item_id)

      state = ModalWorkflow.put_completion_trigger(state, trigger)
      ModalWorkflow.update_completion(state, fn _ -> completion end)
    end
  end

  @spec maybe_finish_failed(EditorState.t()) :: EditorState.t()
  defp maybe_finish_failed(state) do
    case CompletionTrigger.session(ModalWorkflow.completion_trigger(state)) do
      %Session{provider_requests: requests, batches: batches}
      when map_size(requests) == 0 and map_size(batches) == 0 ->
        dismiss(state)

      _ ->
        state
    end
  end

  @spec provider_request_current?(CompletionTrigger.t(), Item.provider_id(), reference()) ::
          boolean()
  defp provider_request_current?(trigger, provider_id, request_ref) do
    case CompletionTrigger.session(trigger) do
      %Session{provider_requests: requests} ->
        case Map.fetch(requests, provider_id) do
          {:ok, {_client, ^request_ref}} -> true
          _ -> false
        end

      nil ->
        false
    end
  end

  @spec typed_since_trigger(CursorContext.t() | :stale, CompletionTrigger.position()) ::
          String.t()
  defp typed_since_trigger(%CursorContext{} = context, trigger_position),
    do: CompletionTrigger.get_typed_since_trigger(context, trigger_position)

  defp typed_since_trigger(:stale, _trigger_position), do: ""

  @spec session_id(CompletionTrigger.t()) :: reference()
  defp session_id(trigger) do
    case CompletionTrigger.session(trigger) do
      %Session{id: id} -> id
      nil -> make_ref()
    end
  end

  @spec resolve_client(Session.t(), Item.provider_id()) :: pid() | nil
  defp resolve_client(%Session{} = session, provider_id) do
    case Map.fetch(session.batches, provider_id) do
      {:ok, %ProviderBatch{client: client}} -> client
      :error -> nil
    end
  end

  @spec codepoint_to_char(non_neg_integer()) :: String.t() | nil
  defp codepoint_to_char(cp) when cp >= 32 and cp <= 0x10FFFF do
    <<cp::utf8>>
  rescue
    ArgumentError -> nil
  end

  defp codepoint_to_char(_), do: nil

  @spec handle_signature_help_response(EditorState.t(), {:ok, term()} | {:error, term()}) ::
          EditorState.t()
  def handle_signature_help_response(state, {:error, _}), do: state

  def handle_signature_help_response(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        {:ok, nil}
      ),
      do: SignatureHelpWorkflow.dismiss(state)

  def handle_signature_help_response(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        {:ok, result}
      )
      when is_map(result) do
    {cursor_row, cursor_col} = approximate_cursor_screen_pos(state)

    case SignatureHelp.from_response(result, cursor_row, cursor_col) do
      nil -> SignatureHelpWorkflow.dismiss(state)
      signature_help -> SignatureHelpWorkflow.show(state, signature_help)
    end
  end

  def handle_signature_help_response(state, _), do: state

  @spec maybe_trigger_signature_help(EditorState.t(), pid(), CursorContext.t(), non_neg_integer()) ::
          EditorState.t()
  defp maybe_trigger_signature_help(state, buf, context, codepoint) do
    char = codepoint_to_char(codepoint)

    cond do
      # ) always dismisses signature help
      codepoint == ?) ->
        SignatureHelpWorkflow.dismiss(state)

      char != nil and signature_trigger_char?(state, buf, char) ->
        send_signature_help_request(state, buf, context)

      codepoint in [?(, ?,] ->
        send_signature_help_request(state, buf, context)

      true ->
        state
    end
  end

  @spec signature_trigger_char?(EditorState.t(), pid(), String.t()) :: boolean()
  defp signature_trigger_char?(state, buf, char) do
    client = lsp_client_for(state, buf)

    if client do
      caps = Client.capabilities(client)
      trigger_chars = get_in(caps, ["signatureHelpProvider", "triggerCharacters"]) || []
      char in trigger_chars
    else
      false
    end
  catch
    :exit, _ -> false
  end

  @spec send_signature_help_request(EditorState.t(), pid(), CursorContext.t()) :: EditorState.t()
  defp send_signature_help_request(state, buf, context) do
    case {lsp_client_for(state, buf), signature_help_origin(context)} do
      {client, {:ok, uri, {line, col}, version}} when is_pid(client) ->
        position =
          PositionEncoding.to_lsp({line, col}, context.line_text, client_encoding(client))

        params = %{
          "textDocument" => %{"uri" => uri},
          "position" => position
        }

        ref = Client.request(client, "textDocument/signatureHelp", params)
        track_signature_help_request(state, ref, client, buf, version, {line, col})

      _ ->
        state
    end
  end

  @spec signature_help_origin(CursorContext.t()) ::
          {:ok, String.t(), {non_neg_integer(), non_neg_integer()}, non_neg_integer()} | :stale
  defp signature_help_origin(%CursorContext{file_path: path} = context) when is_binary(path) do
    {:ok, SyncServer.path_to_uri(path), CursorContext.position(context), context.version}
  end

  defp signature_help_origin(%CursorContext{}), do: :stale

  @spec client_encoding(pid()) :: PositionEncoding.encoding()
  defp client_encoding(client) do
    Client.encoding(client)
  catch
    :exit, _ -> :utf16
  end

  @spec approximate_cursor_screen_pos(EditorState.t()) ::
          {non_neg_integer(), non_neg_integer()}
  defp approximate_cursor_screen_pos(state) do
    buf = state.workspace.buffers.active

    if buf do
      {line, col} = Buffer.cursor(buf)
      vp = state.frontend.terminal_viewport
      screen_row = max(line - vp.top + 1, 1)
      screen_col = min(col + 4, vp.cols - 1)
      {screen_row, screen_col}
    else
      {div(state.frontend.terminal_viewport.rows, 2),
       div(state.frontend.terminal_viewport.cols, 2)}
    end
  end

  @spec lsp_client_for(EditorState.t(), pid()) :: pid() | nil
  defp lsp_client_for(_state, buffer_pid) do
    case SyncServer.clients_for_buffer(buffer_pid) do
      [client | _] -> client
      [] -> nil
    end
  end

  @spec buffer_value(pid(), (pid() -> term())) :: term() | :stale
  defp buffer_value(buffer, fun) do
    fun.(buffer)
  catch
    :exit, _ -> :stale
  end

  @spec extract_resolve_documentation(map()) :: String.t()
  defp extract_resolve_documentation(%{"documentation" => %{"value" => value}})
       when is_binary(value),
       do: String.trim(value)

  defp extract_resolve_documentation(%{"documentation" => doc}) when is_binary(doc),
    do: String.trim(doc)

  defp extract_resolve_documentation(_), do: ""
end
