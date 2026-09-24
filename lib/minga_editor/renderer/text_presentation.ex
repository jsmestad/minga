defmodule MingaEditor.Renderer.TextPresentation do
  @moduledoc "Immutable source correspondence retained for frontend text-pointer input."

  alias Minga.RenderModel.Window.Row
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.Window

  @type rows :: {:resident, ResidentStore.t()} | {:windowed, tuple()}

  @enforce_keys [:window_id, :presentation_id, :buffer, :source_version, :identity, :rows]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          window_id: Window.id(),
          presentation_id: pos_integer(),
          buffer: pid(),
          source_version: non_neg_integer(),
          identity: term(),
          rows: rows()
        }

  @spec new(Window.id(), pid(), non_neg_integer(), term(), rows()) :: t()
  def new(window_id, buffer, source_version, identity, rows)
      when is_integer(window_id) and window_id > 0 and is_pid(buffer) and
             is_integer(source_version) and source_version >= 0 do
    %__MODULE__{
      window_id: window_id,
      presentation_id: System.unique_integer([:positive, :monotonic]),
      buffer: buffer,
      source_version: source_version,
      identity: identity,
      rows: rows
    }
  end

  @doc "Reuses the prior presentation only when its immutable interaction identity matches."
  @spec retain(t() | nil, Window.id(), pid(), non_neg_integer(), term(), rows()) :: t()
  def retain(
        %__MODULE__{
          window_id: window_id,
          buffer: buffer,
          source_version: version,
          identity: identity
        } =
          presentation,
        window_id,
        buffer,
        version,
        identity,
        _rows
      ),
      do: presentation

  def retain(_previous, window_id, buffer, source_version, identity, rows),
    do: new(window_id, buffer, source_version, identity, rows)

  @doc "Resolves one rank-addressed row after verifying its durable row id."
  @spec resolve(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, TextTarget.t()} | {:error, :row_not_found | :row_id_mismatch | :not_source_backed}
  def resolve(%__MODULE__{} = presentation, row_index, row_id, utf16_offset) do
    with {:ok, %VisualRow{row: %Row{row_id: stored_row_id}} = row} <-
           row_at(presentation.rows, row_index),
         true <- stored_row_id == row_id,
         {:ok, {line, byte}} <- VisualRow.source_character_position(row, utf16_offset) do
      {:ok,
       TextTarget.new(%{
         window_id: presentation.window_id,
         buffer: presentation.buffer,
         source_version: presentation.source_version,
         line: line,
         byte: byte
       })}
    else
      :error -> {:error, :row_not_found}
      false -> {:error, :row_id_mismatch}
      :not_source_backed -> {:error, :not_source_backed}
    end
  end

  @spec row_at(rows(), non_neg_integer()) :: {:ok, VisualRow.t()} | :error
  defp row_at({:resident, %ResidentStore{} = store}, row_index),
    do: ResidentStore.payload_at(store, row_index)

  defp row_at({:windowed, rows}, row_index)
       when is_tuple(rows) and row_index >= 0 and row_index < tuple_size(rows),
       do: {:ok, elem(rows, row_index)}

  defp row_at({:windowed, _rows}, _row_index), do: :error
end
