defmodule MingaEditor.Renderer.TextInteractionIndex.Reader do
  @moduledoc "Opaque read capability for one renderer-owned interaction-index generation."

  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Renderer.WrapLayout

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
         {:ok, {buffer, source_version, rows, _scroll_request, _settled_scroll_seq}} <-
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

  @doc "Resolves the exact active source lease without inventing a row hit."
  @spec source(t(), pos_integer(), pos_integer()) ::
          {:ok, {pid(), non_neg_integer()}} | {:error, :inactive | :unavailable}
  def source(%__MODULE__{table: table}, window_id, presentation_id) do
    with {:ok, ^presentation_id} <- read(table, {:active, window_id}),
         {:ok, {buffer, version, _rows, _scroll_request, _settled_scroll_seq}} <-
           read(table, {:lease, window_id, presentation_id}),
         :ok <- active_still_exact(table, window_id, presentation_id) do
      {:ok, {buffer, version}}
    else
      {:error, :unavailable} -> {:error, :unavailable}
      _ -> {:error, :inactive}
    end
  end

  @doc "Resolves a published retained source for physical observations, without admitting text input."
  @spec retained_source(t(), pos_integer(), pos_integer()) ::
          {:ok, {pid(), non_neg_integer()}} | {:error, :unknown | :unavailable}
  def retained_source(%__MODULE__{table: table}, window_id, presentation_id) do
    case read(table, {:lease, window_id, presentation_id}) do
      {:ok, {buffer, version, _rows, _scroll_request, _settled_scroll_seq}} ->
        {:ok, {buffer, version}}

      :error ->
        {:error, :unknown}

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  @doc "Reads complete wrapped-line counts for the current compatible windowed source."
  @spec windowed_wrap_counts(t() | nil, pos_integer(), pid(), non_neg_integer(), tuple()) ::
          WrapLayout.counts()
  def windowed_wrap_counts(%__MODULE__{table: table}, window_id, buffer, version, basis) do
    case read(table, {:windowed_wrap_counts, window_id}) do
      {:ok, {^buffer, ^version, ^basis, counts}} -> counts
      _ -> %{}
    end
  end

  def windowed_wrap_counts(nil, _window_id, _buffer, _version, _basis), do: %{}

  @doc "Moves the live editor anchor using a compatible immutable wrapped root."
  @spec scroll_anchor(
          t(),
          pos_integer(),
          pid(),
          non_neg_integer(),
          term(),
          {non_neg_integer(), non_neg_integer()},
          integer(),
          pos_integer()
        ) :: {:ok, {non_neg_integer(), non_neg_integer()}, boolean()} | :error
  def scroll_anchor(
        %__MODULE__{table: table},
        window_id,
        buffer,
        version,
        basis,
        {line, offset},
        delta,
        fitted
      ) do
    key = {:scroll_root, window_id}
    header = fn ref -> rank_header(table, ref) end

    # Relative wheel input uses the live anchor, independent of settled scroll authority.
    with {:ok, {^buffer, ^version, ^basis, root, _}} <- read(table, key),
         {:ok, {size, lines, _, _, _, _, _}} when lines > 0 <-
           read(table, {:node_header, root}),
         line = min(line, lines - 1),
         first when is_integer(first) <- ResidentStore.select_start(root, line, header),
         last when is_integer(last) <- next_line_rank(root, line + 1, lines, size, header),
         bottom = max(size - fitted, 0),
         current = min(first + min(offset, last - first - 1), bottom),
         target = current |> Kernel.+(delta) |> max(0) |> min(bottom),
         {_, _} = anchor <- ResidentStore.locate_anchor(root, target, header),
         {:ok, {^buffer, ^version, ^basis, ^root, _}} <- read(table, key) do
      {:ok, anchor, target == bottom}
    else
      _ -> :error
    end
  end

  @doc """
  Resolves an absolute visual rank from the active resident lease only if its
  layout and settled scroll authority still match the acknowledged root.
  """
  @spec seek_scroll_rank(
          t(),
          pos_integer(),
          pos_integer(),
          {pid(), non_neg_integer(), term(), non_neg_integer()},
          non_neg_integer(),
          pos_integer()
        ) :: {:ok, {non_neg_integer(), non_neg_integer()}, boolean()} | :error
  def seek_scroll_rank(
        %__MODULE__{table: table},
        window_id,
        presentation_id,
        {buffer, version, basis, authoritative_seq},
        rank,
        fitted
      ) do
    key = {:scroll_root, window_id}

    with {:ok, ^presentation_id} <- read(table, {:active, window_id}),
         {:ok, {^buffer, ^version, {:resident, root}, ^authoritative_seq, settled_scroll_seq}}
         when is_integer(settled_scroll_seq) <-
           read(table, {:lease, window_id, presentation_id}),
         identity = {buffer, version, basis, root, settled_scroll_seq},
         {:ok, ^identity} <- read(table, key),
         {:ok, {size, _, _, _, _, _, _}} <- read(table, {:node_header, root}),
         bottom = max(size - fitted, 0),
         target = min(rank, bottom),
         {_, _} = anchor <- ResidentStore.locate_anchor(root, target, &rank_header(table, &1)),
         {:ok, ^identity} <- read(table, key),
         :ok <- active_still_exact(table, window_id, presentation_id) do
      {:ok, anchor, target == bottom}
    else
      _ -> :error
    end
  end

  defp next_line_rank(_root, lines, lines, size, _header), do: size

  defp next_line_rank(root, line, _lines, _size, header),
    do: ResidentStore.select_start(root, line, header)

  defp rank_header(table, ref) do
    case read(table, {:node_header, ref}) do
      {:ok, {_, _, left, left_size, left_lines, starts, right}} ->
        {:ok, {left, left_size, left_lines, starts, right}}

      _ ->
        :error
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
    with {:ok, {size, _, _, _, _, _, _}} <- read(table, {:node_header, root}),
         true <- row_index >= 0 and row_index < size,
         {:ok, node, offset, line} <-
           ResidentStore.locate_rank(root, row_index, &rank_header(table, &1)),
         {:ok, entries} <- read(table, {:node_entries, node}),
         %{payload: payload} <- elem(entries, offset) do
      {:ok, ResidentStore.project_payload(payload, line)}
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
