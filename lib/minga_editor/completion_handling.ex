defmodule MingaEditor.CompletionHandling do
  @moduledoc """
  Completion accept, filter, trigger, and dismiss logic.

  Handles both LSP completions (async, debounced) and config file
  completions (synchronous, from the Options registry). Extracted
  from `MingaEditor` to keep the GenServer module focused on
  orchestration. All functions are pure state transforms.
  """

  alias Minga.Buffer
  alias Minga.Config
  alias Minga.Editing.Completion
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
    raw_item = if item, do: item.raw
    gen = CompletionTrigger.generation(ModalWorkflow.completion_trigger(state))

    if item == nil or raw_item == nil or raw_item == completion.last_resolved_identity or
         item.documentation != "" do
      state
    else
      if completion.resolve_timer do
        Process.cancel_timer(completion.resolve_timer)
      end

      timer =
        if state.frontend.backend != :headless do
          Process.send_after(self(), {:completion_resolve, gen, raw_item}, @resolve_debounce_ms)
        end

      ModalWorkflow.update_completion(state, fn _ ->
        %{completion | resolve_timer: timer}
      end)
    end
  end

  @spec flush_resolve(EditorState.t(), non_neg_integer(), map()) :: EditorState.t()
  def flush_resolve(%{shell_runtime: %{state: %ShellState{}}} = state, gen, raw_item) do
    case ModalWorkflow.completion(state) do
      nil -> state
      completion -> do_flush_resolve(state, completion, gen, raw_item)
    end
  end

  def flush_resolve(state, _gen, _raw_item), do: state

  @spec do_flush_resolve(EditorState.t(), Completion.t(), non_neg_integer(), map()) ::
          EditorState.t()
  defp do_flush_resolve(
         %{workspace: %{buffers: %{active: buf}}} = state,
         completion,
         gen,
         raw_item
       ) do
    trigger = ModalWorkflow.completion_trigger(state)

    if CompletionTrigger.generation(trigger) == gen and
         Completion.selected_raw?(completion, raw_item) do
      flush_resolve_request(state, buf, gen, raw_item)
    else
      state
    end
  end

  @spec flush_resolve_request(EditorState.t(), pid(), non_neg_integer(), map()) :: EditorState.t()
  defp flush_resolve_request(state, buf, gen, raw_item) do
    case {lsp_client_for(state, buf), buffer_value(buf, &Buffer.version/1)} do
      {client, version} when is_pid(client) and is_integer(version) and version >= 0 ->
        ref = Client.request(client, "completionItem/resolve", raw_item)
        track_completion_resolve_request(state, ref, client, buf, version, gen, raw_item)

      _ ->
        state
    end
  end

  @spec handle_resolve_response(EditorState.t(), map(), {:ok, term()} | {:error, term()}) ::
          EditorState.t()
  def handle_resolve_response(state, _raw_item, {:error, _error}), do: state

  def handle_resolve_response(
        %{shell_runtime: %{state: %ShellState{}}} = state,
        raw_item,
        {:ok, resolved}
      )
      when is_map(raw_item) do
    case ModalWorkflow.completion(state) do
      nil ->
        state

      _completion ->
        doc_text = extract_resolve_documentation(resolved)

        ModalWorkflow.update_completion(state, fn completion ->
          Completion.update_selected_documentation(completion, raw_item, doc_text)
        end)
    end
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
      # Cancel any pending resolve timer and dismiss the trigger to cancel
      # debounce timers and forget pending refs before the modal closes.
      case ModalWorkflow.completion(state) do
        %Completion{resolve_timer: timer} when is_reference(timer) ->
          Process.cancel_timer(timer)

        _ ->
          :ok
      end

      _ = CompletionTrigger.dismiss(ModalWorkflow.completion_trigger(state))

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
  def install_completion_tracking(state, facts) do
    Enum.reduce(facts, state, fn {ref, role, client, buffer, version, gen, pos}, state ->
      %{
        state
        | lsp:
            LSPState.track_completion_result_request(
              state.lsp,
              ref,
              role,
              client,
              buffer,
              version,
              gen,
              pos
            )
      }
    end)
  end

  @spec track_completion_resolve_request(
          EditorState.t(),
          reference(),
          pid(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          map()
        ) :: EditorState.t()
  defp track_completion_resolve_request(state, ref, client, buffer, version, gen, raw_item) do
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
    {_content, {cursor_line, cursor_col}} = Buffer.content_and_cursor(buf)

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
    state = update_filter(state, buf)

    state =
      case config_completion_context(buf) do
        :none ->
          maybe_trigger(state, buf, codepoint)

        context ->
          maybe_trigger_config_completion(state, buf, context)
      end

    maybe_trigger_signature_help(state, buf, codepoint)
  end

  @spec update_filter(EditorState.t(), pid()) :: EditorState.t()
  defp update_filter(state, buf) do
    case ModalWorkflow.completion(state) do
      nil ->
        state

      %Completion{} = completion ->
        prefix = completion_prefix(buf, completion.trigger_position)
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
      dismiss(state)
    end
  end

  @spec maybe_trigger(EditorState.t(), pid(), non_neg_integer()) :: EditorState.t()
  defp maybe_trigger(state, buf, codepoint) do
    case codepoint_to_char(codepoint) do
      nil ->
        state

      char ->
        {new_bridge, facts} =
          CompletionTrigger.maybe_trigger(
            ModalWorkflow.completion_trigger(state),
            char,
            buf
          )

        state
        |> ModalWorkflow.put_completion_trigger(new_bridge)
        |> install_completion_tracking(facts)
    end
  end

  # ── Config file completion ──────────────────────────────────────────────

  @typedoc "Config completion context detected from cursor position."
  @type config_context :: :option_name | {:option_value, atom()} | :filetype | :none

  @doc false
  @spec config_completion_context(pid()) :: config_context()
  def config_completion_context(buf) do
    file_path = Buffer.file_path(buf)

    if config_file?(file_path) do
      {content, {cursor_line, cursor_col}} = Buffer.content_and_cursor(buf)
      lines = String.split(content, "\n")

      case Enum.at(lines, cursor_line) do
        nil -> :none
        line_text -> detect_config_context(line_text, cursor_col)
      end
    else
      :none
    end
  end

  @spec config_file?(String.t() | nil) :: boolean()
  defp config_file?(nil), do: false

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
    before_cursor = String.slice(line_text, 0, cursor_col)
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

  @spec maybe_trigger_config_completion(EditorState.t(), pid(), active_config_context()) ::
          EditorState.t()
  defp maybe_trigger_config_completion(state, buf, context) do
    if ModalWorkflow.completion(state) != nil do
      # Already showing a completion; update_filter handles narrowing.
      state
    else
      case config_items_for_context(context) do
        [] -> state
        items -> build_config_completion(state, buf, items, context)
      end
    end
  end

  @spec build_config_completion(
          EditorState.t(),
          pid(),
          [Completion.item()],
          active_config_context()
        ) :: EditorState.t()
  defp build_config_completion(state, buf, items, context) do
    {cursor_line, cursor_col} = Buffer.cursor(buf)
    trigger_col = config_trigger_col(buf, cursor_line, cursor_col, context)
    completion = Completion.new(items, {cursor_line, trigger_col})

    prefix = config_prefix(buf, cursor_line, trigger_col, cursor_col)
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
  defp config_items_for_context(:option_name), do: Config.option_name_completions()

  defp config_items_for_context({:option_value, name}),
    do: Config.option_value_completions(name)

  defp config_items_for_context(:filetype), do: Config.filetype_completions()

  @spec config_trigger_col(pid(), non_neg_integer(), non_neg_integer(), active_config_context()) ::
          non_neg_integer()
  defp config_trigger_col(buf, cursor_line, cursor_col, context) do
    {content, _cursor} = Buffer.content_and_cursor(buf)
    lines = String.split(content, "\n")
    line_text = Enum.at(lines, cursor_line) || ""
    before_cursor = String.slice(line_text, 0, cursor_col)

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

  @spec config_prefix(pid(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          String.t()
  defp config_prefix(buf, cursor_line, trigger_col, cursor_col) do
    if cursor_col > trigger_col do
      {content, _cursor} = Buffer.content_and_cursor(buf)
      lines = String.split(content, "\n")

      case Enum.at(lines, cursor_line) do
        nil -> ""
        line_text -> String.slice(line_text, trigger_col, cursor_col - trigger_col)
      end
    else
      ""
    end
  end

  @spec completion_prefix(pid(), {non_neg_integer(), non_neg_integer()}) :: String.t() | nil
  defp completion_prefix(buf, {trigger_line, trigger_col}) do
    {content, {cursor_line, cursor_col}} = Buffer.content_and_cursor(buf)

    if cursor_line == trigger_line and cursor_col >= trigger_col do
      lines = String.split(content, "\n")

      case Enum.at(lines, cursor_line) do
        nil -> nil
        line_text -> String.slice(line_text, trigger_col, cursor_col - trigger_col)
      end
    else
      nil
    end
  end

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
    with true <- completion_result_current?(state, client, buffer, version, gen),
         {:ok, prefix} <- completion_prefix_from_trigger(buffer, trigger_pos),
         true <- buffer_value(buffer, &Buffer.version/1) == version do
      mode = if role == :primary, do: :primary, else: :merge
      start_completion_task(self(), mode, result, trigger_pos, prefix, gen, buffer, version)
    end

    state
  end

  defp completion_result_current?(
         %{shell_runtime: %{state: %ShellState{}}} = state,
         client,
         buffer,
         version,
         gen
       ) do
    trigger = ModalWorkflow.completion_trigger(state)

    ModalOverlay.match(state.shell_runtime.state.modal, :completion) and
      CompletionTrigger.generation(trigger) == gen and state.workspace.buffers.active == buffer and
      buffer_value(buffer, &Buffer.version/1) == version and
      client in SyncServer.clients_for_buffer(buffer)
  end

  defp completion_result_current?(_state, _client, _buffer, _version, _gen), do: false

  @spec completion_prefix_from_trigger(pid(), CompletionTrigger.position()) ::
          {:ok, String.t()} | :stale
  defp completion_prefix_from_trigger(buffer, trigger_pos) do
    {:ok, CompletionTrigger.get_typed_since_trigger(buffer, trigger_pos)}
  catch
    :exit, _ -> :stale
  end

  @spec start_completion_task(
          pid(),
          :primary | :merge,
          term(),
          {non_neg_integer(), non_neg_integer()},
          String.t(),
          non_neg_integer(),
          pid(),
          non_neg_integer()
        ) :: :ok
  defp start_completion_task(editor, mode, result, trigger_pos, prefix, gen, buffer, version) do
    case Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
           run_completion_task(editor, mode, result, trigger_pos, prefix, gen, buffer, version)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        # No Task means no {:completion_processed, ...} will arrive on its own;
        # signal failure so the Editor clears the stuck pending modal.
        Minga.Log.warning(:lsp, fn ->
          "Completion Task failed to start (gen=#{gen}, mode=#{mode}): #{inspect(reason)}"
        end)

        send(editor, {:completion_processed, gen, mode, :failed, trigger_pos, buffer, version})
        :ok
    end
  end

  @spec run_completion_task(
          pid(),
          :primary | :merge,
          term(),
          {non_neg_integer(), non_neg_integer()},
          String.t(),
          non_neg_integer(),
          pid(),
          non_neg_integer()
        ) :: :ok
  defp run_completion_task(editor, mode, result, trigger_pos, prefix, gen, buffer, version) do
    payload =
      try do
        build_processed(mode, result, trigger_pos, prefix)
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

    send(editor, {:completion_processed, gen, mode, payload, trigger_pos, buffer, version})
    :ok
  end

  @spec build_processed(
          :primary,
          term(),
          {non_neg_integer(), non_neg_integer()},
          String.t()
        ) :: Completion.t()
  defp build_processed(:primary, {:ok, result}, trigger_pos, prefix) do
    result
    |> Completion.parse_response()
    |> Completion.new(trigger_pos)
    |> Completion.filter(prefix)
  end

  @spec build_processed(:merge, term(), {non_neg_integer(), non_neg_integer()}, String.t()) ::
          [Completion.item()]
  defp build_processed(:merge, {:ok, result}, _trigger_pos, _prefix) do
    Completion.parse_response(result)
  end

  @spec apply_processed(
          EditorState.t(),
          non_neg_integer(),
          :primary | :merge,
          Completion.t() | [Completion.item()] | :failed,
          {non_neg_integer(), non_neg_integer()},
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
      apply_processed_current(state, mode, payload, trigger_pos)
    else
      state
    end
  end

  def apply_processed(state, _gen, _mode, _payload, _trigger_pos, _buffer, _version), do: state

  @spec apply_processed_current(
          EditorState.t(),
          :primary | :merge,
          Completion.t() | [Completion.item()] | :failed,
          {non_neg_integer(), non_neg_integer()}
        ) :: EditorState.t()
  defp apply_processed_current(state, :primary, :failed, _trigger_pos) do
    case ModalWorkflow.completion(state) do
      nil -> dismiss(state)
      %Completion{} -> state
    end
  end

  defp apply_processed_current(state, :merge, :failed, _trigger_pos), do: state

  defp apply_processed_current(state, :primary, %Completion{items: []}, _trigger_pos) do
    state
  end

  defp apply_processed_current(state, :primary, %Completion{} = built, _trigger_pos) do
    case ModalWorkflow.completion(state) do
      nil ->
        ModalWorkflow.update_completion(state, fn _ -> built end)

      %Completion{} ->
        merge_completion_items(state, built.items, built.trigger_position)
    end
  end

  defp apply_processed_current(state, :merge, items, trigger_pos) when is_list(items) do
    merge_completion_items(state, items, trigger_pos)
  end

  @spec merge_completion_items(
          EditorState.t(),
          [Completion.item()],
          {non_neg_integer(), non_neg_integer()}
        ) :: EditorState.t()
  defp merge_completion_items(state, [], _trigger_pos), do: state

  defp merge_completion_items(state, new_items, trigger_pos) do
    case ModalWorkflow.completion(state) do
      nil ->
        completion = Completion.new(new_items, trigger_pos)

        prefix =
          CompletionTrigger.get_typed_since_trigger(state.workspace.buffers.active, trigger_pos)

        completion = Completion.filter(completion, prefix)
        open_completion(state, completion)

      %Completion{} = existing ->
        merged_items = existing.items ++ new_items
        completion = Completion.new(merged_items, existing.trigger_position)

        prefix =
          CompletionTrigger.get_typed_since_trigger(
            state.workspace.buffers.active,
            existing.trigger_position
          )

        completion = Completion.filter(completion, prefix)

        ModalWorkflow.update_completion(state, fn _ ->
          completion
        end)
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

  @spec maybe_trigger_signature_help(EditorState.t(), pid(), non_neg_integer()) ::
          EditorState.t()
  defp maybe_trigger_signature_help(state, buf, codepoint) do
    char = codepoint_to_char(codepoint)

    cond do
      # ) always dismisses signature help
      codepoint == ?) ->
        SignatureHelpWorkflow.dismiss(state)

      char != nil and signature_trigger_char?(state, buf, char) ->
        send_signature_help_request(state, buf)

      codepoint in [?(, ?,] ->
        send_signature_help_request(state, buf)

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

  @spec send_signature_help_request(EditorState.t(), pid()) :: EditorState.t()
  defp send_signature_help_request(state, buf) do
    case {lsp_client_for(state, buf), signature_help_origin(buf)} do
      {client, {:ok, uri, {line, col}, version}} when is_pid(client) ->
        params = %{
          "textDocument" => %{"uri" => uri},
          "position" => %{"line" => line, "character" => col}
        }

        ref = Client.request(client, "textDocument/signatureHelp", params)
        track_signature_help_request(state, ref, client, buf, version, {line, col})

      _ ->
        state
    end
  end

  @spec signature_help_origin(pid()) ::
          {:ok, String.t(), {non_neg_integer(), non_neg_integer()}, non_neg_integer()} | :stale
  defp signature_help_origin(buf) do
    case {
      buffer_value(buf, &Buffer.file_path/1),
      buffer_value(buf, &Buffer.cursor/1),
      buffer_value(buf, &Buffer.version/1)
    } do
      {path, {line, col}, version}
      when is_binary(path) and is_integer(version) and version >= 0 ->
        {:ok, SyncServer.path_to_uri(path), {line, col}, version}

      _ ->
        :stale
    end
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
