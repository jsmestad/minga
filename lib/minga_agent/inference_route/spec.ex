defmodule MingaAgent.InferenceRoute.Spec do
  @moduledoc """
  Source-owned declaration of one contributed model route.

  The route id is the prefix of every model reference the route offers (`"<route_id>:<model_id>"`). Ids use lowercase letters, digits, `_`, and `-`, and cannot reuse a built-in request provider name, so a model reference always has exactly one owner.

  `setup_action` is optional. When present, `/model` shows a setup row for the route while it is registered.

  `short_name` is optional. It is the name Minga uses inside sentences, such as "Claude" in "Claude plan limit reached.", while `display_name` labels picker rows and models. Without it, sentences use `display_name`.
  """

  alias MingaAgent.InferenceRoute.SetupAction

  @enforce_keys [:source, :id, :module, :display_name]
  defstruct [:source, :id, :module, :display_name, short_name: nil, setup_action: nil]

  @typedoc "Source that owns the route declaration."
  @type source :: {:extension, atom()} | {:bundle, atom()}

  @type t :: %__MODULE__{
          source: source(),
          id: String.t(),
          module: module(),
          display_name: String.t(),
          short_name: String.t() | nil,
          setup_action: SetupAction.t() | nil
        }

  @type error ::
          :invalid_source
          | :invalid_id
          | :reserved_id
          | :invalid_module
          | :invalid_display_name
          | :invalid_short_name
          | :invalid_setup_action

  @id_pattern ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @reserved_ids ~w(anthropic openai openai_codex google openrouter groq mistral deepseek apple native contributed)

  @doc "Builds a validated route declaration."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, error()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with {:ok, source} <- validate_source(Map.get(attrs, :source)),
         {:ok, id} <- validate_id(Map.get(attrs, :id)),
         {:ok, module} <- validate_module(Map.get(attrs, :module)),
         {:ok, display_name} <- validate_display_name(Map.get(attrs, :display_name)),
         {:ok, short_name} <- validate_short_name(Map.get(attrs, :short_name)),
         {:ok, setup_action} <- validate_setup_action(Map.get(attrs, :setup_action)) do
      {:ok,
       %__MODULE__{
         source: source,
         id: id,
         module: module,
         display_name: display_name,
         short_name: short_name,
         setup_action: setup_action
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_source}

  @doc "Returns the name to use inside sentences: `short_name`, or `display_name` when it is not set."
  @spec short_name(t()) :: String.t()
  def short_name(%__MODULE__{short_name: nil, display_name: display_name}), do: display_name
  def short_name(%__MODULE__{short_name: short_name}), do: short_name

  @doc "Returns route ids reserved for built-in request providers and backends."
  @spec reserved_ids() :: [String.t()]
  def reserved_ids, do: @reserved_ids

  @spec validate_source(term()) :: {:ok, source()} | {:error, :invalid_source}
  defp validate_source({kind, name} = source)
       when kind in [:extension, :bundle] and is_atom(name) and not is_nil(name),
       do: {:ok, source}

  defp validate_source(_source), do: {:error, :invalid_source}

  @spec validate_id(term()) :: {:ok, String.t()} | {:error, :invalid_id | :reserved_id}
  defp validate_id(id) when is_binary(id) do
    cond do
      id in @reserved_ids -> {:error, :reserved_id}
      Regex.match?(@id_pattern, id) -> {:ok, id}
      true -> {:error, :invalid_id}
    end
  end

  defp validate_id(_id), do: {:error, :invalid_id}

  @spec validate_module(term()) :: {:ok, module()} | {:error, :invalid_module}
  defp validate_module(module) when is_atom(module) and module not in [nil, true, false],
    do: {:ok, module}

  defp validate_module(_module), do: {:error, :invalid_module}

  @spec validate_display_name(term()) :: {:ok, String.t()} | {:error, :invalid_display_name}
  defp validate_display_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :invalid_display_name}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_display_name(_name), do: {:error, :invalid_display_name}

  @spec validate_short_name(term()) :: {:ok, String.t() | nil} | {:error, :invalid_short_name}
  defp validate_short_name(nil), do: {:ok, nil}

  defp validate_short_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :invalid_short_name}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_short_name(_name), do: {:error, :invalid_short_name}

  @spec validate_setup_action(term()) ::
          {:ok, SetupAction.t() | nil} | {:error, :invalid_setup_action}
  defp validate_setup_action(nil), do: {:ok, nil}
  defp validate_setup_action(attrs), do: SetupAction.new(attrs)
end
