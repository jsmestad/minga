defmodule MingaEditor.Renderer.TextPresentation do
  @moduledoc "Immutable source correspondence retained for frontend text-pointer input."

  alias Minga.RenderModel.Window.Row
  alias MingaEditor.DisplayMap
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.Renderer.WrapLayout
  alias MingaEditor.Window

  @type rows :: {:resident, ResidentStore.t()} | {:windowed, tuple()}
  @type wrap_counts :: {tuple(), WrapLayout.counts()}

  @enforce_keys [:window_id, :presentation_id, :buffer, :source_version, :identity, :rows]
  defstruct [{:settled_scroll_seq, nil} | @enforce_keys]

  @type t :: %__MODULE__{
          window_id: Window.id(),
          presentation_id: pos_integer(),
          buffer: pid(),
          source_version: non_neg_integer(),
          identity: term(),
          rows: rows(),
          settled_scroll_seq: non_neg_integer() | nil
        }

  @spec new(Window.id(), pid(), non_neg_integer(), term(), rows(), pos_integer()) :: t()
  def new(window_id, buffer, source_version, identity, rows, presentation_id)
      when is_integer(window_id) and window_id > 0 and is_pid(buffer) and
             is_integer(source_version) and source_version >= 0 do
    %__MODULE__{
      window_id: window_id,
      presentation_id: presentation_id,
      buffer: buffer,
      source_version: source_version,
      identity: identity,
      rows: rows
    }
  end

  @doc "Reuses the prior presentation only when its immutable interaction identity matches."
  @spec retain(t() | nil, Window.id(), pid(), non_neg_integer(), term(), rows(), pos_integer()) ::
          t()
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
        _rows,
        _presentation_id
      ),
      do: presentation

  def retain(_previous, window_id, buffer, source_version, identity, rows, presentation_id),
    do: new(window_id, buffer, source_version, identity, rows, presentation_id)

  @doc "Records the scroll authority settled for this exact wrapped resident frame."
  @spec settle_scroll(t(), non_neg_integer()) :: t()
  def settle_scroll(%__MODULE__{settled_scroll_seq: seq} = presentation, seq), do: presentation

  def settle_scroll(%__MODULE__{identity: {:wrapped_resident, _, _, _}} = presentation, seq),
    do: %{presentation | settled_scroll_seq: seq}

  def settle_scroll(%__MODULE__{} = presentation, _seq), do: presentation

  @doc "Carries complete mixed measurements in the renderer's previous presentation only."
  @spec mixed_wrap_identity(DisplayMap.t(), map(), term()) :: term()
  def mixed_wrap_identity(%DisplayMap{wrap_basis: basis, sources: sources}, builds, identity)
      when is_tuple(basis) do
    {:wrapped_windowed, basis, DisplayMap.wrap_counts(sources),
     {:mixed_layout, sources, builds, identity}}
  end

  @doc "Returns this pane's mixed measurements only for the same source and wrap basis."
  @spec matching_mixed_wrap(t() | nil, pid(), non_neg_integer(), tuple() | nil) ::
          {DisplayMap.sources(), map()}
  def matching_mixed_wrap(
        %__MODULE__{
          buffer: buffer,
          source_version: version,
          identity: {:wrapped_windowed, basis, _, {:mixed_layout, sources, builds, _}}
        },
        buffer,
        version,
        basis
      )
      when is_tuple(basis),
      do: {sources, builds}

  def matching_mixed_wrap(_presentation, _buffer, _version, _basis), do: {%{}, %{}}

  @doc "Drops renderer-only measurements before retaining a frontend input lease."
  @spec for_lease(t()) :: t()
  def for_lease(
        %__MODULE__{
          identity: {:wrapped_windowed, basis, counts, {:mixed_layout, _, _, identity}}
        } = presentation
      ),
      do: %{presentation | identity: {:wrapped_windowed, basis, counts, identity}}

  def for_lease(%__MODULE__{} = presentation), do: presentation

  @doc "Returns exact counts from complete wrapped groups, never from trimmed presentation rows."
  @spec windowed_wrap_counts(t()) :: wrap_counts() | nil
  def windowed_wrap_counts(%__MODULE__{
        identity: {:wrapped_windowed, basis, counts, _identity},
        rows: {:windowed, _rows}
      }),
      do: {basis, counts}

  def windowed_wrap_counts(%__MODULE__{}), do: nil

  @doc "Reuses a window's counts only for the same source and wrap basis."
  @spec matching_wrap_counts(t() | nil, pid(), non_neg_integer(), tuple()) :: WrapLayout.counts()
  def matching_wrap_counts(
        %__MODULE__{buffer: buffer, source_version: version} = presentation,
        buffer,
        version,
        basis
      ) do
    case windowed_wrap_counts(presentation) do
      {^basis, counts} -> counts
      _ -> %{}
    end
  end

  def matching_wrap_counts(_presentation, _buffer, _version, _basis), do: %{}

  @doc "Resolves one rank-addressed row after verifying its durable row id."
  @spec resolve(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, TextTarget.t()} | {:error, :row_not_found | :row_id_mismatch | :not_source_backed}
  def resolve(%__MODULE__{} = presentation, row_index, row_id, utf16_offset) do
    case row_at(presentation.rows, row_index) do
      {:ok, row} ->
        resolve_row(
          presentation.window_id,
          presentation.buffer,
          presentation.source_version,
          row,
          row_id,
          utf16_offset
        )

      :error ->
        {:error, :row_not_found}
    end
  end

  @doc "Resolves one already-located visual row through the shared source mapping."
  @spec resolve_row(
          Window.id(),
          pid(),
          non_neg_integer(),
          VisualRow.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, TextTarget.t()} | {:error, :row_id_mismatch | :not_source_backed}
  def resolve_row(
        window_id,
        buffer,
        source_version,
        %VisualRow{row: %Row{row_id: stored_row_id}} = row,
        row_id,
        utf16_offset
      ) do
    if stored_row_id != row_id do
      {:error, :row_id_mismatch}
    else
      case VisualRow.source_character_position(row, utf16_offset) do
        {:ok, {line, byte}} ->
          {:ok,
           TextTarget.new(%{
             window_id: window_id,
             buffer: buffer,
             source_version: source_version,
             line: line,
             byte: byte
           })}

        :not_source_backed ->
          {:error, :not_source_backed}
      end
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
