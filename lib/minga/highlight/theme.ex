defmodule Minga.Highlight.Theme do
  @moduledoc """
  Legacy syntax highlighting theme module.

  Delegates to `Minga.Theme` for theme data and capture resolution.
  Kept for backward compatibility with code that references
  `Highlight.Theme.doom_one/0` or `Highlight.Theme.style_for_capture/2`.
  """

  @typedoc "A theme: capture name → style mapping."
  @type t :: %{String.t() => Minga.Port.Protocol.style()}

  @doc "Returns the Doom One syntax color map."
  @spec doom_one() :: t()
  def doom_one do
    Minga.Theme.get!(:doom_one).syntax
  end

  @doc """
  Returns the style for a capture name, using suffix fallback.

  Delegates to `Minga.Theme.style_for_capture/2` using a wrapper theme struct.

  ## Examples

      iex> theme = Minga.Highlight.Theme.doom_one()
      iex> Minga.Highlight.Theme.style_for_capture(theme, "keyword")
      [fg: 0xC678DD, bold: true]

      iex> theme = Minga.Highlight.Theme.doom_one()
      iex> Minga.Highlight.Theme.style_for_capture(theme, "nonexistent")
      []
  """
  @spec style_for_capture(t(), String.t()) :: Minga.Port.Protocol.style()
  def style_for_capture(theme, name) when is_map(theme) and is_binary(name) do
    case Map.get(theme, name) do
      nil -> fallback_lookup(theme, name)
      style -> style
    end
  end

  @spec fallback_lookup(t(), String.t()) :: Minga.Port.Protocol.style()
  defp fallback_lookup(theme, name) when is_binary(name) do
    case String.split(name, ".") do
      [_single] ->
        []

      parts ->
        parent = parts |> Enum.slice(0..-2//1) |> Enum.join(".")
        style_for_capture(theme, parent)
    end
  end
end
