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

  @doc "Builds limits from an owner-supplied complete policy plus bounded overrides."
  @spec new(keyword() | map(), keyword() | map()) :: {:ok, t()} | {:error, :invalid_limits}
  def new(overrides, defaults \\ %{}) do
    with {:ok, default_values} <- override_map(defaults),
         true <- Enum.sort(Map.keys(default_values)) == Enum.sort(@enforce_keys),
         {:ok, values} <- override_map(overrides),
         true <- Map.keys(values) -- @enforce_keys == [],
         merged = Map.merge(default_values, values),
         true <- Enum.all?(merged, fn {_key, value} -> is_integer(value) and value > 0 end),
         true <- coherent?(merged) do
      {:ok, struct!(__MODULE__, merged)}
    else
      _ -> {:error, :invalid_limits}
    end
  end

  @doc "Applies namespace limits without allowing any root policy limit to increase."
  @spec restrict(t(), keyword() | map()) :: {:ok, t()} | {:error, :invalid_limits}
  def restrict(%__MODULE__{} = ceiling, overrides) do
    with {:ok, values} <- override_map(overrides),
         true <- Map.keys(values) -- @enforce_keys == [],
         true <-
           Enum.all?(values, fn {key, value} ->
             is_integer(value) and value > 0 and value <= Map.fetch!(ceiling, key)
           end),
         restricted = Map.merge(Map.from_struct(ceiling), values),
         true <- coherent?(restricted) do
      {:ok, struct!(__MODULE__, restricted)}
    else
      _ -> {:error, :invalid_limits}
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

  @spec override_map(keyword() | map()) :: {:ok, map()} | {:error, :invalid_limits}
  defp override_map(values) when is_list(values) do
    if Keyword.keyword?(values), do: {:ok, Map.new(values)}, else: {:error, :invalid_limits}
  end

  defp override_map(values) when is_map(values), do: {:ok, values}
  defp override_map(_values), do: {:error, :invalid_limits}

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
