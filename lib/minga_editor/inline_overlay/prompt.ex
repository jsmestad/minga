defmodule MingaEditor.InlineOverlay.Prompt do
  @moduledoc """
  Shared prompt-input and scroll mechanics for inline overlays.

  Inline ask and inline edit edit a `:prompt` string while `:phase` is `:input`, and scroll their body with a `:scroll` offset clamped at zero. Those transitions only touch fields common to both variant structs, so they live here once instead of being copied per variant.

  Each function takes and returns the variant's own struct, so the variant modules keep their `@enforce_keys`, kind-specific fields, and terminal transitions while delegating these shared edits.
  """

  @typedoc "An overlay struct carrying `:prompt`, `:phase`, and `:scroll`."
  @type overlay :: %{
          :__struct__ => module(),
          :prompt => String.t(),
          :phase => term(),
          :scroll => non_neg_integer(),
          optional(atom()) => term()
        }

  @doc "Appends text to the prompt while the overlay is accepting input."
  @spec append_input(overlay(), String.t()) :: overlay()
  def append_input(%{phase: :input, prompt: prompt} = overlay, text) when is_binary(text),
    do: %{overlay | prompt: prompt <> text}

  def append_input(overlay, _text) when is_map(overlay), do: overlay

  @doc "Deletes one prompt grapheme while the overlay is accepting input."
  @spec backspace(overlay()) :: overlay()
  def backspace(%{phase: :input, prompt: prompt} = overlay),
    do: %{overlay | prompt: prompt |> String.graphemes() |> Enum.drop(-1) |> Enum.join()}

  def backspace(overlay) when is_map(overlay), do: overlay

  @doc "Scrolls the overlay body, clamped at zero."
  @spec scroll(overlay(), integer()) :: overlay()
  def scroll(%{scroll: current} = overlay, delta) when is_integer(delta),
    do: %{overlay | scroll: max(current + delta, 0)}
end
