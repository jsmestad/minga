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
  alias MingaEditor.State.LSP.FormatOperations

  @type server_status :: :starting | :initializing | :ready | :crashed
  @type operation_request :: {:references | :rename, pos_integer(), pos_integer() | nil}

  @type t :: %__MODULE__{
          status: MingaEditor.Shell.Traditional.Modeline.lsp_status(),
          server_statuses: %{atom() => server_status()},
          code_lenses: [map()],
          inlay_hints: [map()],
          selection_ranges: [map()] | nil,
          selection_range_index: non_neg_integer(),
          format_operations: FormatOperations.t(),
          operation_requests: %{reference() => operation_request()},
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
            format_operations: FormatOperations.new(),
            operation_requests: %{},
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

  # ── Formatting operations ────────────────────────────────────────────────

  @doc "Tracks an Editor-global formatting operation."
  @spec track_format(t(), FormatOperation.t()) :: t()
  def track_format(%__MODULE__{} = lsp, %FormatOperation{} = operation) do
    {:ok, operations} = FormatOperations.track(lsp.format_operations, operation)
    %{lsp | format_operations: operations}
  end

  @doc "Fetches a formatting operation by request reference."
  @spec fetch_format(t(), reference()) :: {:ok, FormatOperation.t()} | :error
  def fetch_format(%__MODULE__{} = lsp, ref) when is_reference(ref) do
    FormatOperations.fetch(lsp.format_operations, ref)
  end

  @doc "Returns the formatting operation for one Buffer."
  @spec format_for_buffer(t(), pid()) :: FormatOperation.t() | nil
  def format_for_buffer(%__MODULE__{} = lsp, buffer) when is_pid(buffer) do
    FormatOperations.for_buffer(lsp.format_operations, buffer)
  end

  @doc "Returns the newest active formatting operation."
  @spec newest_format(t()) :: FormatOperation.t() | nil
  def newest_format(%__MODULE__{} = lsp), do: FormatOperations.newest(lsp.format_operations)

  @doc "Drops a formatting operation by request reference."
  @spec drop_format(t(), reference()) :: t()
  def drop_format(%__MODULE__{} = lsp, ref) when is_reference(ref) do
    %{lsp | format_operations: FormatOperations.drop(lsp.format_operations, ref)}
  end

  @doc "Returns whether a formatting operation is active."
  @spec format_active?(t(), reference()) :: boolean()
  def format_active?(%__MODULE__{} = lsp, ref) when is_reference(ref) do
    match?({:ok, %FormatOperation{}}, fetch_format(lsp, ref))
  end

  # ── Correlated operation requests ────────────────────────────────────────

  @doc "Tracks an Editor-global LSP request for a structured operation."
  @spec track_operation_request(t(), reference(), operation_request()) :: t()
  def track_operation_request(%__MODULE__{} = lsp, ref, {kind, operation_id, tab_id} = request)
      when is_reference(ref) and kind in [:references, :rename] and is_integer(operation_id) and
             operation_id > 0 and (is_nil(tab_id) or (is_integer(tab_id) and tab_id > 0)) do
    %{lsp | operation_requests: Map.put(lsp.operation_requests, ref, request)}
  end

  @doc "Takes an Editor-global LSP operation request by response reference."
  @spec take_operation_request(t(), reference()) ::
          {:ok, operation_request(), t()} | :error
  def take_operation_request(%__MODULE__{} = lsp, ref) when is_reference(ref) do
    case Map.pop(lsp.operation_requests, ref) do
      {nil, _requests} -> :error
      {request, requests} -> {:ok, request, %{lsp | operation_requests: requests}}
    end
  end

  @doc "Takes all structured operation requests originating from one departing tab."
  @spec take_operation_requests_for_tab(t(), pos_integer()) :: {[operation_request()], t()}
  def take_operation_requests_for_tab(%__MODULE__{} = lsp, tab_id)
      when is_integer(tab_id) and tab_id > 0 do
    {requests, retained} =
      Enum.reduce(lsp.operation_requests, {[], %{}}, fn
        {_ref, {_kind, _operation_id, ^tab_id} = request}, {requests, retained} ->
          {[request | requests], retained}

        {ref, request}, {requests, retained} ->
          {requests, Map.put(retained, ref, request)}
      end)

    {Enum.reverse(requests), %{lsp | operation_requests: retained}}
  end

  # ── Highlight debounce timer ─────────────────────────────────────────────

  @doc "Sets the highlight debounce timer reference."
  @spec set_highlight_timer(t(), reference()) :: t()
  def set_highlight_timer(%__MODULE__{} = lsp, timer) when is_reference(timer) do
    %{lsp | highlight_debounce_timer: timer}
  end

  @doc "Cancels the highlight debounce timer and clears the reference."
  @spec cancel_highlight_timer(t()) :: t()
  def cancel_highlight_timer(%__MODULE__{highlight_debounce_timer: nil} = lsp), do: lsp

  def cancel_highlight_timer(%__MODULE__{highlight_debounce_timer: timer} = lsp) do
    Process.cancel_timer(timer)
    %{lsp | highlight_debounce_timer: nil}
  end

  # ── Inlay hint debounce timer ────────────────────────────────────────────

  @doc "Sets the inlay hint debounce timer and records the viewport top."
  @spec set_inlay_hint_timer(t(), reference(), non_neg_integer()) :: t()
  def set_inlay_hint_timer(%__MODULE__{} = lsp, timer, viewport_top)
      when is_reference(timer) do
    %{lsp | inlay_hint_debounce_timer: timer, last_inlay_viewport_top: viewport_top}
  end

  @doc "Cancels the inlay hint debounce timer and clears the reference."
  @spec cancel_inlay_hint_timer(t()) :: t()
  def cancel_inlay_hint_timer(%__MODULE__{inlay_hint_debounce_timer: nil} = lsp), do: lsp

  def cancel_inlay_hint_timer(%__MODULE__{inlay_hint_debounce_timer: timer} = lsp) do
    Process.cancel_timer(timer)
    %{lsp | inlay_hint_debounce_timer: nil}
  end

  @doc "Clears the inlay hint debounce timer reference without cancelling it."
  @spec clear_inlay_hint_timer(t()) :: t()
  def clear_inlay_hint_timer(%__MODULE__{} = lsp) do
    %{lsp | inlay_hint_debounce_timer: nil}
  end

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
