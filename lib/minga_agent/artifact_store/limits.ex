defmodule MingaAgent.ArtifactStore.Limits do
  @moduledoc "Finite owner-configured limits for retained artifacts."

  @type t :: %__MODULE__{
          root_bytes: pos_integer(),
          session_bytes: pos_integer(),
          capture_bytes: pos_integer(),
          append_bytes: pos_integer(),
          image_bytes: pos_integer(),
          root_namespaces: pos_integer(),
          root_artifacts: pos_integer(),
          session_artifacts: pos_integer(),
          root_open_captures: pos_integer(),
          session_open_captures: pos_integer(),
          session_pin_sets: pos_integer(),
          session_pin_refs: pos_integer(),
          root_items: pos_integer(),
          session_items: pos_integer(),
          capture_items: pos_integer()
        }

  @enforce_keys [
    :root_bytes,
    :session_bytes,
    :capture_bytes,
    :append_bytes,
    :image_bytes,
    :root_namespaces,
    :root_artifacts,
    :session_artifacts,
    :root_open_captures,
    :session_open_captures,
    :session_pin_sets,
    :session_pin_refs,
    :root_items,
    :session_items,
    :capture_items
  ]
  defstruct @enforce_keys

  @limit_key_count length(@enforce_keys)

  @doc "Builds limits from an owner-supplied complete policy plus bounded overrides."
  @spec new(keyword() | map(), keyword() | map()) :: {:ok, t()} | {:error, :invalid_limits}
  def new(overrides, defaults \\ %{}) do
    with {:ok, default_values} when map_size(default_values) == @limit_key_count <-
           admit_limit_map(defaults),
         {:ok, values} <- admit_limit_map(overrides) do
      default_values
      |> Map.merge(values)
      |> build_limits()
    else
      _ -> {:error, :invalid_limits}
    end
  end

  @doc "Applies namespace limits without allowing any root policy limit to increase."
  @spec restrict(t(), keyword() | map()) :: {:ok, t()} | {:error, :invalid_limits}
  def restrict(%__MODULE__{} = ceiling, overrides) do
    with {:ok, values} <- admit_limit_map(overrides),
         :ok <- check_ceiling(values, ceiling) do
      restricted = Map.merge(ceiling, values)
      if coherent?(restricted), do: {:ok, restricted}, else: {:error, :invalid_limits}
    end
  end

  @doc "Caps session aggregate policy at an already durable namespace ceiling."
  @spec cap_session(t(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) :: t()
  def cap_session(%__MODULE__{} = limits, bytes, items, artifacts, open_captures) do
    %__MODULE__{
      limits
      | session_bytes: min(limits.session_bytes, bytes),
        session_items: min(limits.session_items, items),
        session_artifacts: min(limits.session_artifacts, artifacts),
        session_open_captures: min(limits.session_open_captures, open_captures)
    }
  end

  @doc "Returns the fixed logical SQLite envelope charge."
  @spec sqlite_envelope_bytes() :: pos_integer()
  def sqlite_envelope_bytes, do: 8 * 1024 * 1024 + 256 * 1024

  @doc "Returns the fixed versioned blob header size."
  @spec blob_header_bytes() :: pos_integer()
  def blob_header_bytes, do: 16

  @doc "Returns the fixed versioned item-index header size."
  @spec index_header_bytes() :: pos_integer()
  def index_header_bytes, do: 16

  @doc "Returns the fixed charge admitted before creating capture files."
  @spec capture_header_bytes() :: pos_integer()
  def capture_header_bytes, do: blob_header_bytes() + index_header_bytes()

  @doc "Returns the fixed persisted integrity block size."
  @spec integrity_block_bytes() :: pos_integer()
  def integrity_block_bytes, do: 64 * 1024

  @spec build_limits(map()) :: {:ok, t()} | {:error, :invalid_limits}
  defp build_limits(values) do
    if Enum.all?(values, fn {_key, value} -> is_integer(value) and value > 0 end) and
         coherent?(values) do
      {:ok, struct!(__MODULE__, values)}
    else
      {:error, :invalid_limits}
    end
  end

  @spec admit_limit_map(term()) :: {:ok, map()} | {:error, :invalid_limits}
  defp admit_limit_map(values) when is_list(values) do
    if Keyword.keyword?(values),
      do: values |> Map.new() |> admit_limit_map(),
      else: {:error, :invalid_limits}
  end

  defp admit_limit_map(%{__struct__: _}), do: {:error, :invalid_limits}

  defp admit_limit_map(values) when is_map(values) do
    if Enum.all?(values, fn {key, _value} -> key in @enforce_keys end),
      do: {:ok, values},
      else: {:error, :invalid_limits}
  end

  defp admit_limit_map(_values), do: {:error, :invalid_limits}

  @spec check_ceiling(map(), t()) :: :ok | {:error, :invalid_limits}
  defp check_ceiling(values, ceiling) do
    if Enum.all?(values, fn {key, value} ->
         is_integer(value) and value > 0 and value <= Map.fetch!(ceiling, key)
       end),
       do: :ok,
       else: {:error, :invalid_limits}
  end

  @spec coherent?(map()) :: boolean()
  defp coherent?(values) do
    values.session_bytes <= values.root_bytes and
      values.capture_bytes <= values.session_bytes and
      values.image_bytes <= values.capture_bytes and
      values.append_bytes <= values.capture_bytes and
      values.session_artifacts <= values.root_artifacts and
      values.session_open_captures <= values.root_open_captures and
      values.session_items <= values.root_items and
      values.capture_items <= values.session_items
  end
end
