defmodule Minga.Buffer.Span do
  @moduledoc """
  Represents a resolved half-open span in document text.

  Most editor code should talk in positions and selections. A span is the internal resolved shape used once a selection is ready to read or edit text.
  """

  alias Minga.Buffer.Position

  @enforce_keys [:start, :stop]
  defstruct [:start, :stop]

  @type point :: Position.point()
  @type t :: %__MODULE__{start: point(), stop: point()}

  @doc "Builds a span from two document points."
  @spec between(point(), point()) :: t()
  def between(start_point, stop_point) when start_point <= stop_point do
    %__MODULE__{start: start_point, stop: stop_point}
  end

  def between(start_point, stop_point) do
    %__MODULE__{start: stop_point, stop: start_point}
  end

  @doc "Builds a characterwise span that includes the character at the final point."
  @spec characterwise(String.t(), point(), point()) :: t()
  def characterwise(text, start_point, stop_point) when start_point <= stop_point do
    %__MODULE__{start: start_point, stop: Position.after_character_at(text, stop_point)}
  end

  def characterwise(text, start_point, stop_point) do
    %__MODULE__{start: stop_point, stop: Position.after_character_at(text, start_point)}
  end

  @doc "Returns the text covered by a span."
  @spec slice(String.t(), t()) :: String.t()
  def slice(text, %__MODULE__{start: start_point, stop: stop_point}) do
    binary_part(text, start_point, stop_point - start_point)
  end

  @doc "Removes the text covered by a span."
  @spec delete(String.t(), t()) :: String.t()
  def delete(text, %__MODULE__{start: start_point, stop: stop_point}) do
    text_size = byte_size(text)
    before_text = binary_part(text, 0, start_point)
    after_text = binary_part(text, stop_point, text_size - stop_point)
    before_text <> after_text
  end
end
