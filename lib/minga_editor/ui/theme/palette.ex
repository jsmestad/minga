defmodule MingaEditor.UI.Theme.Palette do
  @moduledoc """
  Semantic color palette used to derive a complete editor theme.

  Theme authors provide a flat palette map, and this module expands it into smaller nested structs for base colors, semantic accents, and syntax roles.
  """

  alias MingaEditor.UI.Theme
  alias MingaEditor.UI.Theme.Palette.{Base, Semantic, Syntax}

  @enforce_keys [:variant, :base, :semantic, :syntax]
  defstruct [:variant, :base, :semantic, :syntax]

  @type variant :: :dark | :light
  @type color :: Theme.color()

  @type t :: %__MODULE__{
          variant: variant(),
          base: Base.t(),
          semantic: Semantic.t(),
          syntax: Syntax.t()
        }

  @doc "Builds a palette from a flat theme map."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    variant = variant!(attrs)
    base = Base.new(attrs)
    semantic = Semantic.new(attrs, variant, base)
    syntax = Syntax.new(attrs, semantic, base)

    %__MODULE__{variant: variant, base: base, semantic: semantic, syntax: syntax}
  end

  @doc "Normalizes an existing palette or flat palette map."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = palette) do
    validate_palette!(palette)
    palette
  end

  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @spec variant!(map()) :: variant()
  defp variant!(%{variant: :dark}), do: :dark
  defp variant!(%{variant: :light}), do: :light

  defp variant!(%{variant: variant}) do
    raise ArgumentError, "theme palette variant must be :dark or :light, got: #{inspect(variant)}"
  end

  defp variant!(_attrs) do
    raise ArgumentError, "theme palette is missing required key :variant"
  end

  @spec validate_palette!(t()) :: :ok
  defp validate_palette!(%__MODULE__{
         variant: variant,
         base: base,
         semantic: semantic,
         syntax: syntax
       }) do
    validate_variant!(variant)
    validate_struct!(:base, Base, base)
    validate_struct!(:semantic, Semantic, semantic)
    validate_struct!(:syntax, Syntax, syntax)
    :ok
  end

  @spec validate_variant!(term()) :: variant()
  defp validate_variant!(:dark), do: :dark
  defp validate_variant!(:light), do: :light

  defp validate_variant!(variant) do
    raise ArgumentError, "theme palette variant must be :dark or :light, got: #{inspect(variant)}"
  end

  @spec validate_struct!(atom(), module(), term()) :: :ok
  defp validate_struct!(label, module, struct) do
    case struct do
      %{__struct__: ^module} = nested ->
        Enum.each(Map.from_struct(nested), fn {key, value} ->
          validate_color!(label, key, value)
        end)

        :ok

      _ ->
        raise ArgumentError,
              "theme palette #{label} must be a #{inspect(module)} struct, got: #{inspect(struct)}"
    end
  end

  @spec validate_color!(atom(), atom(), term()) :: term()
  defp validate_color!(_label, _key, value) when is_integer(value) and value >= 0, do: value

  defp validate_color!(label, key, value) do
    raise ArgumentError,
          "theme palette #{label}.#{key} must be a color, got: #{inspect(value)}"
  end
end
