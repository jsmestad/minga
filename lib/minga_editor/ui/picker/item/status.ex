defmodule MingaEditor.UI.Picker.Item.Status do
  @moduledoc """
  A picker row's status chip: short text and the tone a frontend draws it in.

  The text and tone travel as one value so they cannot disagree. The BEAM decides both. Frontends render the text verbatim and map the tone to their own colors and glyphs; they never parse the text. Keep the text short (at most 24 display columns), because frontends do not truncate a chip while the row label still fits.

  Tones:

  - `:ready`: the row can be used now.
  - `:warn`: the row can be used, but it needs attention soon, such as plan usage near its limit.
  - `:error`: the row cannot be used now, such as a reached limit or a missing login.
  - `:checking`: the BEAM is still finding out.
  - `:neutral`: a fact with no judgement, such as a route that was not checked.
  """

  @enforce_keys [:tone, :text]
  defstruct @enforce_keys

  @type tone :: :ready | :warn | :error | :checking | :neutral

  @type t :: %__MODULE__{tone: tone(), text: String.t()}

  @tones [:ready, :warn, :error, :checking, :neutral]

  @doc "Builds a status chip from a tone and non-empty text."
  @spec new(tone(), String.t()) :: t()
  def new(tone, text) when tone in @tones and is_binary(text) and text != "",
    do: %__MODULE__{tone: tone, text: text}
end
