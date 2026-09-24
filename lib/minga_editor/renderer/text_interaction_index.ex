defmodule MingaEditor.Renderer.TextInteractionIndex do
  @moduledoc "Renderer-owned immutable index for direct text-pointer resolution."

  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Renderer.TextPresentation

  @type root_ref :: reference()
  @type current_root :: {pid(), root_ref()}
  @type t :: %__MODULE__{
          table: :ets.table(),
          current_roots: %{optional(pos_integer()) => current_root()},
          last_publication_nodes: non_neg_integer()
        }

  @enforce_keys [:table]
  defstruct [:table, current_roots: %{}, last_publication_nodes: 0]

  @spec new() :: t()
  def new do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    %__MODULE__{table: table}
  end

  @spec reader(t()) :: Reader.t()
  def reader(%__MODULE__{table: table}), do: Reader.new(table)

  @doc "Publishes one complete candidate graph and pins its lease and current root."
  @spec publish(t(), TextPresentation.t()) :: t()
  def publish(%__MODULE__{} = index, %TextPresentation{} = presentation) do
    {rows, published_nodes} = publish_rows(index.table, presentation.rows)

    :ets.insert(
      index.table,
      {{:lease, presentation.window_id, presentation.presentation_id},
       {presentation.buffer, presentation.source_version, rows}}
    )

    retain_rows(index.table, rows)

    index
    |> swap_current(presentation.window_id, presentation.buffer, rows)
    |> Map.put(:last_publication_nodes, published_nodes)
  end

  @doc "Makes one already-published candidate active."
  @spec activate(t(), pos_integer(), pos_integer()) :: :ok | {:error, :unknown}
  def activate(%__MODULE__{table: table}, window_id, presentation_id) do
    if :ets.member(table, {:lease, window_id, presentation_id}) do
      :ets.insert(table, {{:active, window_id}, presentation_id})
      :ok
    else
      {:error, :unknown}
    end
  end

  @doc "Removes exact lease metadata before releasing its immutable graph pin."
  @spec discard(t(), TextPresentation.t()) :: t()
  def discard(%__MODULE__{table: table} = index, %TextPresentation{} = presentation) do
    key = {:lease, presentation.window_id, presentation.presentation_id}

    case :ets.take(table, key) do
      [{^key, {_buffer, _source_version, rows}}] ->
        delete_active_if_exact(table, presentation.window_id, presentation.presentation_id)
        release_rows(table, rows)
        index

      [] ->
        index
    end
  end

  @doc "Drops current graph roots for windows absent from the acknowledged output."
  @spec retain_current_windows(t(), MapSet.t(pos_integer())) :: t()
  def retain_current_windows(%__MODULE__{} = index, window_ids) do
    Enum.reduce(index.current_roots, index, fn {window_id, {_buffer, root}}, acc ->
      if MapSet.member?(window_ids, window_id) do
        acc
      else
        release_root(acc.table, root)
        %{acc | current_roots: Map.delete(acc.current_roots, window_id)}
      end
    end)
  end

  @doc "Drops current roots owned by a terminated buffer."
  @spec drop_buffer(t(), pid()) :: t()
  def drop_buffer(%__MODULE__{} = index, buffer) when is_pid(buffer) do
    Enum.reduce(index.current_roots, index, fn
      {window_id, {^buffer, root}}, acc ->
        release_root(acc.table, root)
        %{acc | current_roots: Map.delete(acc.current_roots, window_id)}

      {_window_id, _current}, acc ->
        acc
    end)
  end

  @doc "Clears every lease, active record, graph node, and root pin for a new connection."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{table: table} = index) do
    :ets.delete_all_objects(table)
    %{index | current_roots: %{}, last_publication_nodes: 0}
  end

  @spec last_publication_nodes(t()) :: non_neg_integer()
  def last_publication_nodes(%__MODULE__{last_publication_nodes: count}), do: count

  @spec publish_rows(:ets.table(), TextPresentation.rows()) ::
          {{:resident, root_ref() | nil} | {:windowed, tuple()}, non_neg_integer()}
  defp publish_rows(_table, {:windowed, rows}), do: {{:windowed, rows}, 0}

  defp publish_rows(table, {:resident, %ResidentStore{} = store}) do
    root = ResidentStore.interaction_root(store)
    {root_ref, count} = publish_node(table, root)
    {{:resident, root_ref}, count}
  end

  @spec publish_node(:ets.table(), ResidentStore.tree()) :: {root_ref() | nil, non_neg_integer()}
  defp publish_node(_table, nil), do: {nil, 0}

  defp publish_node(table, tree) do
    {:ok, {ref, size, left, left_size, entries, right}} = ResidentStore.interaction_node(tree)

    if :ets.member(table, {:node_header, ref}) do
      {ref, 0}
    else
      {left_ref, left_count} = publish_node(table, left)
      {right_ref, right_count} = publish_node(table, right)

      :ets.insert(table, [
        {{:node_header, ref}, {size, left_ref, left_size, tuple_size(entries), right_ref}},
        {{:node_entries, ref}, entries},
        {{:node_refs, ref}, 0}
      ])

      retain_root(table, left_ref)
      retain_root(table, right_ref)
      {ref, left_count + right_count + 1}
    end
  end

  @spec swap_current(
          t(),
          pos_integer(),
          pid(),
          {:resident, root_ref() | nil} | {:windowed, tuple()}
        ) ::
          t()
  defp swap_current(index, window_id, buffer, {:resident, root}) when is_reference(root) do
    case Map.get(index.current_roots, window_id) do
      {^buffer, ^root} ->
        index

      previous ->
        retain_root(index.table, root)
        release_current(index.table, previous)
        %{index | current_roots: Map.put(index.current_roots, window_id, {buffer, root})}
    end
  end

  defp swap_current(index, window_id, _buffer, _rows) do
    case Map.pop(index.current_roots, window_id) do
      {nil, _roots} ->
        index

      {{_buffer, root}, roots} ->
        release_root(index.table, root)
        %{index | current_roots: roots}
    end
  end

  @spec retain_rows(:ets.table(), {:resident, root_ref() | nil} | {:windowed, tuple()}) :: :ok
  defp retain_rows(table, {:resident, root}), do: retain_root(table, root)
  defp retain_rows(_table, {:windowed, _rows}), do: :ok

  @spec release_rows(:ets.table(), {:resident, root_ref() | nil} | {:windowed, tuple()}) :: :ok
  defp release_rows(table, {:resident, root}), do: release_root(table, root)
  defp release_rows(_table, {:windowed, _rows}), do: :ok

  @spec retain_root(:ets.table(), root_ref() | nil) :: :ok
  defp retain_root(_table, nil), do: :ok

  defp retain_root(table, root) do
    _new_count = :ets.update_counter(table, {:node_refs, root}, {2, 1})
    :ok
  end

  @spec release_root(:ets.table(), root_ref() | nil) :: :ok
  defp release_root(_table, nil), do: :ok

  defp release_root(table, root) do
    case :ets.update_counter(table, {:node_refs, root}, {2, -1}) do
      0 -> release_zero_ref_node(table, root)
      _remaining -> :ok
    end
  end

  @spec release_zero_ref_node(:ets.table(), root_ref()) :: :ok
  defp release_zero_ref_node(table, root) do
    header_key = {:node_header, root}

    case :ets.take(table, header_key) do
      [{^header_key, {_size, left, _left_size, _own_size, right}}] ->
        :ets.delete(table, {:node_entries, root})
        :ets.delete(table, {:node_refs, root})
        release_root(table, left)
        release_root(table, right)

      [] ->
        :ok
    end
  end

  @spec release_current(:ets.table(), current_root() | nil) :: :ok
  defp release_current(_table, nil), do: :ok
  defp release_current(table, {_buffer, root}), do: release_root(table, root)

  @spec delete_active_if_exact(:ets.table(), pos_integer(), pos_integer()) :: :ok
  defp delete_active_if_exact(table, window_id, presentation_id) do
    key = {:active, window_id}

    case :ets.lookup(table, key) do
      [{^key, ^presentation_id}] -> :ets.delete(table, key)
      _other -> true
    end

    :ok
  end
end
