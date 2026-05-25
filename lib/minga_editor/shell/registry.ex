defmodule MingaEditor.Shell.Registry do
  @moduledoc """
  Source-owned registry for workspace shells.

  The active editor shell is read on input and render hot paths, so the registry stores a validated, sorted snapshot in `persistent_term`. Registration and cleanup may do validation work; reads are simple map/list lookups and never call extension code.
  """

  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.Shell.Entry

  @type shell_id :: atom()
  @type source :: ContributionCleanup.contribution_source()
  @type register_attrs :: keyword() | map()
  @type register_error ::
          {:duplicate_id, shell_id()}
          | {:duplicate_module, module(), shell_id()}
          | {:duplicate_default, shell_id()}
          | {:missing_default, term()}
          | {:invalid_entry, term()}
          | :source_required
          | :not_owner

  @state_key {__MODULE__, :state}
  @cleanup_key {__MODULE__, :cleanup_registered?}

  @doc "Registers the built-in shell contributions. Safe to call more than once."
  @spec seed_builtin() :: :ok
  def seed_builtin do
    :ok = ensure_cleanup_registered()

    :ok =
      register_builtin(
        :traditional,
        MingaEditor.Shell.Traditional,
        "Traditional",
        "Tab-based editor with file tree, modeline, picker, and agent panel.",
        true
      )

    :ok
  end

  @doc "Registers a shell contribution."
  @spec register(source(), register_attrs()) :: :ok | {:error, register_error()}
  def register(source, attrs) do
    :ok = ensure_cleanup_registered()
    attrs = attrs |> Map.new() |> Map.put(:source, source)

    case Entry.new(attrs) do
      {:ok, entry} -> put_entry(entry, replace?: false)
      {:error, reason} -> {:error, {:invalid_entry, reason}}
    end
  end

  @doc "Unregisters a shell by id. Built-in shells are intentionally preserved. Extension shells must use unregister/2."
  @spec unregister(shell_id()) :: :ok | {:error, :builtin_shell | :source_required}
  def unregister(id) when is_atom(id) do
    case get(id) do
      %Entry{source: :builtin} -> {:error, :builtin_shell}
      %Entry{} -> {:error, :source_required}
      nil -> :ok
    end
  end

  @doc "Unregisters a shell owned by the given source."
  @spec unregister(source(), shell_id()) :: :ok | {:error, :builtin_shell | :not_owner}
  def unregister(:builtin, _id), do: {:error, :builtin_shell}

  def unregister(source, id) when is_atom(id) do
    case get(id) do
      %Entry{source: ^source} -> put_state(remove_entry(state(), id))
      %Entry{} -> {:error, :not_owner}
      nil -> :ok
    end
  end

  @doc "Unregisters all shells owned by a source. Built-in shells are intentionally preserved."
  @spec unregister_source(source()) :: :ok
  def unregister_source(:builtin), do: :ok

  def unregister_source(source) do
    current = state()

    current.entries
    |> Enum.filter(fn {_id, %Entry{source: entry_source}} -> entry_source == source end)
    |> Enum.map(fn {id, _entry} -> id end)
    |> Enum.reduce(current, &remove_entry(&2, &1))
    |> put_state()
  end

  @doc "Returns registered shells in deterministic display order."
  @spec list() :: [Entry.t()]
  def list, do: state().ordered

  @doc "Returns a shell entry by id."
  @spec get(shell_id()) :: Entry.t() | nil
  def get(id) when is_atom(id), do: Map.get(state().entries, id)

  @doc "Returns the default shell entry, falling back to Traditional when the registry is empty."
  @spec default() :: Entry.t()
  def default do
    current = state()
    Map.get(current.entries, current.default_id) || builtin_traditional_entry()
  end

  @doc "Returns the registered module for an id, or nil."
  @spec module_for(shell_id()) :: module() | nil
  def module_for(id) when is_atom(id) do
    case get(id) do
      %Entry{module: module} -> module
      nil -> nil
    end
  end

  @doc "Returns the shell id registered for a module, or nil."
  @spec id_for_module(module()) :: shell_id() | nil
  def id_for_module(module) when is_atom(module) do
    list()
    |> Enum.find(fn %Entry{module: entry_module} -> entry_module == module end)
    |> case do
      %Entry{id: id} -> id
      nil -> nil
    end
  end

  @doc "Returns true when the id is currently registered."
  @spec available?(shell_id()) :: boolean()
  def available?(id) when is_atom(id), do: get(id) != nil

  @doc "Returns true when the shell supports a capability atom."
  @spec supports?(shell_id(), atom()) :: boolean()
  def supports?(id, capability) when is_atom(id) and is_atom(capability) do
    case get(id) do
      %Entry{capabilities: capabilities} -> capability in capabilities
      nil -> false
    end
  end

  @doc "Resets registry state. Intended for tests that need isolated registry setup."
  @spec reset_for_test([Entry.t()]) :: :ok
  def reset_for_test(entries \\ []) when is_list(entries) do
    entries
    |> Enum.reduce(empty_state(), fn %Entry{} = entry, acc -> add_entry(acc, entry) end)
    |> put_state()
  end

  @spec register_builtin(shell_id(), module(), String.t(), String.t(), boolean()) :: :ok
  defp register_builtin(id, module, display_name, description, default?) do
    entry = Entry.builtin!(id, module, display_name, description, default?)

    :ok = put_entry(entry, replace?: true)
  end

  @spec put_entry(Entry.t(), keyword()) :: :ok | {:error, register_error()}
  defp put_entry(%Entry{} = entry, opts) do
    current = state()
    replace? = Keyword.fetch!(opts, :replace?)

    with :ok <- check_duplicate_id(current, entry, replace?),
         :ok <- check_duplicate_module(current, entry, replace?),
         :ok <- check_duplicate_default(current, entry, replace?) do
      {current, entry} = assign_generation(current, entry, replace?)

      current
      |> remove_entry(entry.id)
      |> add_entry(entry)
      |> put_state()
    end
  end

  @spec check_duplicate_id(map(), Entry.t(), boolean()) :: :ok | {:error, register_error()}
  defp check_duplicate_id(_current, _entry, true), do: :ok

  defp check_duplicate_id(current, %Entry{id: id}, false) do
    if Map.has_key?(current.entries, id), do: {:error, {:duplicate_id, id}}, else: :ok
  end

  @spec check_duplicate_module(map(), Entry.t(), boolean()) :: :ok | {:error, register_error()}
  defp check_duplicate_module(current, %Entry{id: id, module: module}, replace?) do
    current.entries
    |> Enum.find(fn {entry_id, %Entry{module: entry_module}} ->
      entry_module == module and (not replace? or entry_id != id)
    end)
    |> case do
      {existing_id, _entry} -> {:error, {:duplicate_module, module, existing_id}}
      nil -> :ok
    end
  end

  @spec check_duplicate_default(map(), Entry.t(), boolean()) :: :ok | {:error, register_error()}
  defp check_duplicate_default(_current, %Entry{default?: false}, _replace?), do: :ok

  defp check_duplicate_default(current, %Entry{id: id}, replace?) do
    existing_default = current.default_id

    if existing_default != nil and (not replace? or existing_default != id) do
      {:error, {:duplicate_default, existing_default}}
    else
      :ok
    end
  end

  @spec assign_generation(map(), Entry.t(), boolean()) :: {map(), Entry.t()}
  defp assign_generation(current, %Entry{id: id} = entry, true) do
    case Map.get(current.entries, id) do
      %Entry{source: source, module: module, generation: generation}
      when source == entry.source and module == entry.module ->
        {current, Entry.with_generation(entry, generation)}

      _other ->
        assign_next_generation(current, entry)
    end
  end

  defp assign_generation(current, %Entry{} = entry, _replace?),
    do: assign_next_generation(current, entry)

  @spec assign_next_generation(map(), Entry.t()) :: {map(), Entry.t()}
  defp assign_next_generation(current, %Entry{} = entry) do
    generation = Map.get(current, :next_generation, 1)
    {%{current | next_generation: generation + 1}, Entry.with_generation(entry, generation)}
  end

  @spec add_entry(map(), Entry.t()) :: map()
  defp add_entry(current, %Entry{} = entry) do
    entries = Map.put(current.entries, entry.id, entry)
    default_id = if entry.default?, do: entry.id, else: current.default_id
    %{current | entries: entries, ordered: sort_entries(entries), default_id: default_id}
  end

  @spec remove_entry(map(), shell_id()) :: map()
  defp remove_entry(current, id) do
    entries = Map.delete(current.entries, id)
    default_id = next_default_id(entries, current.default_id, id)
    %{current | entries: entries, ordered: sort_entries(entries), default_id: default_id}
  end

  @spec next_default_id(%{shell_id() => Entry.t()}, shell_id() | nil, shell_id()) ::
          shell_id() | nil
  defp next_default_id(_entries, current_default, removed_id)
       when current_default != removed_id do
    current_default
  end

  defp next_default_id(entries, _current_default, _removed_id) do
    entries
    |> Enum.find(fn {_id, %Entry{default?: default?}} -> default? end)
    |> default_entry_id()
  end

  @spec default_entry_id({shell_id(), Entry.t()} | nil) :: shell_id() | nil
  defp default_entry_id({id, _entry}), do: id
  defp default_entry_id(nil), do: nil

  @spec sort_entries(%{shell_id() => Entry.t()}) :: [Entry.t()]
  defp sort_entries(entries) do
    entries
    |> Map.values()
    |> Enum.sort_by(fn %Entry{default?: default?, display_name: display_name, id: id} ->
      {if(default?, do: 0, else: 1), String.downcase(display_name), Atom.to_string(id)}
    end)
  end

  @spec state() :: map()
  defp state, do: :persistent_term.get(@state_key, empty_state())

  @spec put_state(map()) :: :ok
  defp put_state(current) do
    :persistent_term.put(@state_key, current)
    :ok
  end

  @spec empty_state() :: map()
  defp empty_state, do: %{entries: %{}, ordered: [], default_id: nil, next_generation: 1}

  @spec builtin_traditional_entry() :: Entry.t()
  defp builtin_traditional_entry do
    Entry.builtin!(
      :traditional,
      MingaEditor.Shell.Traditional,
      "Traditional",
      "Tab-based editor with file tree, modeline, picker, and agent panel.",
      true
    )
  end

  @spec ensure_cleanup_registered() :: :ok
  defp ensure_cleanup_registered do
    unless :persistent_term.get(@cleanup_key, false) do
      ContributionCleanup.register(:shells, &__MODULE__.unregister_source/1)
      :persistent_term.put(@cleanup_key, true)
    end

    :ok
  end
end
