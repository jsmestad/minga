defmodule MingaEditor.FeatureState do
  @moduledoc """
  Source-owned per-workspace UI feature state.

  Feature state is for presentation features that need tab-scoped state without adding permanent fields to `MingaEditor.Session.State`. Values are opaque to the registry. The owning feature decides the value shape and updates it through the helpers here and on `MingaEditor.Session.State`.
  """

  alias Minga.Extension.ContributionCleanup

  @typedoc "Feature identifier owned by a source."
  @type feature_id :: atom()

  @typedoc "Source that owns feature state."
  @type source :: ContributionCleanup.contribution_source()

  @typedoc "Opaque feature-owned value."
  @type value :: term()

  @typedoc "Feature state registry keyed first by source and then by feature id."
  @type entries :: %{optional(source()) => %{optional(feature_id()) => value()}}

  @cleanup_registered_key {__MODULE__, :cleanup_registered}

  defstruct entries: %{}

  @type t :: %__MODULE__{entries: entries()}

  @doc "Creates an empty feature-state registry."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns true when no feature state is stored."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{entries: entries}), do: map_size(entries) == 0

  @doc "Returns the value for a source-owned feature, or nil when missing."
  @spec get(t(), source(), feature_id()) :: value() | nil
  def get(%__MODULE__{} = state, source, feature_id) do
    state
    |> fetch(source, feature_id)
    |> case do
      {:ok, value} -> value
      :error -> nil
    end
  end

  @doc "Returns the value for a source-owned feature, or a caller-provided default when missing."
  @spec get(t(), source(), feature_id(), default) :: value() | default when default: var
  def get(%__MODULE__{} = state, source, feature_id, default) do
    state
    |> fetch(source, feature_id)
    |> case do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "Fetches a source-owned feature value."
  @spec fetch(t(), source(), feature_id()) :: {:ok, value()} | :error
  def fetch(%__MODULE__{entries: entries}, source, feature_id) do
    with true <- valid_source?(source),
         true <- valid_feature_id?(feature_id),
         %{^feature_id => value} <- Map.get(entries, source, %{}) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  @doc "Stores a source-owned feature value."
  @spec put(t(), source(), feature_id(), value()) :: t()
  def put(%__MODULE__{entries: entries} = state, source, feature_id, value) do
    if valid_source?(source) and valid_feature_id?(feature_id) do
      ensure_cleanup_registered()
      source_entries = entries |> Map.get(source, %{}) |> Map.put(feature_id, value)
      %{state | entries: Map.put(entries, source, source_entries)}
    else
      state
    end
  end

  @doc "Updates a source-owned feature value. Missing values are initialized with `default`."
  @spec update(t(), source(), feature_id(), value(), (value() -> value())) :: t()
  def update(%__MODULE__{} = state, source, feature_id, default, fun) when is_function(fun, 1) do
    value = state |> get(source, feature_id, default) |> fun.()
    put(state, source, feature_id, value)
  end

  @doc "Drops one source-owned feature value."
  @spec drop(t(), source(), feature_id()) :: t()
  def drop(%__MODULE__{entries: entries} = state, source, feature_id) do
    if valid_source?(source) and valid_feature_id?(feature_id) do
      source_entries = entries |> Map.get(source, %{}) |> Map.delete(feature_id)
      entries = put_or_drop_source(entries, source, source_entries)
      %{state | entries: entries}
    else
      state
    end
  end

  @doc "Drops every feature value owned by `source`."
  @spec drop_source(t(), source()) :: t()
  def drop_source(%__MODULE__{entries: entries} = state, source) do
    if valid_source?(source), do: %{state | entries: Map.delete(entries, source)}, else: state
  end

  @doc "Drops every extension-owned feature value while preserving built-in and config state."
  @spec drop_extension_sources(t()) :: t()
  def drop_extension_sources(%__MODULE__{entries: entries} = state) do
    entries = Map.reject(entries, fn {source, _values} -> extension_source?(source) end)
    %{state | entries: entries}
  end

  @doc "Returns true when the source owns the feature id."
  @spec member?(t(), source(), feature_id()) :: boolean()
  def member?(%__MODULE__{} = state, source, feature_id) do
    match?({:ok, _value}, fetch(state, source, feature_id))
  end

  @doc "Registers the source-cleanup callback used by extension unload/reload."
  @spec ensure_cleanup_registered() :: :ok
  def ensure_cleanup_registered do
    case :persistent_term.get(@cleanup_registered_key, false) do
      true ->
        :ok

      false ->
        ContributionCleanup.register(:feature_state, &__MODULE__.unregister_source/1)
        :persistent_term.put(@cleanup_registered_key, true)
        :ok
    end
  end

  @doc "Cleanup callback bridge used by `Minga.Extension.ContributionCleanup`."
  @spec unregister_source(source()) :: :ok | {:error, term()}
  def unregister_source(source) do
    if valid_source?(source) do
      unregister_valid_source(source)
    else
      :ok
    end
  end

  @spec unregister_valid_source(source()) :: :ok | {:error, term()}
  defp unregister_valid_source(source) do
    case Process.whereis(MingaEditor) do
      nil -> :ok
      pid when pid == self() -> unregister_from_editor_process(source)
      pid -> GenServer.call(pid, {:cleanup_feature_state, source}, :infinity)
    end
  end

  @spec unregister_from_editor_process(source()) :: :ok
  defp unregister_from_editor_process(_source), do: :ok

  @doc "Returns true for supported contribution source identifiers."
  @spec valid_source?(term()) :: boolean()
  def valid_source?(:builtin), do: true
  def valid_source?(:config), do: true
  def valid_source?({:extension, name}) when is_atom(name), do: true
  def valid_source?(_source), do: false

  @doc "Returns true for supported feature ids."
  @spec valid_feature_id?(term()) :: boolean()
  def valid_feature_id?(feature_id), do: is_atom(feature_id) and not is_nil(feature_id)

  @spec extension_source?(term()) :: boolean()
  defp extension_source?({:extension, name}) when is_atom(name), do: true
  defp extension_source?(_source), do: false

  @spec put_or_drop_source(entries(), source(), %{optional(feature_id()) => value()}) :: entries()
  defp put_or_drop_source(entries, source, source_entries) do
    case map_size(source_entries) do
      0 -> Map.delete(entries, source)
      _count -> Map.put(entries, source, source_entries)
    end
  end
end
