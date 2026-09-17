defmodule MingaEditor.State.LSP.PendingRequests do
  @moduledoc """
  Pure indexes for Editor-global LSP request correlations.

  One response reference has exactly one semantic owner. Formatting keeps extra Buffer and newest indexes for cancellation while all request variants share the `by_ref` authority.
  """

  alias MingaEditor.State.LSP.FormatOperation

  defstruct by_ref: %{},
            format_by_buffer: %{},
            newest_formats: [],
            workspace_generations: %{},
            next_workspace_generation: 1

  @type operation_kind :: :references | :rename
  @type position :: {non_neg_integer(), non_neg_integer()}
  @type workspace_generation :: pos_integer()
  @type workspace_key :: {:code_action, pid()}
  @type request ::
          {:response, MingaEditor.State.LSP.current_origin_response_kind(), pid(), pid(),
           non_neg_integer(), MingaEditor.State.Tab.id() | nil, position() | nil}
          | {:inlay_hint, pid(), pid(), non_neg_integer(), MingaEditor.State.Tab.id() | nil,
             non_neg_integer(), pos_integer()}
          | {:completion_result, MingaEditor.CompletionTrigger.response_role(),
             Minga.Editing.Completion.Item.provider_id(), pid(), reference(), pid(),
             non_neg_integer(), reference(), non_neg_integer(), position()}
          | {:completion_resolve, pid(), reference(), pid(), non_neg_integer(), reference(),
             non_neg_integer(), Minga.Editing.Completion.Item.provider_id(),
             Minga.Editing.Completion.Item.id(), map()}
          | {:completion_result, MingaEditor.CompletionTrigger.response_role(), pid(), pid(),
             non_neg_integer(), non_neg_integer(), position()}
          | {:completion_resolve, pid(), pid(), non_neg_integer(), non_neg_integer(), map()}
          | {:signature_help, pid(), pid(), non_neg_integer(), position()}
          | {:hover_mouse, non_neg_integer(), non_neg_integer(), pid(), non_neg_integer(),
             non_neg_integer(), non_neg_integer()}
          | {:semantic_tokens, pid(), pid(), non_neg_integer(),
             Minga.LSP.PositionEncoding.encoding(), {[String.t()], [String.t()]}}
          | {:operation, operation_kind(), MingaEditor.State.Operation.id(),
             MingaEditor.State.Tab.id() | nil}
          | {:workspace_operation, :rename, MingaEditor.State.Operation.id(),
             MingaEditor.State.Tab.id() | nil, Minga.LSP.DocumentContext.t()}
          | {:workspace_response, :code_action, workspace_generation(),
             Minga.LSP.DocumentContext.t(), MingaEditor.State.Tab.id() | nil, position()}
          | {:format, FormatOperation.t()}

  @type t :: %__MODULE__{
          by_ref: %{reference() => request()},
          format_by_buffer: %{pid() => reference()},
          newest_formats: [reference()],
          workspace_generations: %{workspace_key() => workspace_generation()},
          next_workspace_generation: workspace_generation()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  defguardp valid_cursor_guard(cursor)
            when is_tuple(cursor) and tuple_size(cursor) == 2 and is_integer(elem(cursor, 0)) and
                   elem(cursor, 0) >= 0 and is_integer(elem(cursor, 1)) and elem(cursor, 1) >= 0

  @doc "Tracks one provider-owned completion result request by its full session identity."
  @spec track_completion_result(t(), MingaEditor.CompletionTrigger.tracking_fact()) ::
          {:ok, t()} | {:error, :duplicate_ref}
  def track_completion_result(
        %__MODULE__{} = pending,
        {ref, role, provider_id, client, buffer, version, session_id, gen, pos}
      )
      when is_reference(ref) and role in [:primary, :secondary] and is_pid(client) and
             is_pid(buffer) and is_integer(version) and version >= 0 and is_integer(gen) and
             is_reference(session_id) and gen >= 0 and valid_cursor_guard(pos) do
    track_request(
      pending,
      ref,
      {:completion_result, role, provider_id, client, ref, buffer, version, session_id, gen, pos}
    )
  end

  @doc "Tracks a legacy completion request that predates stable session ownership."
  @spec track_completion_result(
          t(),
          reference(),
          MingaEditor.CompletionTrigger.response_role(),
          pid(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          position()
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_completion_result(pending, ref, role, client, buffer, version, gen, pos) do
    track_request(pending, ref, {:completion_result, role, client, buffer, version, gen, pos})
  end

  @doc "Tracks one lazy resolve request by its full session and item identity."
  @spec track_completion_resolve(t(), MingaEditor.State.LSP.resolve_tracking_fact()) ::
          {:ok, t()} | {:error, :duplicate_ref}
  def track_completion_resolve(
        %__MODULE__{} = pending,
        {ref, client, buffer, version, session_id, gen, provider_id, item_id, raw_item}
      )
      when is_reference(ref) and is_pid(client) and is_pid(buffer) and is_integer(version) and
             version >= 0 and is_integer(gen) and gen >= 0 and is_map(raw_item) do
    track_request(
      pending,
      ref,
      {:completion_resolve, client, ref, buffer, version, session_id, gen, provider_id, item_id,
       raw_item}
    )
  end

  @doc "Tracks a legacy completion resolve request that predates stable item identity."
  @spec track_completion_resolve(
          t(),
          reference(),
          pid(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          map()
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_completion_resolve(pending, ref, client, buffer, version, gen, raw_item) do
    track_request(pending, ref, {:completion_resolve, client, buffer, version, gen, raw_item})
  end

  @spec track_signature_help(t(), reference(), pid(), pid(), non_neg_integer(), position()) ::
          {:ok, t()} | {:error, :duplicate_ref}
  def track_signature_help(%__MODULE__{} = pending, ref, client, buffer, version, cursor)
      when is_reference(ref) and is_pid(client) and is_pid(buffer) and is_integer(version) and
             version >= 0 and valid_cursor_guard(cursor) do
    track_request(pending, ref, {:signature_help, client, buffer, version, cursor})
  end

  @spec track_response(
          t(),
          reference(),
          MingaEditor.State.LSP.current_origin_response_kind(),
          pid(),
          pid(),
          non_neg_integer(),
          MingaEditor.State.Tab.id() | nil,
          {non_neg_integer(), non_neg_integer()} | nil
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_response(%__MODULE__{} = pending, ref, kind, client, buffer, version, tab_id, nil)
      when is_reference(ref) and is_pid(client) and is_pid(buffer) and is_integer(version) and
             kind in [
               :document_symbol,
               :workspace_symbol,
               :incoming_calls,
               :outgoing_calls,
               :code_lens,
               :code_lens_resolve
             ] and
             version >= 0 and (is_nil(tab_id) or (is_integer(tab_id) and tab_id > 0)) do
    track_request(pending, ref, {:response, kind, client, buffer, version, tab_id, nil})
  end

  def track_response(%__MODULE__{} = pending, ref, kind, client, buffer, version, tab_id, cursor)
      when is_reference(ref) and is_pid(client) and is_pid(buffer) and is_integer(version) and
             kind in [
               :definition,
               :peek_definition,
               :hover,
               :document_highlight,
               :code_action,
               :prepare_rename,
               :type_definition,
               :implementation,
               :selection_range,
               :prepare_call_hierarchy,
               :prepare_outgoing_hierarchy
             ] and
             version >= 0 and (is_nil(tab_id) or (is_integer(tab_id) and tab_id > 0)) and
             valid_cursor_guard(cursor) do
    track_request(pending, ref, {:response, kind, client, buffer, version, tab_id, cursor})
  end

  @spec track_workspace_response(
          t(),
          reference(),
          :code_action,
          Minga.LSP.DocumentContext.t(),
          MingaEditor.State.Tab.id() | nil,
          position()
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_workspace_response(
        %__MODULE__{} = pending,
        ref,
        :code_action,
        context,
        tab_id,
        cursor
      )
      when is_reference(ref) and is_struct(context, Minga.LSP.DocumentContext) and
             (is_nil(tab_id) or (is_integer(tab_id) and tab_id > 0)) and
             valid_cursor_guard(cursor) do
    track_workspace_request(pending, ref, context, tab_id, cursor)
  end

  @doc "Returns whether a workspace response generation is still current for its origin."
  @spec workspace_generation_current?(
          t(),
          :code_action,
          pid(),
          workspace_generation()
        ) :: boolean()
  def workspace_generation_current?(pending, :code_action, buffer, generation)
      when is_pid(buffer) and is_integer(generation) and generation > 0 do
    Map.get(pending.workspace_generations, {:code_action, buffer}) == generation
  end

  @spec track_inlay_hint(
          t(),
          reference(),
          pid(),
          pid(),
          non_neg_integer(),
          MingaEditor.State.Tab.id() | nil,
          non_neg_integer(),
          pos_integer()
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_inlay_hint(
        %__MODULE__{} = pending,
        ref,
        client,
        buffer,
        version,
        tab_id,
        viewport_top,
        viewport_rows
      )
      when is_reference(ref) and is_pid(client) and is_pid(buffer) and is_integer(version) and
             version >= 0 and (is_nil(tab_id) or (is_integer(tab_id) and tab_id > 0)) and
             is_integer(viewport_top) and viewport_top >= 0 and is_integer(viewport_rows) and
             viewport_rows > 0 do
    track_request(
      pending,
      ref,
      {:inlay_hint, client, buffer, version, tab_id, viewport_top, viewport_rows}
    )
  end

  @spec track_hover_mouse(
          t(),
          reference(),
          non_neg_integer(),
          non_neg_integer(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_hover_mouse(
        %__MODULE__{} = pending,
        ref,
        row,
        col,
        buffer,
        buffer_line,
        buffer_col,
        version
      )
      when is_reference(ref) and is_integer(row) and row >= 0 and is_integer(col) and col >= 0 and
             is_pid(buffer) and is_integer(buffer_line) and buffer_line >= 0 and
             is_integer(buffer_col) and buffer_col >= 0 and is_integer(version) and version >= 0 do
    track_request(
      pending,
      ref,
      {:hover_mouse, row, col, buffer, buffer_line, buffer_col, version}
    )
  end

  @spec track_semantic_tokens(
          t(),
          reference(),
          pid(),
          pid(),
          non_neg_integer(),
          Minga.LSP.PositionEncoding.encoding(),
          {[String.t()], [String.t()]}
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_semantic_tokens(
        %__MODULE__{} = pending,
        ref,
        client,
        buffer,
        version,
        encoding,
        {types, mods}
      )
      when is_reference(ref) and is_pid(client) and is_pid(buffer) and is_integer(version) and
             version >= 0 and encoding in [:utf8, :utf16, :utf32] and is_list(types) and
             is_list(mods) do
    track_request(
      pending,
      ref,
      {:semantic_tokens, client, buffer, version, encoding, {types, mods}}
    )
  end

  @spec track_operation(
          t(),
          reference(),
          operation_kind(),
          MingaEditor.State.Operation.id(),
          MingaEditor.State.Tab.id() | nil
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_operation(%__MODULE__{} = pending, ref, kind, operation_id, tab_id)
      when is_reference(ref) and kind in [:references, :rename] and is_integer(operation_id) and
             operation_id > 0 and (is_nil(tab_id) or (is_integer(tab_id) and tab_id > 0)) do
    track_request(pending, ref, {:operation, kind, operation_id, tab_id})
  end

  @spec track_workspace_operation(
          t(),
          reference(),
          :rename,
          MingaEditor.State.Operation.id(),
          MingaEditor.State.Tab.id() | nil,
          Minga.LSP.DocumentContext.t()
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_workspace_operation(
        %__MODULE__{} = pending,
        ref,
        :rename,
        operation_id,
        tab_id,
        context
      )
      when is_reference(ref) and is_integer(operation_id) and operation_id > 0 and
             (is_nil(tab_id) or (is_integer(tab_id) and tab_id > 0)) and
             is_struct(context, Minga.LSP.DocumentContext) do
    track_request(pending, ref, {:workspace_operation, :rename, operation_id, tab_id, context})
  end

  @spec track_format(t(), FormatOperation.t()) ::
          {:ok, t()} | {:error, :duplicate_ref | :buffer_busy}
  def track_format(%__MODULE__{} = pending, %FormatOperation{} = operation) do
    track_format_ref(Map.fetch(pending.by_ref, operation.ref), pending, operation)
  end

  @spec take(t(), reference()) :: {:ok, request(), t()} | :error
  def take(%__MODULE__{} = pending, ref) when is_reference(ref) do
    case Map.pop(pending.by_ref, ref) do
      {nil, _by_ref} ->
        :error

      {{:format, %FormatOperation{} = operation} = request, by_ref} ->
        {:ok, request, drop_format_indexes(%{pending | by_ref: by_ref}, operation, ref)}

      {request, by_ref} ->
        {:ok, request, %{pending | by_ref: by_ref}}
    end
  end

  @spec take_operations_for_tab(t(), MingaEditor.State.Tab.id()) :: {[request()], t()}
  def take_operations_for_tab(%__MODULE__{} = pending, tab_id)
      when is_integer(tab_id) and tab_id > 0 do
    {requests, by_ref} =
      Enum.reduce(pending.by_ref, {[], %{}}, fn
        {_ref, {:operation, _kind, _operation_id, ^tab_id} = request}, {requests, by_ref} ->
          {[request | requests], by_ref}

        {_ref, {:workspace_operation, _kind, _operation_id, ^tab_id, _context} = request},
        {requests, by_ref} ->
          {[request | requests], by_ref}

        {ref, request}, {requests, by_ref} ->
          {requests, Map.put(by_ref, ref, request)}
      end)

    {Enum.reverse(requests), %{pending | by_ref: by_ref}}
  end

  @spec drop_completion_requests(t()) :: t()
  def drop_completion_requests(%__MODULE__{} = pending) do
    by_ref =
      Map.reject(pending.by_ref, fn
        {_map_ref,
         {:completion_result, _role, _provider, _client, _request_ref, _buffer, _version,
          _session, _gen, _pos}} ->
          true

        {_map_ref,
         {:completion_resolve, _client, _request_ref, _buffer, _version, _session, _gen,
          _provider, _item, _raw_item}} ->
          true

        {_ref, {:completion_result, _role, _client, _buffer, _version, _gen, _pos}} ->
          true

        {_ref, {:completion_resolve, _client, _buffer, _version, _gen, _raw_item}} ->
          true

        {_ref, _request} ->
          false
      end)

    %{pending | by_ref: by_ref}
  end

  @doc "Drops pending workspace responses and generation state for a retired buffer."
  @spec retire_buffer(t(), pid()) :: t()
  def retire_buffer(%__MODULE__{} = pending, buffer) when is_pid(buffer) do
    by_ref =
      Map.reject(pending.by_ref, fn
        {_ref,
         {:workspace_response, :code_action, _generation, %{buffer: ^buffer}, _tab, _cursor}} ->
          true

        {_ref, _request} ->
          false
      end)

    %{
      pending
      | by_ref: by_ref,
        workspace_generations: Map.delete(pending.workspace_generations, {:code_action, buffer})
    }
  end

  @spec fetch(t(), reference()) :: {:ok, request()} | :error
  def fetch(%__MODULE__{} = pending, ref) when is_reference(ref),
    do: Map.fetch(pending.by_ref, ref)

  @spec fetch_format(t(), reference()) :: {:ok, FormatOperation.t()} | :error
  def fetch_format(%__MODULE__{} = pending, ref) when is_reference(ref) do
    case Map.fetch(pending.by_ref, ref) do
      {:ok, {:format, operation}} -> {:ok, operation}
      _ -> :error
    end
  end

  @spec format_for_buffer(t(), pid()) :: FormatOperation.t() | nil
  def format_for_buffer(%__MODULE__{} = pending, buffer) when is_pid(buffer) do
    with {:ok, ref} <- Map.fetch(pending.format_by_buffer, buffer),
         {:ok, operation} <- fetch_format(pending, ref) do
      operation
    else
      _ -> nil
    end
  end

  @spec newest_format(t()) :: FormatOperation.t() | nil
  def newest_format(%__MODULE__{newest_formats: [ref | _]} = pending) do
    case fetch_format(pending, ref) do
      {:ok, operation} -> operation
      :error -> nil
    end
  end

  def newest_format(%__MODULE__{}), do: nil

  @spec drop_format(t(), reference()) :: t()
  def drop_format(%__MODULE__{} = pending, ref) when is_reference(ref) do
    case Map.pop(pending.by_ref, ref) do
      {{:format, %FormatOperation{} = operation}, by_ref} ->
        drop_format_indexes(%{pending | by_ref: by_ref}, operation, ref)

      _ ->
        pending
    end
  end

  @spec format_active?(t(), reference()) :: boolean()
  def format_active?(%__MODULE__{} = pending, ref) when is_reference(ref),
    do: match?({:ok, %FormatOperation{}}, fetch_format(pending, ref))

  defp track_request(%__MODULE__{} = pending, ref, request) do
    if Map.has_key?(pending.by_ref, ref),
      do: {:error, :duplicate_ref},
      else: {:ok, %{pending | by_ref: Map.put(pending.by_ref, ref, request)}}
  end

  @spec track_workspace_request(
          t(),
          reference(),
          Minga.LSP.DocumentContext.t(),
          MingaEditor.State.Tab.id() | nil,
          position()
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  defp track_workspace_request(pending, ref, context, tab_id, cursor) do
    if Map.has_key?(pending.by_ref, ref) do
      {:error, :duplicate_ref}
    else
      generation = pending.next_workspace_generation
      key = {:code_action, context.buffer}
      by_ref = drop_workspace_requests(pending.by_ref, context.buffer)

      request =
        {:workspace_response, :code_action, generation, context, tab_id, cursor}

      {:ok,
       %{
         pending
         | by_ref: Map.put(by_ref, ref, request),
           workspace_generations: Map.put(pending.workspace_generations, key, generation),
           next_workspace_generation: generation + 1
       }}
    end
  end

  @spec drop_workspace_requests(%{reference() => request()}, pid()) :: %{
          reference() => request()
        }
  defp drop_workspace_requests(by_ref, buffer) do
    Map.reject(by_ref, fn
      {_ref, {:workspace_response, :code_action, _generation, %{buffer: ^buffer}, _tab, _cursor}} ->
        true

      {_ref, _request} ->
        false
    end)
  end

  defp track_format_ref({:ok, _request}, %__MODULE__{}, %FormatOperation{}),
    do: {:error, :duplicate_ref}

  defp track_format_ref(:error, %__MODULE__{} = pending, %FormatOperation{} = operation) do
    track_format_buffer(Map.fetch(pending.format_by_buffer, operation.buffer), pending, operation)
  end

  defp track_format_buffer({:ok, _ref}, %__MODULE__{}, %FormatOperation{}),
    do: {:error, :buffer_busy}

  defp track_format_buffer(:error, %__MODULE__{} = pending, %FormatOperation{} = operation) do
    {:ok,
     %__MODULE__{
       pending
       | by_ref: Map.put(pending.by_ref, operation.ref, {:format, operation}),
         format_by_buffer: Map.put(pending.format_by_buffer, operation.buffer, operation.ref),
         newest_formats: [operation.ref | pending.newest_formats]
     }}
  end

  defp drop_format_indexes(%__MODULE__{} = pending, %FormatOperation{} = operation, ref) do
    %__MODULE__{
      pending
      | format_by_buffer: Map.delete(pending.format_by_buffer, operation.buffer),
        newest_formats: List.delete(pending.newest_formats, ref)
    }
  end
end
