defmodule MingaAgent.Tool.Spec do
  @moduledoc """
  Specification for an agent tool.

  Wraps the metadata needed to register, discover, and execute a tool in
  the `MingaAgent.Tool.Registry`. Unlike `ReqLLM.Tool` (which is
  provider-facing and tied to the LLM request lifecycle), `Spec` is the
  internal, registry-facing representation that adds category, approval
  level, and extensibility metadata.

  ## Fields

  | Field              | Type               | Description                                    |
  |--------------------|--------------------|------------------------------------------------|
  | `name`             | `String.t()`       | Unique tool identifier (e.g., `"read_file"`)   |
  | `description`      | `String.t()`       | Human-readable description for the LLM         |
  | `parameter_schema` | `map()`            | JSON Schema for the tool's parameters          |
  | `callback`         | `(map() -> term())` | Function that executes the tool                |
  | `category`         | `atom()`           | Grouping: `:filesystem`, `:git`, `:lsp`, etc.  |
  | `approval_level`   | `atom()`           | `:auto`, `:ask`, or `:deny`                    |
  | `metadata`         | `map()`            | Extensible bag for future fields               |
  """

  @typedoc "Approval level for tool execution."
  @type approval_level :: :auto | :ask | :deny

  @typedoc "Tool category for grouping and filtering."
  @type category :: :filesystem | :git | :lsp | :shell | :memory | :agent | :custom

  @typedoc "A tool specification."
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameter_schema: map(),
          callback: (map() -> term()),
          category: category(),
          approval_level: approval_level(),
          metadata: map()
        }

  @enforce_keys [:name, :description, :parameter_schema, :callback]
  defstruct name: nil,
            description: nil,
            parameter_schema: %{},
            callback: nil,
            category: :custom,
            approval_level: :auto,
            metadata: %{}

  @doc """
  Creates a new tool spec from a keyword list.

  Required keys: `:name`, `:description`, `:parameter_schema`, `:callback`.
  Optional keys: `:category` (default `:custom`), `:approval_level`
  (default `:auto`), `:metadata` (default `%{}`).
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs) do
    name = Keyword.get(attrs, :name)
    description = Keyword.get(attrs, :description)
    parameter_schema = Keyword.get(attrs, :parameter_schema, %{})
    callback = Keyword.get(attrs, :callback)
    category = Keyword.get(attrs, :category, :custom)
    approval_level = Keyword.get(attrs, :approval_level, :auto)
    metadata = Keyword.get(attrs, :metadata, %{})

    validate_and_build(
      name,
      description,
      parameter_schema,
      callback,
      category,
      approval_level,
      metadata
    )
  end

  @doc """
  Creates a new tool spec, raising on validation failure.
  """
  @spec new!(keyword()) :: t()
  def new!(attrs) when is_list(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec validate_and_build(
          term(),
          term(),
          term(),
          term(),
          term(),
          term(),
          term()
        ) :: {:ok, t()} | {:error, String.t()}
  defp validate_and_build(nil, _desc, _schema, _cb, _cat, _al, _meta),
    do: {:error, ":name is required"}

  defp validate_and_build(_name, nil, _schema, _cb, _cat, _al, _meta),
    do: {:error, ":description is required"}

  defp validate_and_build(_name, _desc, _schema, nil, _cat, _al, _meta),
    do: {:error, ":callback is required"}

  defp validate_and_build(name, _desc, _schema, _cb, _cat, _al, _meta)
       when not is_binary(name),
       do: {:error, ":name must be a string"}

  defp validate_and_build(_name, desc, _schema, _cb, _cat, _al, _meta)
       when not is_binary(desc),
       do: {:error, ":description must be a string"}

  defp validate_and_build(_name, _desc, _schema, cb, _cat, _al, _meta)
       when not is_function(cb, 1),
       do: {:error, ":callback must be a 1-arity function"}

  defp validate_and_build(_name, _desc, _schema, _cb, _cat, al, _meta)
       when al not in [:auto, :ask, :deny],
       do: {:error, ":approval_level must be :auto, :ask, or :deny"}

  defp validate_and_build(name, desc, schema, cb, cat, al, meta) do
    {:ok,
     %__MODULE__{
       name: name,
       description: desc,
       parameter_schema: schema,
       callback: cb,
       category: cat,
       approval_level: al,
       metadata: meta
     }}
  end
end
