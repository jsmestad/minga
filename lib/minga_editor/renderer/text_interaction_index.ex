defmodule MingaEditor.Renderer.TextInteractionIndex do
  @moduledoc "Renderer-owned immutable index for direct text-pointer resolution."

  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Renderer.TextPresentation

  @type root_ref :: reference()
  @type current_root :: {pid(), root_ref() | nil}
  @type gutter_leases :: %{
          optional(pos_integer()) => {pos_integer(), Minga.Buffer.RendererConsume.review_lease()}
        }
  @type t :: %__MODULE__{
          table: :ets.table(),
          current_roots: %{optional(pos_integer()) => current_root()},
          gutter_leases: gutter_leases(),
          last_publication_nodes: non_neg_integer()
        }

  @enforce_keys [:table]
  defstruct [:table, current_roots: %{}, gutter_leases: %{}, last_publication_nodes: 0]

  @spec new() :: t()
  def new do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    %__MODULE__{table: table}
  end

  @spec reader(t()) :: Reader.t()
  def reader(%__MODULE__{table: table}), do: Reader.new(table)

  @doc "Publishes only the compact gutter leases from one acknowledged frame."
  @spec publish_gutters(t(), gutter_leases()) :: t()
  def publish_gutters(%__MODULE__{gutter_leases: leases} = index, leases), do: index

  def publish_gutters(%__MODULE__{} = index, leases) do
    :ets.insert(index.table, {:gutter_leases, leases})
    %{index | gutter_leases: leases}
  end

  @doc "Publishes one complete candidate graph and pins its lease and current root."
  @spec publish(t(), TextPresentation.t()) :: t()
  def publish(%__MODULE__{} = index, %TextPresentation{} = presentation) do
    {rows, published_nodes} = publish_rows(index.table, presentation.rows)

    :ets.insert(
      index.table,
      {{:lease, presentation.window_id, presentation.presentation_id}, lease(presentation, rows)}
    )

    publish_prompt_owner(index.table, presentation)

    retain_rows(index.table, rows)

    index
    |> update_current_geometry(presentation, rows)
    |> Map.put(:last_publication_nodes, published_nodes)
  end

  @doc "Replaces current wrap geometry without retaining a frontend-visible input lease."
  @spec publish_current(t(), TextPresentation.t()) :: t()
  def publish_current(
        %__MODULE__{} = index,
        %TextPresentation{identity: {:wrapped_resident, _, _, _}} = presentation
      ) do
    {rows, _published_nodes} = publish_rows(index.table, presentation.rows)
    update_current_geometry(index, presentation, rows)
  end

  def publish_current(%__MODULE__{} = index, %TextPresentation{} = presentation),
    do: update_current_geometry(index, presentation, :none)

  defp update_current_geometry(index, presentation, rows) do
    root = publish_scroll_geometry(index.table, presentation, rows)
    swap_current(index, presentation.window_id, presentation.buffer, root)
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
      [{^key, {_buffer, _source_version, rows, _scroll_request, _settled_scroll_seq}}] ->
        delete_active_if_exact(table, presentation.window_id, presentation.presentation_id)
        discard_prompt_owner(table, presentation)
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
        clear_scroll_geometry(acc.table, window_id)
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
        clear_scroll_geometry(acc.table, window_id)
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
    %{index | current_roots: %{}, gutter_leases: %{}, last_publication_nodes: 0}
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
    {:ok, {ref, size, lines, left, left_size, left_lines, starts, entries, right}} =
      ResidentStore.interaction_node(tree)

    if :ets.member(table, {:node_header, ref}) do
      {ref, 0}
    else
      {left_ref, left_count} = publish_node(table, left)
      {right_ref, right_count} = publish_node(table, right)

      :ets.insert(table, [
        {{:node_header, ref}, {size, lines, left_ref, left_size, left_lines, starts, right_ref}},
        {{:node_entries, ref}, entries},
        {{:node_refs, ref}, 0}
      ])

      retain_root(table, left_ref)
      retain_root(table, right_ref)
      {ref, left_count + right_count + 1}
    end
  end

  defp lease(
         %TextPresentation{identity: {:wrapped_resident, _, request, _}} = presentation,
         rows
       ) do
    {presentation.buffer, presentation.source_version, rows, request,
     presentation.settled_scroll_seq}
  end

  defp lease(%TextPresentation{} = presentation, rows),
    do: {presentation.buffer, presentation.source_version, rows, nil, nil}

  @spec publish_prompt_owner(:ets.tid(), TextPresentation.t()) :: :ok
  defp publish_prompt_owner(
         table,
         %TextPresentation{identity: {:prompt, {_, _, _} = owner, _, _, _}} = presentation
       ) do
    :ets.insert(
      table,
      {{:prompt_owner, presentation.window_id, presentation.presentation_id}, owner}
    )

    :ok
  end

  defp publish_prompt_owner(_table, _presentation), do: :ok

  @spec discard_prompt_owner(:ets.tid(), TextPresentation.t()) :: :ok
  defp discard_prompt_owner(
         table,
         %TextPresentation{identity: {:prompt, {_, _, _}, _, _, _}} = presentation
       ) do
    :ets.delete(table, {:prompt_owner, presentation.window_id, presentation.presentation_id})
    :ok
  end

  defp discard_prompt_owner(_table, _presentation), do: :ok

  defp publish_scroll_geometry(
         table,
         %TextPresentation{identity: {:wrapped_resident, basis, _, _}} = presentation,
         {:resident, root}
       )
       when is_reference(root) do
    :ets.delete(table, {:windowed_wrap_counts, presentation.window_id})

    :ets.insert(
      table,
      {{:scroll_root, presentation.window_id},
       {presentation.buffer, presentation.source_version, basis, root,
        presentation.settled_scroll_seq}}
    )

    {:current, root}
  end

  defp publish_scroll_geometry(table, presentation, rows) do
    :ets.delete(table, {:scroll_root, presentation.window_id})
    key = {:windowed_wrap_counts, presentation.window_id}

    case TextPresentation.windowed_wrap_counts(presentation) do
      {basis, counts} ->
        :ets.insert(
          table,
          {key, {presentation.buffer, presentation.source_version, basis, counts}}
        )

        {:current, nil}

      nil ->
        :ets.delete(table, key)
        current_row_root(rows)
    end
  end

  defp current_row_root({:resident, root}) when is_reference(root), do: {:current, root}
  defp current_row_root(_rows), do: :none

  defp clear_scroll_geometry(table, window_id) do
    :ets.delete(table, {:scroll_root, window_id})
    :ets.delete(table, {:windowed_wrap_counts, window_id})
  end

  @spec swap_current(
          t(),
          pos_integer(),
          pid(),
          {:current, root_ref() | nil} | :none
        ) ::
          t()
  defp swap_current(index, window_id, buffer, {:current, root}) do
    case Map.get(index.current_roots, window_id) do
      {^buffer, ^root} ->
        index

      previous ->
        retain_root(index.table, root)
        release_current(index.table, previous)
        %{index | current_roots: Map.put(index.current_roots, window_id, {buffer, root})}
    end
  end

  defp swap_current(index, window_id, _buffer, :none) do
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
      [{^header_key, {_, _, left, _, _, _, right}}] ->
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
