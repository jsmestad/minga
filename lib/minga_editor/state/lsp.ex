defmodule MingaEditor.State.LSP do
  @moduledoc """
  LSP coordination state for the Editor.

  Groups the Editor's LSP-related fields into a focused sub-struct:
  server status tracking, cached responses (code lenses, inlay hints,
  selection ranges), and debounce timers for highlight and inlay hint
  requests.

  All mutations go through functions on this module. Other modules
  read fields directly but never do `%{lsp | field: value}`.
  """

  alias MingaEditor.State.LSP.FormatOperation
  alias MingaEditor.State.LSP.PendingRequests

  @type server_status :: :starting | :initializing | :ready | :crashed
  @type legacy_response_kind :: :code_lens | :code_lens_resolve | :inlay_hint
  @type current_origin_response_kind ::
          :definition
          | :peek_definition
          | :hover
          | :document_highlight
          | :code_action
          | :prepare_rename
          | :type_definition
          | :implementation
          | :document_symbol
          | :workspace_symbol
          | :selection_range
          | :prepare_call_hierarchy
          | :prepare_outgoing_hierarchy
          | :incoming_calls
          | :outgoing_calls
  @type response_kind :: legacy_response_kind() | current_origin_response_kind()
  @type pending_request :: PendingRequests.request()
  @type operation_request ::
          {:operation, :references | :rename, MingaEditor.State.Operation.id(),
           MingaEditor.State.Tab.id() | nil}

  @type t :: %__MODULE__{
          status: MingaEditor.Shell.Traditional.Modeline.lsp_status(),
          server_statuses: %{atom() => server_status()},
          code_lenses: [map()],
          inlay_hints: [map()],
          selection_ranges: [map()] | nil,
          selection_range_index: non_neg_integer(),
          pending_requests: PendingRequests.t(),
          highlight_debounce_timer: reference() | nil,
          inlay_hint_debounce_timer: reference() | nil,
          last_inlay_viewport_top: non_neg_integer() | nil
        }

  defstruct status: :none,
            server_statuses: %{},
            code_lenses: [],
            inlay_hints: [],
            selection_ranges: nil,
            selection_range_index: 0,
            pending_requests: PendingRequests.new(),
            highlight_debounce_timer: nil,
            inlay_hint_debounce_timer: nil,
            last_inlay_viewport_top: nil

  # ── Status tracking ──────────────────────────────────────────────────────

  @doc """
  Updates a single server's status and re-derives the aggregate status.

  When `status` is `:stopped`, the server is removed from the map entirely.
  """
  @spec update_server_status(t(), atom(), atom()) :: t()
  def update_server_status(%__MODULE__{} = lsp, name, status) do
    server_statuses =
      case status do
        :stopped -> Map.delete(lsp.server_statuses, name)
        s -> Map.put(lsp.server_statuses, name, s)
      end

    %{lsp | server_statuses: server_statuses, status: aggregate(server_statuses)}
  end

  # ── Code lenses ──────────────────────────────────────────────────────────

  @doc "Replaces the stored code lenses."
  @spec set_code_lenses(t(), [map()]) :: t()
  def set_code_lenses(%__MODULE__{} = lsp, lenses) when is_list(lenses) do
    %{lsp | code_lenses: lenses}
  end

  @doc "Appends a single resolved code lens entry."
  @spec append_code_lens(t(), map()) :: t()
  def append_code_lens(%__MODULE__{} = lsp, entry) when is_map(entry) do
    %{lsp | code_lenses: Enum.concat(lsp.code_lenses, [entry])}
  end

  # ── Inlay hints ──────────────────────────────────────────────────────────

  @doc "Replaces the stored inlay hints."
  @spec set_inlay_hints(t(), [map()]) :: t()
  def set_inlay_hints(%__MODULE__{} = lsp, hints) when is_list(hints) do
    %{lsp | inlay_hints: hints}
  end

  # ── Selection ranges ─────────────────────────────────────────────────────

  @doc "Stores a selection range chain and resets the index to 0."
  @spec set_selection_ranges(t(), [map()]) :: t()
  def set_selection_ranges(%__MODULE__{} = lsp, ranges) when is_list(ranges) do
    %{lsp | selection_ranges: ranges, selection_range_index: 0}
  end

  @doc "Clears the stored selection ranges and resets the index."
  @spec clear_selection_ranges(t()) :: t()
  def clear_selection_ranges(%__MODULE__{} = lsp) do
    %{lsp | selection_ranges: nil, selection_range_index: 0}
  end

  @doc "Moves the selection range index forward (expand) by one step."
  @spec expand_selection(t()) :: t()
  def expand_selection(%__MODULE__{selection_range_index: idx} = lsp) do
    %{lsp | selection_range_index: idx + 1}
  end

  @doc "Moves the selection range index backward (shrink) by one step."
  @spec shrink_selection(t()) :: t()
  def shrink_selection(%__MODULE__{selection_range_index: idx} = lsp) when idx > 0 do
    %{lsp | selection_range_index: idx - 1}
  end

  # ── Pending requests and formatting operations ────────────────────────────
  @spec track_response_request(t(), reference(), legacy_response_kind()) :: t()
  def track_response_request(%__MODULE__{} = lsp, ref, kind) when is_reference(ref) do
    {:ok, pending_requests} = PendingRequests.track_response(lsp.pending_requests, ref, kind)
    %{lsp | pending_requests: pending_requests}
  end

  @spec track_response_request(
          t(),
          reference(),
          current_origin_response_kind(),
          pid(),
          pid(),
          non_neg_integer(),
          MingaEditor.State.Tab.id() | nil,
          {non_neg_integer(), non_neg_integer()} | nil
        ) :: t()
  def track_response_request(
        %__MODULE__{} = lsp,
        ref,
        kind,
        client,
        buffer,
        version,
        tab_id,
        cursor
      )
      when is_reference(ref) do
    {:ok, pending_requests} =
      PendingRequests.track_response(
        lsp.pending_requests,
        ref,
        kind,
        client,
        buffer,
        version,
        tab_id,
        cursor
      )

    %{lsp | pending_requests: pending_requests}
  end

  @spec track_completion_result_request(
          t(),
          reference(),
          MingaEditor.CompletionTrigger.response_role(),
          pid(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()}
        ) :: t()
  def track_completion_result_request(
        %__MODULE__{} = lsp,
        ref,
        role,
        client,
        buffer,
        version,
        gen,
        pos
      ) do
    accept_pending(
      lsp,
      PendingRequests.track_completion_result(
        lsp.pending_requests,
        ref,
        role,
        client,
        buffer,
        version,
        gen,
        pos
      )
    )
  end

  @spec track_completion_resolve_request(
          t(),
          reference(),
          pid(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          map()
        ) :: t()
  def track_completion_resolve_request(
        %__MODULE__{} = lsp,
        ref,
        client,
        buffer,
        version,
        gen,
        raw_item
      ) do
    accept_pending(
      lsp,
      PendingRequests.track_completion_resolve(
        lsp.pending_requests,
        ref,
        client,
        buffer,
        version,
        gen,
        raw_item
      )
    )
  end

  @spec track_signature_help_request(
          t(),
          reference(),
          pid(),
          pid(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()}
        ) :: t()
  def track_signature_help_request(%__MODULE__{} = lsp, ref, client, buffer, version, cursor) do
    accept_pending(
      lsp,
      PendingRequests.track_signature_help(
        lsp.pending_requests,
        ref,
        client,
        buffer,
        version,
        cursor
      )
    )
  end

  @doc "Tracks an Editor-global mouse hover request."
  @spec track_hover_mouse_request(
          t(),
          reference(),
          non_neg_integer(),
          non_neg_integer(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def track_hover_mouse_request(
        %__MODULE__{} = lsp,
        ref,
        row,
        col,
        buffer,
        buffer_line,
        buffer_col,
        version
      ) do
    {:ok, pending_requests} =
      PendingRequests.track_hover_mouse(
        lsp.pending_requests,
        ref,
        row,
        col,
        buffer,
        buffer_line,
        buffer_col,
        version
      )

    %{lsp | pending_requests: pending_requests}
  end

  @doc "Tracks an Editor-global semantic token request."
  @spec track_semantic_tokens_request(t(), reference(), pid()) :: t()
  def track_semantic_tokens_request(%__MODULE__{} = lsp, ref, buffer) when is_reference(ref) do
    {:ok, pending_requests} =
      PendingRequests.track_semantic_tokens(lsp.pending_requests, ref, buffer)

    %{lsp | pending_requests: pending_requests}
  end

  @doc "Tracks an Editor-global LSP request for a structured operation."
  @spec track_operation_request(
          t(),
          reference(),
          :references | :rename,
          MingaEditor.State.Operation.id(),
          MingaEditor.State.Tab.id() | nil
        ) :: t()
  def track_operation_request(%__MODULE__{} = lsp, ref, kind, operation_id, tab_id) do
    {:ok, pending_requests} =
      PendingRequests.track_operation(lsp.pending_requests, ref, kind, operation_id, tab_id)

    %{lsp | pending_requests: pending_requests}
  end

  @doc "Tracks an Editor-global formatting operation."
  @spec track_format(t(), FormatOperation.t()) :: t()
  def track_format(%__MODULE__{} = lsp, %FormatOperation{} = operation) do
    {:ok, pending_requests} = PendingRequests.track_format(lsp.pending_requests, operation)
    %{lsp | pending_requests: pending_requests}
  end

  @doc "Takes an Editor-global LSP request by response reference."
  @spec take_pending_request(t(), reference()) :: {:ok, pending_request(), t()} | :error
  def take_pending_request(%__MODULE__{} = lsp, ref) when is_reference(ref) do
    case PendingRequests.take(lsp.pending_requests, ref) do
      {:ok, request, pending_requests} ->
        {:ok, request, %{lsp | pending_requests: pending_requests}}

      :error ->
        :error
    end
  end

  @doc "Takes all structured operation requests originating from one departing tab."
  @spec take_operation_requests_for_tab(t(), pos_integer()) :: {[operation_request()], t()}
  def take_operation_requests_for_tab(%__MODULE__{} = lsp, tab_id) do
    {requests, pending_requests} =
      PendingRequests.take_operations_for_tab(lsp.pending_requests, tab_id)

    {requests, %{lsp | pending_requests: pending_requests}}
  end

  @doc "Fetches an Editor-global LSP pending request by response reference."
  @spec fetch_pending_request(t(), reference()) :: {:ok, pending_request()} | :error
  def fetch_pending_request(%__MODULE__{} = lsp, ref) when is_reference(ref) do
    PendingRequests.fetch(lsp.pending_requests, ref)
  end

  @doc "Fetches a formatting operation by request reference."
  @spec fetch_format(t(), reference()) :: {:ok, FormatOperation.t()} | :error
  def fetch_format(%__MODULE__{} = lsp, ref) when is_reference(ref) do
    PendingRequests.fetch_format(lsp.pending_requests, ref)
  end

  @doc "Returns the formatting operation for one Buffer."
  @spec format_for_buffer(t(), pid()) :: FormatOperation.t() | nil
  def format_for_buffer(%__MODULE__{} = lsp, buffer) when is_pid(buffer) do
    PendingRequests.format_for_buffer(lsp.pending_requests, buffer)
  end

  @doc "Returns the newest active formatting operation."
  @spec newest_format(t()) :: FormatOperation.t() | nil
  def newest_format(%__MODULE__{} = lsp), do: PendingRequests.newest_format(lsp.pending_requests)

  @doc "Drops a formatting operation by request reference."
  @spec drop_format(t(), reference()) :: t()
  def drop_format(%__MODULE__{} = lsp, ref) when is_reference(ref) do
    %{lsp | pending_requests: PendingRequests.drop_format(lsp.pending_requests, ref)}
  end

  @doc "Returns whether a formatting operation is active."
  @spec format_active?(t(), reference()) :: boolean()
  def format_active?(%__MODULE__{} = lsp, ref) when is_reference(ref) do
    PendingRequests.format_active?(lsp.pending_requests, ref)
  end

  # ── Highlight debounce timer ─────────────────────────────────────────────

  @doc "Sets the highlight debounce timer reference."
  @spec set_highlight_timer(t(), reference()) :: t()
  def set_highlight_timer(%__MODULE__{} = lsp, timer) when is_reference(timer) do
    %{lsp | highlight_debounce_timer: timer}
  end

  @doc "Returns a pure instruction for canceling the highlight debounce timer."
  @spec cancel_highlight_timer(t()) :: {:cancel_timer, t(), reference() | nil}
  def cancel_highlight_timer(%__MODULE__{highlight_debounce_timer: nil} = lsp),
    do: {:cancel_timer, lsp, nil}

  def cancel_highlight_timer(%__MODULE__{highlight_debounce_timer: timer} = lsp) do
    {:cancel_timer, %{lsp | highlight_debounce_timer: nil}, timer}
  end

  # ── Inlay hint debounce timer ────────────────────────────────────────────

  @doc "Sets the inlay hint debounce timer and records the viewport top."
  @spec set_inlay_hint_timer(t(), reference(), non_neg_integer()) :: t()
  def set_inlay_hint_timer(%__MODULE__{} = lsp, timer, viewport_top)
      when is_reference(timer) do
    %{lsp | inlay_hint_debounce_timer: timer, last_inlay_viewport_top: viewport_top}
  end

  @doc "Records the viewport top used by the latest inlay-hint request."
  @spec remember_inlay_viewport(t(), non_neg_integer()) :: t()
  def remember_inlay_viewport(%__MODULE__{} = lsp, viewport_top) do
    %{lsp | last_inlay_viewport_top: viewport_top}
  end

  @doc "Returns a pure instruction for canceling the inlay hint debounce timer."
  @spec cancel_inlay_hint_timer(t()) :: {:cancel_timer, t(), reference() | nil}
  def cancel_inlay_hint_timer(%__MODULE__{inlay_hint_debounce_timer: nil} = lsp),
    do: {:cancel_timer, lsp, nil}

  def cancel_inlay_hint_timer(%__MODULE__{inlay_hint_debounce_timer: timer} = lsp) do
    {:cancel_timer, %{lsp | inlay_hint_debounce_timer: nil}, timer}
  end

  @doc "Clears the inlay hint debounce timer reference without cancelling it."
  @spec clear_inlay_hint_timer(t()) :: t()
  def clear_inlay_hint_timer(%__MODULE__{} = lsp) do
    %{lsp | inlay_hint_debounce_timer: nil}
  end

  @spec accept_pending(t(), {:ok, PendingRequests.t()}) :: t()
  defp accept_pending(%__MODULE__{} = lsp, {:ok, pending_requests}),
    do: %{lsp | pending_requests: pending_requests}

  @doc "Clears the highlight debounce timer reference without cancelling it."
  @spec clear_highlight_timer(t()) :: t()
  def clear_highlight_timer(%__MODULE__{} = lsp) do
    %{lsp | highlight_debounce_timer: nil}
  end

  # ── Aggregation ──────────────────────────────────────────────────────────

  # Derives an aggregate LSP status from the per-server status map.
  # Priority: :ready > :error > :initializing > :starting > :none
  @spec aggregate(%{atom() => server_status()}) ::
          MingaEditor.Shell.Traditional.Modeline.lsp_status()
  defp aggregate(server_statuses) when server_statuses == %{}, do: :none

  defp aggregate(server_statuses) do
    server_statuses
    |> Map.values()
    |> Enum.reduce(:none, fn
      :ready, _acc -> :ready
      _status, :ready -> :ready
      :crashed, _acc -> :error
      _status, :error -> :error
      :initializing, _acc -> :initializing
      _status, :initializing -> :initializing
      :starting, _acc -> :starting
      _status, :starting -> :starting
      _status, acc -> acc
    end)
  end
end
