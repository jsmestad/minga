defmodule MingaAgent.ArtifactStore.PinKey do
  @moduledoc "A durable, bounded key for delivery, snapshot, and task retention pins."

  @type component :: String.t() | non_neg_integer()
  @type kind :: :delivery | :snapshot | :task
  @type t :: %__MODULE__{kind: kind(), id: String.t() | nil, generation: String.t()}

  @enforce_keys [:kind, :generation]
  defstruct [:kind, :id, :generation]

  @doc "Builds the delivery pin key for one admitted checkpoint and call."
  @spec delivery(String.t(), String.t()) :: {:ok, t()} | {:error, :invalid_pin_key}
  def delivery(checkpoint, call_id) when is_binary(checkpoint) and is_binary(call_id),
    do: build(:delivery, checkpoint, call_id)

  def delivery(_checkpoint, _call_id), do: {:error, :invalid_pin_key}

  @doc "Builds the pin key for one durable snapshot generation."
  @spec snapshot(component()) :: {:ok, t()} | {:error, :invalid_pin_key}
  def snapshot(generation), do: build(:snapshot, nil, generation)

  @doc "Builds the pin key for one task generation."
  @spec task(component(), component()) :: {:ok, t()} | {:error, :invalid_pin_key}
  def task(task_id, generation), do: build(:task, task_id, generation)

  @doc "Normalizes the public tuple forms accepted by ArtifactStore."
  @spec new(t() | {:delivery, component(), component()} | {:snapshot, component()} | {:task, component(), component()}) ::
          {:ok, t()} | {:error, :invalid_pin_key}
  def new(%__MODULE__{} = key), do: validate(key)
  def new({:delivery, checkpoint, call_id}), do: delivery(checkpoint, call_id)
  def new({:snapshot, generation}), do: snapshot(generation)
  def new({:task, task_id, generation}), do: task(task_id, generation)
  def new(_key), do: {:error, :invalid_pin_key}

  @doc "Returns the canonical SQLite key."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{kind: kind, id: id, generation: generation}) do
    encoded_id = if id == nil, do: "-", else: encode_component(id)
    Atom.to_string(kind) <> ":" <> encoded_id <> ":" <> encode_component(generation)
  end

  @doc "Returns the pin's storage class."
  @spec kind(t()) :: kind()
  def kind(%__MODULE__{kind: kind}), do: kind

  @spec build(kind(), component() | nil, component()) :: {:ok, t()} | {:error, :invalid_pin_key}
  defp build(kind, id, generation) do
    with {:ok, normalized_id} <- normalize_optional_component(id),
         {:ok, normalized_generation} <- normalize_component(generation) do
      validate(%__MODULE__{kind: kind, id: normalized_id, generation: normalized_generation})
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, :invalid_pin_key}
  defp validate(%__MODULE__{kind: :snapshot, id: nil, generation: generation} = key)
       when is_binary(generation),
       do: valid_components(key, [generation])

  defp validate(%__MODULE__{kind: kind, id: id, generation: generation} = key)
       when kind in [:delivery, :task] and is_binary(id) and is_binary(generation),
       do: valid_components(key, [id, generation])

  defp validate(_key), do: {:error, :invalid_pin_key}

  @spec valid_components(t(), [String.t()]) :: {:ok, t()} | {:error, :invalid_pin_key}
  defp valid_components(key, components) do
    if Enum.all?(components, &(byte_size(&1) in 1..64)),
      do: {:ok, key},
      else: {:error, :invalid_pin_key}
  end

  @spec normalize_optional_component(component() | nil) ::
          {:ok, String.t() | nil} | {:error, :invalid_pin_key}
  defp normalize_optional_component(nil), do: {:ok, nil}
  defp normalize_optional_component(value), do: normalize_component(value)

  @spec normalize_component(component()) :: {:ok, String.t()} | {:error, :invalid_pin_key}
  defp normalize_component(value) when is_binary(value), do: {:ok, value}
  defp normalize_component(value) when is_integer(value) and value >= 0, do: {:ok, Integer.to_string(value)}
  defp normalize_component(_value), do: {:error, :invalid_pin_key}

  @spec encode_component(String.t()) :: String.t()
  defp encode_component(component), do: Base.url_encode64(component, padding: false)
end
