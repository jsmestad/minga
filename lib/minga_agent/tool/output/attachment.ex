defmodule MingaAgent.Tool.Output.Attachment do
  @moduledoc "Provider-neutral image metadata whose bytes live in a durable capture."

  alias MingaAgent.Tool.Output.Reference

  @type t :: %__MODULE__{
          kind: :image,
          reference: Reference.t(),
          media_type: String.t(),
          filename: String.t()
        }

  @enforce_keys [:reference, :media_type, :filename]
  defstruct [:reference, :media_type, :filename, kind: :image]

  @doc "Builds an image attachment without copying the image bytes into conversation records."
  @spec image(Reference.t(), String.t()) ::
          {:ok, t()} | {:error, :unsupported_image_format | :invalid_attachment}
  def image(%Reference{media_type: media_type} = reference, filename)
      when media_type in ["image/png", "image/jpeg", "image/gif", "image/webp"] and
             is_binary(filename) and byte_size(filename) > 0 do
    {:ok, %__MODULE__{reference: reference, media_type: media_type, filename: filename}}
  end

  def image(%Reference{}, filename) when is_binary(filename) and byte_size(filename) > 0,
    do: {:error, :unsupported_image_format}

  def image(_, _), do: {:error, :invalid_attachment}
end
