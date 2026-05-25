defmodule MingaEditor.Shell.Entry do
  @moduledoc """
  Registered shell metadata.

  Shell entries are source-owned contributions. The registry keeps this validated shape in `persistent_term` so render and input hot paths can resolve the active shell without sorting or calling extension code.
  """

  @type source :: Minga.Extension.ContributionCleanup.contribution_source()
  @type capability :: :gui | :tui

  @enforce_keys [:id, :source, :module, :display_name, :description, :capabilities]
  defstruct [
    :id,
    :source,
    :module,
    :display_name,
    :description,
    :capabilities,
    default?: false,
    generation: 0
  ]

  @type t :: %__MODULE__{
          id: atom(),
          source: source(),
          module: module(),
          display_name: String.t(),
          description: String.t(),
          capabilities: [capability()],
          default?: boolean(),
          generation: non_neg_integer()
        }

  @doc "Builds a validated built-in shell entry or raises if the shell module is invalid."
  @spec builtin!(atom(), module(), String.t(), String.t(), boolean()) :: t()
  def builtin!(id, module, display_name, description, default?)
      when is_atom(id) and is_atom(module) and is_binary(display_name) and is_binary(description) and
             is_boolean(default?) do
    case new(%{
           id: id,
           source: :builtin,
           module: module,
           display_name: display_name,
           description: description,
           capabilities: [:gui, :tui],
           default?: default?
         }) do
      {:ok, entry} -> entry
      {:error, reason} -> raise ArgumentError, "invalid built-in shell entry: #{inspect(reason)}"
    end
  end

  @doc "Returns an entry with a registry-assigned generation."
  @spec with_generation(t(), non_neg_integer()) :: t()
  def with_generation(%__MODULE__{} = entry, generation)
      when is_integer(generation) and generation >= 0 do
    %{entry | generation: generation}
  end

  @doc "Builds a validated shell entry."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    with {:ok, id} <- fetch_atom(attrs, :id),
         {:ok, source} <- fetch_source(attrs),
         {:ok, module} <- fetch_module(attrs),
         {:ok, display_name} <- fetch_binary(attrs, :display_name),
         {:ok, description} <- fetch_binary(attrs, :description),
         {:ok, capabilities} <- fetch_capabilities(attrs) do
      {:ok,
       %__MODULE__{
         id: id,
         source: source,
         module: module,
         display_name: display_name,
         description: description,
         capabilities: capabilities,
         default?: Map.get(attrs, :default?, false) == true
       }}
    end
  end

  @spec fetch_atom(map(), atom()) :: {:ok, atom()} | {:error, term()}
  defp fetch_atom(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_atom(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_atom, key, value}}
      :error -> {:error, {:missing, key}}
    end
  end

  @spec fetch_source(map()) :: {:ok, source()} | {:error, term()}
  defp fetch_source(attrs) do
    case Map.fetch(attrs, :source) do
      {:ok, :builtin} -> {:ok, :builtin}
      {:ok, :config} -> {:ok, :config}
      {:ok, {:extension, name} = source} when is_atom(name) -> {:ok, source}
      {:ok, source} -> {:error, {:invalid_source, source}}
      :error -> {:error, {:missing, :source}}
    end
  end

  @spec fetch_module(map()) :: {:ok, module()} | {:error, term()}
  defp fetch_module(attrs) do
    case Map.fetch(attrs, :module) do
      {:ok, module} when is_atom(module) -> validate_shell_module(module)
      {:ok, module} -> {:error, {:invalid_module, module}}
      :error -> {:error, {:missing, :module}}
    end
  end

  @spec validate_shell_module(module()) :: {:ok, module()} | {:error, term()}
  defp validate_shell_module(module) do
    with true <- Code.ensure_loaded?(module),
         :ok <- validate_callbacks(module) do
      {:ok, module}
    else
      false -> {:error, {:module_not_loaded, module}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_callbacks(module()) :: :ok | {:error, term()}
  defp validate_callbacks(module) do
    missing =
      required_callbacks()
      |> Enum.reject(fn {name, arity} -> function_exported?(module, name, arity) end)

    case missing do
      [] -> :ok
      callbacks -> {:error, {:missing_callbacks, module, callbacks}}
    end
  end

  @spec required_callbacks() :: [{atom(), non_neg_integer()}]
  defp required_callbacks do
    [
      init: 1,
      compute_layout: 1,
      build_chrome: 4,
      chrome_fingerprint: 1,
      async_render?: 1,
      gui_payload: 1,
      render: 1,
      input_handlers: 1,
      handle_event: 3,
      handle_gui_action: 3,
      on_buffer_added: 5,
      on_buffer_switched: 2,
      on_buffer_died: 3,
      on_agent_event: 4,
      active_tab: 1,
      find_tab_by_buffer: 2,
      active_tab_kind: 1,
      set_tab_session: 3,
      active_session: 1
    ]
  end

  @spec fetch_binary(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp fetch_binary(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_binary, key, value}}
      :error -> {:error, {:missing, key}}
    end
  end

  @spec fetch_capabilities(map()) :: {:ok, [capability()]} | {:error, term()}
  defp fetch_capabilities(attrs) do
    case Map.fetch(attrs, :capabilities) do
      {:ok, capabilities} when is_list(capabilities) -> normalize_capabilities(capabilities)
      {:ok, capabilities} -> {:error, {:invalid_capabilities, capabilities}}
      :error -> {:error, {:missing, :capabilities}}
    end
  end

  @spec normalize_capabilities([term()]) :: {:ok, [capability()]} | {:error, term()}
  defp normalize_capabilities(capabilities) do
    if Enum.all?(capabilities, &valid_capability?/1) do
      {:ok, capabilities |> Enum.uniq() |> Enum.sort()}
    else
      {:error, {:invalid_capabilities, capabilities}}
    end
  end

  @spec valid_capability?(term()) :: boolean()
  defp valid_capability?(:gui), do: true
  defp valid_capability?(:tui), do: true
  defp valid_capability?(_capability), do: false
end
