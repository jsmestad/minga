defmodule MingaEditor.UI.Theme.Palette.Base do
  @moduledoc """
  Base palette colors for theme authoring.

  These are the minimal structural colors every theme must provide.
  """

  alias MingaEditor.UI.Theme

  @enforce_keys [:bg, :fg, :surface, :overlay, :muted, :subtle]
  defstruct [:bg, :fg, :surface, :overlay, :muted, :subtle]

  @type color :: Theme.color()

  @type t :: %__MODULE__{
          bg: color(),
          fg: color(),
          surface: color(),
          overlay: color(),
          muted: color(),
          subtle: color()
        }

  @doc "Builds the base palette from a flat theme map."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      bg: required_color(attrs, :bg),
      fg: required_color(attrs, :fg),
      surface: required_color(attrs, :surface),
      overlay: required_color(attrs, :overlay),
      muted: required_color(attrs, :muted),
      subtle: required_color(attrs, :subtle)
    }
  end

  @spec required_color(map(), atom()) :: color()
  defp required_color(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "theme palette #{inspect(key)} must be a color, got: #{inspect(value)}"

      :error ->
        raise ArgumentError, "theme palette is missing required key #{inspect(key)}"
    end
  end
end
