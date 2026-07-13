defmodule MingaEditor.Shell.Registry.Snapshot do
  @moduledoc "Pure coherent publication value for the serialized shell registry."

  alias MingaEditor.Shell.Entry

  @type shell_id :: atom()
  @type register_error ::
          {:duplicate_id, shell_id()}
          | {:duplicate_module, module(), shell_id()}
          | {:duplicate_default, shell_id()}

  @enforce_keys [:entries, :ordered, :default_id, :next_generation, :generation]
  defstruct [:entries, :ordered, :default_id, :next_generation, :generation]

  @type t :: %__MODULE__{
          entries: %{optional(shell_id()) => Entry.t()},
          ordered: [Entry.t()],
          default_id: shell_id() | nil,
          next_generation: pos_integer(),
          generation: non_neg_integer()
        }

  @doc "Builds an empty unpublished snapshot."
  @spec new() :: t()
  def new do
    %__MODULE__{
      entries: %{},
      ordered: [],
      default_id: nil,
      next_generation: 1,
      generation: 0
    }
  end

  @doc "Builds an unpublished snapshot from validated entries."
  @spec from_entries([Entry.t()]) :: t()
  def from_entries(entries) when is_list(entries) do
    entries
    |> Enum.reduce(new(), &add_entry(&2, &1))
    |> set_next_generation()
  end

  @doc "Registers a new contribution after coherent duplicate checks."
  @spec register(t(), Entry.t()) :: {:ok, t()} | {:error, register_error()}
  def register(%__MODULE__{} = snapshot, %Entry{} = entry) do
    put_entry(snapshot, entry, false)
  end

  @doc "Adds or refreshes a built-in contribution while preserving stable identity."
  @spec put_builtin(t(), Entry.t()) :: {:ok, t()} | {:error, register_error()}
  def put_builtin(%__MODULE__{} = snapshot, %Entry{source: :builtin} = entry) do
    put_entry(snapshot, entry, true)
  end

  @doc "Removes one contribution only when the source owns it."
  @spec unregister(t(), Entry.source(), shell_id()) ::
          {:ok, t(), boolean()} | {:error, :not_owner}
  def unregister(%__MODULE__{} = snapshot, source, id) when is_atom(id) do
    case Map.get(snapshot.entries, id) do
      %Entry{source: ^source} -> {:ok, remove_entry(snapshot, id), true}
      %Entry{} -> {:error, :not_owner}
      nil -> {:ok, snapshot, false}
    end
  end

  @doc "Removes every contribution owned by one source in one value transition."
  @spec unregister_source(t(), Entry.source()) :: {t(), boolean()}
  def unregister_source(%__MODULE__{} = snapshot, source) do
    ids =
      snapshot.entries
      |> Enum.filter(fn {_id, %Entry{source: entry_source}} -> entry_source == source end)
      |> Enum.map(fn {id, _entry} -> id end)

    case ids do
      [] -> {snapshot, false}
      _ids -> {Enum.reduce(ids, snapshot, &remove_entry(&2, &1)), true}
    end
  end

  @doc "Advances the coherent publication generation."
  @spec advance(t()) :: t()
  def advance(%__MODULE__{} = snapshot) do
    %{snapshot | generation: snapshot.generation + 1}
  end

  @doc "Resolves a shell id or implementation module from this publication."
  @spec resolve(t(), shell_id() | module()) :: Entry.t() | nil
  def resolve(%__MODULE__{} = snapshot, id_or_module) when is_atom(id_or_module) do
    Map.get(snapshot.entries, id_or_module) || entry_for_module(snapshot, id_or_module)
  end

  @doc "Returns the entry registered for an implementation module."
  @spec entry_for_module(t(), module()) :: Entry.t() | nil
  def entry_for_module(%__MODULE__{} = snapshot, module) when is_atom(module) do
    Enum.find(snapshot.ordered, fn %Entry{module: entry_module} -> entry_module == module end)
  end

  @spec put_entry(t(), Entry.t(), boolean()) :: {:ok, t()} | {:error, register_error()}
  defp put_entry(snapshot, entry, replace?) do
    with :ok <- check_duplicate_id(snapshot, entry, replace?),
         :ok <- check_duplicate_module(snapshot, entry, replace?),
         :ok <- check_duplicate_default(snapshot, entry, replace?) do
      {snapshot, entry} = assign_generation(snapshot, entry, replace?)
      {:ok, snapshot |> remove_entry(entry.id) |> add_entry(entry)}
    end
  end

  @spec check_duplicate_id(t(), Entry.t(), boolean()) :: :ok | {:error, register_error()}
  defp check_duplicate_id(_snapshot, _entry, true), do: :ok

  defp check_duplicate_id(snapshot, %Entry{id: id}, false) do
    if Map.has_key?(snapshot.entries, id), do: {:error, {:duplicate_id, id}}, else: :ok
  end

  @spec check_duplicate_module(t(), Entry.t(), boolean()) :: :ok | {:error, register_error()}
  defp check_duplicate_module(snapshot, %Entry{id: id, module: module}, replace?) do
    snapshot.entries
    |> Enum.find(fn {entry_id, %Entry{module: entry_module}} ->
      entry_module == module and (not replace? or entry_id != id)
    end)
    |> case do
      {existing_id, _entry} -> {:error, {:duplicate_module, module, existing_id}}
      nil -> :ok
    end
  end

  @spec check_duplicate_default(t(), Entry.t(), boolean()) :: :ok | {:error, register_error()}
  defp check_duplicate_default(_snapshot, %Entry{default?: false}, _replace?), do: :ok

  defp check_duplicate_default(snapshot, %Entry{id: id}, replace?) do
    existing_default = snapshot.default_id

    if existing_default != nil and (not replace? or existing_default != id) do
      {:error, {:duplicate_default, existing_default}}
    else
      :ok
    end
  end

  @spec assign_generation(t(), Entry.t(), boolean()) :: {t(), Entry.t()}
  defp assign_generation(snapshot, %Entry{id: id} = entry, true) do
    case Map.get(snapshot.entries, id) do
      %Entry{source: source, module: module, generation: generation}
      when source == entry.source and module == entry.module ->
        {snapshot, Entry.with_generation(entry, generation)}

      _other ->
        assign_next_generation(snapshot, entry)
    end
  end

  defp assign_generation(snapshot, entry, _replace?), do: assign_next_generation(snapshot, entry)

  @spec assign_next_generation(t(), Entry.t()) :: {t(), Entry.t()}
  defp assign_next_generation(snapshot, entry) do
    generation = snapshot.next_generation

    {%{snapshot | next_generation: generation + 1}, Entry.with_generation(entry, generation)}
  end

  @spec add_entry(t(), Entry.t()) :: t()
  defp add_entry(snapshot, entry) do
    entries = Map.put(snapshot.entries, entry.id, entry)
    default_id = if entry.default?, do: entry.id, else: snapshot.default_id
    %{snapshot | entries: entries, ordered: sort_entries(entries), default_id: default_id}
  end

  @spec remove_entry(t(), shell_id()) :: t()
  defp remove_entry(snapshot, id) do
    entries = Map.delete(snapshot.entries, id)
    default_id = next_default_id(entries, snapshot.default_id, id)
    %{snapshot | entries: entries, ordered: sort_entries(entries), default_id: default_id}
  end

  @spec next_default_id(%{shell_id() => Entry.t()}, shell_id() | nil, shell_id()) ::
          shell_id() | nil
  defp next_default_id(_entries, current_default, removed_id)
       when current_default != removed_id,
       do: current_default

  defp next_default_id(entries, _current_default, _removed_id) do
    entries
    |> Enum.find(fn {_id, %Entry{default?: default?}} -> default? end)
    |> case do
      {id, _entry} -> id
      nil -> nil
    end
  end

  @spec sort_entries(%{shell_id() => Entry.t()}) :: [Entry.t()]
  defp sort_entries(entries) do
    entries
    |> Map.values()
    |> Enum.sort_by(fn %Entry{default?: default?, display_name: display_name, id: id} ->
      {if(default?, do: 0, else: 1), String.downcase(display_name), Atom.to_string(id)}
    end)
  end

  @spec set_next_generation(t()) :: t()
  defp set_next_generation(snapshot) do
    next_generation =
      snapshot.entries
      |> Map.values()
      |> Enum.map(& &1.generation)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    %{snapshot | next_generation: next_generation}
  end
end
