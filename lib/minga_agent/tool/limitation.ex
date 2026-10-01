defmodule MingaAgent.Tool.Limitation do
  @moduledoc "A model-visible, recoverable limitation encountered while executing a tool."

  @type reason :: :model_image_input | :tool_result_transport | :image_format
  @type t :: %__MODULE__{
          kind: :unsupported_modality,
          modality: :image,
          reason: reason(),
          filename: String.t(),
          media_type: String.t()
        }

  @enforce_keys [:reason, :filename, :media_type]
  defstruct [:reason, :filename, :media_type, kind: :unsupported_modality, modality: :image]

  @doc "Builds an image-delivery limitation for an exact model selection decision."
  @spec image_delivery(
          :model_image_input | :tool_result_transport,
          String.t(),
          String.t()
        ) :: t()
  def image_delivery(reason, filename, media_type)
      when reason in [:model_image_input, :tool_result_transport] and is_binary(filename) and
             filename != "" and is_binary(media_type) and media_type != "" do
    %__MODULE__{reason: reason, filename: filename, media_type: media_type}
  end

  @doc "Builds a limitation for image or binary media that cannot be delivered honestly."
  @spec image_format(String.t(), String.t()) :: t()
  def image_format(filename, media_type)
      when is_binary(filename) and filename != "" and is_binary(media_type) and media_type != "" do
    %__MODULE__{reason: :image_format, filename: filename, media_type: media_type}
  end

  @doc "Returns explicit model-visible text for a recoverable tool limitation."
  @spec message(t()) :: String.t()
  def message(%__MODULE__{
        reason: :model_image_input,
        filename: filename,
        media_type: media_type
      }) do
    "Cannot return image #{inspect(filename)} (#{media_type}): the selected model does not support image input. Choose an image-capable model or read a text representation instead."
  end

  def message(%__MODULE__{
        reason: :tool_result_transport,
        filename: filename,
        media_type: media_type
      }) do
    "Cannot return image #{inspect(filename)} (#{media_type}): the selected protocol does not support images in tool results. Choose an exact route that declares image tool-result transport or read a text representation instead."
  end

  def message(%__MODULE__{reason: :image_format, filename: filename, media_type: media_type}) do
    "Cannot return #{inspect(filename)} (#{media_type}): this image or binary format is not supported. Supported image formats are PNG, JPEG, GIF, and WebP."
  end
end
