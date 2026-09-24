defmodule MingaEditor.Renderer.TextInteractionIndex.Reader do
  @moduledoc "Opaque read capability for one renderer-owned interaction-index generation."

  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.Renderer.TextPresentation

  @opaque t :: %__MODULE__{table: :ets.table()}
  @enforce_keys [:table]
  defstruct @enforce_keys

  @doc "Creates a read capability for the protected table owned by the renderer."
  @spec new(:ets.table()) :: t()
  def new(table), do: %__MODULE__{table: table}

  @doc "Resolves input directly from immutable renderer-owned data."
  @spec resolve(t(), TextEvent.t()) ::
          {:ok, TextTarget.t()}
          | {:error,
             :inactive
             | :row_not_found
             | :row_id_mismatch
             | :not_source_backed
             | :unavailable}
  def resolve(%__MODULE__{table: table}, %TextEvent{} = event) do
    with {:ok, active_id} <- read(table, {:active, event.window_id}),
         true <- active_id == event.presentation_id,
         {:ok, {buffer, source_version, rows}} <-
           read(table, {:lease, event.window_id, event.presentation_id}),
         {:ok, row} <- row_at(table, rows, event.row_index),
         {:ok, target} <-
           TextPresentation.resolve_row(
             event.window_id,
             buffer,
             source_version,
             row,
             event.row_id,
             event.utf16_offset
           ),
         :ok <- active_still_exact(table, event.window_id, event.presentation_id) do
      {:ok, target}
    else
      false -> {:error, :inactive}
      :error -> {:error, :inactive}
      {:error, :inactive} -> {:error, :inactive}
      {:error, :row_not_found} -> {:error, :row_not_found}
      {:error, :row_id_mismatch} -> {:error, :row_id_mismatch}
      {:error, :not_source_backed} -> {:error, :not_source_backed}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  @spec row_at(
          :ets.table(),
          {:resident, reference() | nil} | {:windowed, tuple()},
          non_neg_integer()
        ) ::
          {:ok, term()} | {:error, :row_not_found | :unavailable}
  defp row_at(_table, {:resident, nil}, _row_index), do: {:error, :row_not_found}

  defp row_at(table, {:resident, root}, row_index) do
    header = fn ref ->
      case read(table, {:node_header, ref}) do
        {:ok, {_size, left, left_size, own_size, right}} ->
          {:ok, {left, left_size, own_size, right}}

        _missing_or_unavailable ->
          :error
      end
    end

    with {:ok, {size, _left, _left_size, _own_size, _right}} <-
           read(table, {:node_header, root}),
         true <- row_index < size,
         {:ok, node, offset} <- ResidentStore.locate_rank(root, row_index, header),
         {:ok, entries} <- read(table, {:node_entries, node}),
         %{payload: payload} <- elem(entries, offset) do
      {:ok, ResidentStore.project_payload(payload, row_index)}
    else
      false -> {:error, :row_not_found}
      :error -> {:error, :unavailable}
      {:error, :unavailable} -> {:error, :unavailable}
      _other -> {:error, :unavailable}
    end
  end

  defp row_at(_table, {:windowed, rows}, row_index)
       when row_index >= 0 and row_index < tuple_size(rows),
       do: {:ok, elem(rows, row_index)}

  defp row_at(_table, {:windowed, _rows}, _row_index), do: {:error, :row_not_found}

  @spec read(:ets.table(), term()) :: {:ok, term()} | :error | {:error, :unavailable}
  defp read(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @spec active_still_exact(:ets.table(), pos_integer(), pos_integer()) ::
          :ok | {:error, :inactive | :unavailable}
  defp active_still_exact(table, window_id, presentation_id) do
    case read(table, {:active, window_id}) do
      {:ok, ^presentation_id} -> :ok
      {:error, :unavailable} -> {:error, :unavailable}
      _other -> {:error, :inactive}
    end
  end
end
