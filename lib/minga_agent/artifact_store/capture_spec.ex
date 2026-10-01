defmodule MingaAgent.ArtifactStore.CaptureSpec do
  @moduledoc "Validated owner intent for a streamed retained artifact capture."

  alias MingaAgent.ArtifactStore.PinKey

  @type mode :: :bytes | :items
  @type t :: %__MODULE__{
          media_type: String.t(),
          mode: mode(),
          expected_bytes: non_neg_integer() | nil,
          owner_pid: pid(),
          delivery_key: PinKey.t()
        }

  @enforce_keys [:media_type, :mode, :owner_pid, :delivery_key]
  defstruct [:media_type, :mode, :expected_bytes, :owner_pid, :delivery_key]

  @doc "Builds a capture specification; delivery keys identify an admitted checkpoint and call."
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_capture_spec | :invalid_pin_key}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: build(attrs), else: {:error, :invalid_capture_spec}
  end

  def new(_attrs), do: {:error, :invalid_capture_spec}

  @spec build(keyword()) :: {:ok, t()} | {:error, :invalid_capture_spec | :invalid_pin_key}
  defp build(attrs) do
    media_type = Keyword.get(attrs, :media_type)
    mode = Keyword.get(attrs, :mode)
    expected_bytes = Keyword.get(attrs, :expected_bytes)
    owner_pid = Keyword.get(attrs, :owner_pid)

    with true <-
           Keyword.keys(attrs) --
             [:media_type, :mode, :expected_bytes, :owner_pid, :delivery_key] == [],
         true <-
           is_binary(media_type) and byte_size(media_type) > 0 and byte_size(media_type) <= 255,
         true <- mode in [:bytes, :items],
         true <- valid_expected_bytes?(expected_bytes),
         true <- is_pid(owner_pid),
         {:ok, %PinKey{kind: :delivery} = delivery_key} <-
           normalize_delivery_key(Keyword.get(attrs, :delivery_key)) do
      {:ok,
       %__MODULE__{
         media_type: media_type,
         mode: mode,
         expected_bytes: expected_bytes,
         owner_pid: owner_pid,
         delivery_key: delivery_key
       }}
    else
      {:error, :invalid_pin_key} = error -> error
      _ -> {:error, :invalid_capture_spec}
    end
  end

  @spec normalize_delivery_key(term()) :: {:ok, PinKey.t()} | {:error, :invalid_pin_key}
  defp normalize_delivery_key(%PinKey{} = key), do: PinKey.new(key)
  defp normalize_delivery_key({:delivery, _checkpoint, _call_id} = key), do: PinKey.new(key)
  defp normalize_delivery_key(_key), do: {:error, :invalid_pin_key}

  @spec valid_expected_bytes?(term()) :: boolean()
  defp valid_expected_bytes?(nil), do: true
  defp valid_expected_bytes?(value), do: is_integer(value) and value >= 0
end
