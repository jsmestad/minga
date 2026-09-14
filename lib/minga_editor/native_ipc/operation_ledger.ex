defmodule MingaEditor.NativeIPC.OperationLedger do
  @moduledoc "Bounded in-memory receipt owner used by the existing native IPC server."

  alias MingaEditor.NativeIPC.Identity
  alias MingaEditor.NativeIPC.OperationReceipt
  alias MingaEditor.NativeIPC.OperationReceipt.Evidence
  alias MingaEditor.NativeIPC.OperationNativeResult

  @max_active 64
  @max_terminal 128
  @max_expired 128
  @retention_ms 60_000
  @active_retention_ms 30_000

  defstruct active: %{}, terminal: %{}, terminal_order: [], expired: MapSet.new()

  @type t :: %__MODULE__{
          active: %{optional(pos_integer()) => OperationReceipt.t()},
          terminal: %{optional(pos_integer()) => OperationReceipt.t()},
          terminal_order: [pos_integer()],
          expired: MapSet.t(pos_integer())
        }

  @doc "Shipping active operation bound."
  @spec max_active() :: pos_integer()
  def max_active, do: @max_active

  @doc "Shipping retained terminal receipt bound."
  @spec max_terminal() :: pos_integer()
  def max_terminal, do: @max_terminal

  @doc "Shipping receipt retention duration in milliseconds."
  @spec retention_ms() :: pos_integer()
  def retention_ms, do: @retention_ms

  @doc "Maximum lifetime for an operation that never receives native completion."
  @spec active_retention_ms() :: pos_integer()
  def active_retention_ms, do: @active_retention_ms

  @spec admit(t(), Identity.t(), String.t(), non_neg_integer(), integer()) ::
          {:ok, OperationReceipt.t(), t()} | {:error, :operation_capacity, t()}
  def admit(%__MODULE__{} = ledger, %Identity{} = identity, path, token, now_ms) do
    ledger = expire_terminal(ledger, now_ms)

    if map_size(ledger.active) >= @max_active do
      {:error, :operation_capacity, ledger}
    else
      operation_id = unique_id(ledger)

      receipt =
        OperationReceipt.admit(
          identity.app_instance_id,
          identity.core_instance_id,
          operation_id,
          path,
          token,
          now_ms
        )

      {:ok, receipt, %{ledger | active: Map.put(ledger.active, operation_id, receipt)}}
    end
  end

  @spec applied(t(), pos_integer(), non_neg_integer(), non_neg_integer(), integer()) ::
          {:ok, OperationReceipt.t(), t()} | {:error, :unknown_operation, t()}
  def applied(%__MODULE__{} = ledger, operation_id, window_id, revision, now_ms) do
    update_active(ledger, operation_id, fn receipt ->
      OperationReceipt.applied(receipt, window_id, revision, now_ms)
    end)
  end

  @spec finish(
          t(),
          pos_integer(),
          OperationReceipt.outcome(),
          Evidence.t() | nil,
          Evidence.t() | nil,
          integer()
        ) :: {:ok, OperationReceipt.t(), t()} | {:error, :unknown_operation, t()}
  def finish(%__MODULE__{} = ledger, operation_id, outcome, evidence, last_visible, now_ms) do
    finish(ledger, operation_id, outcome, evidence, last_visible, nil, now_ms)
  end

  @spec finish(
          t(),
          pos_integer(),
          OperationReceipt.outcome(),
          Evidence.t() | nil,
          Evidence.t() | nil,
          String.t() | nil,
          integer()
        ) :: {:ok, OperationReceipt.t(), t()} | {:error, :unknown_operation, t()}
  def finish(
        %__MODULE__{} = ledger,
        operation_id,
        outcome,
        evidence,
        last_visible,
        detail,
        now_ms
      ) do
    case Map.pop(ledger.active, operation_id) do
      {nil, active} ->
        case Map.fetch(ledger.terminal, operation_id) do
          {:ok, receipt} -> {:ok, receipt, %{ledger | active: active}}
          :error -> {:error, :unknown_operation, %{ledger | active: active}}
        end

      {%OperationReceipt{} = receipt, active} ->
        receipt =
          OperationReceipt.finish(receipt, outcome, evidence, last_visible, detail, now_ms)

        ledger = %{ledger | active: active}
        {:ok, receipt, retain_terminal(ledger, receipt, now_ms)}
    end
  end

  @doc "Finishes an applied operation only when native evidence matches its exact target."
  @spec finish_native(t(), OperationNativeResult.t(), integer()) ::
          {:ok, OperationReceipt.t(), t()}
          | {:error, :unknown_operation | :correlation_mismatch, t()}
  def finish_native(%__MODULE__{} = ledger, %OperationNativeResult{} = result, now_ms) do
    case Map.get(ledger.active, result.operation_id) do
      %OperationReceipt{
        phase: :applied,
        target: target,
        application_revision: application_revision
      } = receipt
      when target.token == result.target_token and target.window_id == result.evidence.window_id and
             result.evidence.target_token == result.target_token and
             result.evidence.application_revision >= application_revision ->
        finish_correlated_native(ledger, receipt, result, now_ms)

      %OperationReceipt{} ->
        {:error, :correlation_mismatch, ledger}

      nil ->
        finish_missing_native(ledger, result)
    end
  end

  @spec finish_correlated_native(t(), OperationReceipt.t(), OperationNativeResult.t(), integer()) ::
          {:ok, OperationReceipt.t(), t()} | {:error, :correlation_mismatch, t()}
  defp finish_correlated_native(ledger, receipt, result, now_ms) do
    if valid_native_outcome?(receipt, result) do
      finish(
        ledger,
        result.operation_id,
        result.outcome,
        result.evidence,
        result.last_visible,
        now_ms
      )
    else
      {:error, :correlation_mismatch, ledger}
    end
  end

  @spec valid_native_outcome?(OperationReceipt.t(), OperationNativeResult.t()) :: boolean()
  defp valid_native_outcome?(
         %OperationReceipt{postcondition: :editor_visible_focused},
         %OperationNativeResult{
           outcome: :ready,
           evidence: %Evidence{boundary: :metal_drawable_completed, focus_ready: true}
         }
       ),
       do: true

  defp valid_native_outcome?(%OperationReceipt{}, %OperationNativeResult{outcome: :ready}),
    do: false

  defp valid_native_outcome?(%OperationReceipt{}, %OperationNativeResult{}), do: true

  @spec finish_missing_native(t(), OperationNativeResult.t()) ::
          {:ok, OperationReceipt.t(), t()}
          | {:error, :unknown_operation | :correlation_mismatch, t()}
  defp finish_missing_native(ledger, result) do
    case Map.fetch(ledger.terminal, result.operation_id) do
      {:ok, receipt} -> finish_duplicate_native(ledger, receipt, result)
      :error -> {:error, :unknown_operation, ledger}
    end
  end

  @spec finish_duplicate_native(t(), OperationReceipt.t(), OperationNativeResult.t()) ::
          {:ok, OperationReceipt.t(), t()} | {:error, :correlation_mismatch, t()}
  defp finish_duplicate_native(ledger, receipt, result) do
    if receipt.target.token == result.target_token and receipt.outcome == result.outcome and
         receipt.evidence == result.evidence and receipt.last_visible == result.last_visible do
      {:ok, receipt, ledger}
    else
      {:error, :correlation_mismatch, ledger}
    end
  end

  @spec lookup(t(), Identity.t(), String.t(), String.t(), pos_integer(), integer()) ::
          {:ok, OperationReceipt.t(), t()}
          | {:error, :app_replaced | :core_replaced | :expired | :unknown, t()}
  def lookup(
        %__MODULE__{} = ledger,
        %Identity{} = identity,
        app_id,
        core_id,
        operation_id,
        now_ms
      ) do
    ledger = expire_terminal(ledger, now_ms)

    case identity_error(identity, app_id, core_id) do
      nil -> lookup_current(ledger, operation_id)
      reason -> {:error, reason, ledger}
    end
  end

  @spec counts(t()) :: %{
          active: non_neg_integer(),
          terminal: non_neg_integer(),
          expired: non_neg_integer()
        }
  def counts(%__MODULE__{} = ledger) do
    %{
      active: map_size(ledger.active),
      terminal: map_size(ledger.terminal),
      expired: MapSet.size(ledger.expired)
    }
  end

  @doc "Expires retained terminal receipts and terminates abandoned active operations."
  @spec sweep(t(), integer()) :: {t(), [OperationReceipt.t()]}
  def sweep(%__MODULE__{} = ledger, now_ms) do
    ledger = expire_terminal(ledger, now_ms)

    ledger.active
    |> Map.values()
    |> Enum.filter(&(now_ms - &1.admitted_at_ms >= @active_retention_ms))
    |> Enum.reduce({ledger, []}, fn receipt, {current, expired_receipts} ->
      {:ok, terminal, current} =
        finish(current, receipt.operation_id, :indeterminate, nil, nil, now_ms)

      {current, [terminal | expired_receipts]}
    end)
  end

  @spec update_active(t(), pos_integer(), (OperationReceipt.t() -> OperationReceipt.t())) ::
          {:ok, OperationReceipt.t(), t()} | {:error, :unknown_operation, t()}
  defp update_active(ledger, operation_id, update) do
    case Map.fetch(ledger.active, operation_id) do
      {:ok, receipt} ->
        receipt = update.(receipt)
        {:ok, receipt, %{ledger | active: Map.put(ledger.active, operation_id, receipt)}}

      :error ->
        {:error, :unknown_operation, ledger}
    end
  end

  @spec lookup_current(t(), pos_integer()) ::
          {:ok, OperationReceipt.t(), t()} | {:error, :expired | :unknown, t()}
  defp lookup_current(ledger, operation_id) do
    case Map.get(ledger.active, operation_id) || Map.get(ledger.terminal, operation_id) do
      %OperationReceipt{} = receipt -> {:ok, receipt, ledger}
      nil -> lookup_missing(ledger, operation_id)
    end
  end

  @spec lookup_missing(t(), pos_integer()) :: {:error, :expired | :unknown, t()}
  defp lookup_missing(ledger, operation_id) do
    if MapSet.member?(ledger.expired, operation_id),
      do: {:error, :expired, ledger},
      else: {:error, :unknown, ledger}
  end

  @spec identity_error(Identity.t(), String.t(), String.t()) ::
          :app_replaced | :core_replaced | nil
  defp identity_error(identity, app_id, _core_id) when identity.app_instance_id != app_id,
    do: :app_replaced

  defp identity_error(identity, _app_id, core_id) when identity.core_instance_id != core_id,
    do: :core_replaced

  defp identity_error(_identity, _app_id, _core_id), do: nil

  @spec expire_terminal(t(), integer()) :: t()
  defp expire_terminal(%__MODULE__{} = ledger, now_ms) do
    {expired_ids, kept_order} =
      Enum.split_with(ledger.terminal_order, fn operation_id ->
        case Map.get(ledger.terminal, operation_id) do
          %OperationReceipt{terminal_at_ms: terminal_at_ms} when is_integer(terminal_at_ms) ->
            now_ms - terminal_at_ms >= @retention_ms

          _other ->
            true
        end
      end)

    terminal = Map.drop(ledger.terminal, expired_ids)
    expired = remember_expired(ledger.expired, expired_ids)
    %{ledger | terminal: terminal, terminal_order: kept_order, expired: expired}
  end

  @spec retain_terminal(t(), OperationReceipt.t(), integer()) :: t()
  defp retain_terminal(ledger, receipt, now_ms) do
    ledger = expire_terminal(ledger, now_ms)
    # The history is bounded to 128 entries and expires oldest-first.
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    order = ledger.terminal_order ++ [receipt.operation_id]
    terminal = Map.put(ledger.terminal, receipt.operation_id, receipt)
    trim_terminal(%{ledger | terminal: terminal, terminal_order: order})
  end

  @spec trim_terminal(t()) :: t()
  defp trim_terminal(%__MODULE__{} = ledger) when map_size(ledger.terminal) <= @max_terminal,
    do: ledger

  defp trim_terminal(%__MODULE__{terminal_order: [oldest | rest]} = ledger) do
    %{
      ledger
      | terminal: Map.delete(ledger.terminal, oldest),
        terminal_order: rest,
        expired: remember_expired(ledger.expired, [oldest])
    }
    |> trim_terminal()
  end

  @spec remember_expired(MapSet.t(pos_integer()), [pos_integer()]) :: MapSet.t(pos_integer())
  defp remember_expired(expired, ids) do
    remembered = Enum.reduce(ids, expired, &MapSet.put(&2, &1))

    if MapSet.size(remembered) <= @max_expired do
      remembered
    else
      remembered |> Enum.sort() |> Enum.take(-@max_expired) |> MapSet.new()
    end
  end

  @spec unique_id(t()) :: pos_integer()
  defp unique_id(ledger) do
    <<candidate::unsigned-64>> = :crypto.strong_rand_bytes(8)

    if candidate == 0 or Map.has_key?(ledger.active, candidate) or
         Map.has_key?(ledger.terminal, candidate) do
      unique_id(ledger)
    else
      candidate
    end
  end
end
