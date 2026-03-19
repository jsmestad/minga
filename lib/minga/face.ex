defmodule Minga.Face do
  @moduledoc """
  A named, inheritable bundle of visual attributes.

  A face describes how text should look: foreground/background colors,
  bold/italic/underline, underline style and color, strikethrough, blend
  (opacity), and GUI-only font properties. Faces form an inheritance chain
  where `nil` attributes resolve up to the parent face.

  ## Inheritance

  Every face except `"default"` has a parent. When resolving a face's
  effective style, `nil` fields inherit from the parent. The resolution
  walks up the chain until it finds a non-nil value or reaches `"default"`.

  The inheritance chain follows tree-sitter capture name structure:
  `"keyword.function"` inherits from `"keyword"`, which inherits from
  `"default"`. This replaces the suffix-fallback lookup in
  `Theme.style_for_capture/2` with proper structural inheritance.

  ## GUI-only fields

  `font_family`, `font_weight`, `font_slant`, and `font_features` are
  silently ignored in the TUI backend. The TUI uses bold/italic attrs
  from the base fields; the GUI uses the font fields to select specific
  font variants.

  ## Blend

  The `blend` field (0-100) controls opacity. In the GUI, this maps to
  alpha blending in the Metal shader. In the TUI, values below 50 map
  to the `dim` attribute; values 50-100 are rendered at full brightness.
  `nil` means inherit from parent (default is 100 = fully opaque).
  """

  @enforce_keys [:name]
  defstruct name: nil,
            inherit: nil,
            fg: nil,
            bg: nil,
            bold: nil,
            italic: nil,
            underline: nil,
            underline_style: nil,
            underline_color: nil,
            strikethrough: nil,
            reverse: nil,
            blend: nil,
            # GUI-only fields (silently ignored in TUI):
            font_family: nil,
            font_weight: nil,
            font_slant: nil,
            font_features: nil

  @typedoc "RGB color as a 24-bit integer (e.g., `0xFF6C6B`)."
  @type color :: non_neg_integer()

  @typedoc "Underline rendering style."
  @type underline_style :: :line | :curl | :dashed | :dotted | :double

  @typedoc "Font weight for GUI rendering."
  @type font_weight :: :thin | :light | :regular | :medium | :bold | :black

  @typedoc "Font slant for GUI rendering."
  @type font_slant :: :roman | :italic | :oblique

  @type t :: %__MODULE__{
          name: String.t(),
          inherit: String.t() | nil,
          fg: color() | nil,
          bg: color() | nil,
          bold: boolean() | nil,
          italic: boolean() | nil,
          underline: boolean() | nil,
          underline_style: underline_style() | nil,
          underline_color: color() | nil,
          strikethrough: boolean() | nil,
          reverse: boolean() | nil,
          blend: 0..100 | nil,
          font_family: String.t() | nil,
          font_weight: font_weight() | nil,
          font_slant: font_slant() | nil,
          font_features: %{String.t() => boolean()} | nil
        }

  @doc """
  The default face. All inheritance chains terminate here.

  Doom One colors, no decorations, fully opaque.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      name: "default",
      inherit: nil,
      fg: 0xBBC2CF,
      bg: 0x282C34,
      bold: false,
      italic: false,
      underline: false,
      underline_style: :line,
      underline_color: nil,
      strikethrough: false,
      reverse: false,
      blend: 100,
      font_family: nil,
      font_weight: :regular,
      font_slant: :roman,
      font_features: nil
    }
  end

  @doc """
  Resolves a face's effective attributes by walking the inheritance chain.

  Takes a face and a lookup function `(String.t() -> t() | nil)` that
  retrieves parent faces by name. Returns a fully resolved face with no
  `nil` attribute values (every field has a concrete value from the
  nearest ancestor that defines it, bottoming out at `default/0`).

  ## Examples

      iex> comment = %Face{name: "comment", inherit: "default", fg: 0x5B6268, italic: true}
      iex> resolved = Face.resolve(comment, fn "default" -> Face.default(); _ -> nil end)
      iex> resolved.fg
      0x5B6268
      iex> resolved.italic
      true
      iex> resolved.bold
      false
  """
  @spec resolve(t(), (String.t() -> t() | nil)) :: t()
  def resolve(%__MODULE__{} = face, lookup) when is_function(lookup, 1) do
    do_resolve(face, lookup, %{})
  end

  # Fields where nil means "inherit from parent" (must be resolved).
  @required_fields [
    :fg,
    :bg,
    :bold,
    :italic,
    :underline,
    :underline_style,
    :strikethrough,
    :reverse,
    :blend,
    :font_weight,
    :font_slant
  ]

  # All inheritable fields: required fields + fields where nil is a
  # valid terminal value (no underline color, no font override, etc.).
  @inheritable_fields @required_fields ++
                        [:underline_color, :font_family, :font_features]

  defp do_resolve(%__MODULE__{} = face, lookup, seen) do
    if fully_resolved?(face) do
      face
    else
      parent = resolve_parent(face, lookup, seen)
      merge_with_parent(face, parent)
    end
  end

  # A face is fully resolved when all required fields are non-nil.
  # Fields like underline_color, font_family, font_features use nil
  # as a legitimate terminal value ("no override"), so they are not
  # checked here.
  defp fully_resolved?(%__MODULE__{} = face) do
    Enum.all?(@required_fields, fn field ->
      Map.get(face, field) != nil
    end)
  end

  defp resolve_parent(%__MODULE__{inherit: nil}, _lookup, _seen) do
    default()
  end

  defp resolve_parent(%__MODULE__{inherit: parent_name} = face, lookup, seen) do
    if Map.has_key?(seen, parent_name) do
      raise ArgumentError,
            "circular face inheritance detected: #{face.name} -> #{parent_name}"
    end

    parent = lookup.(parent_name) || default()
    do_resolve(parent, lookup, Map.put(seen, face.name, true))
  end

  defp merge_with_parent(%__MODULE__{} = face, %__MODULE__{} = parent) do
    Enum.reduce(@inheritable_fields, face, fn field, acc ->
      case Map.get(acc, field) do
        nil -> Map.put(acc, field, Map.get(parent, field))
        _value -> acc
      end
    end)
  end

  @doc """
  Creates an anonymous face from keyword attributes.

  Convenience constructor for inline styles in renderer modules.
  Equivalent to `from_style("_", attrs)` but more concise.

  ## Examples

      iex> Face.new(fg: 0xFF6C6B, bold: true)
      %Face{name: "_", fg: 0xFF6C6B, bold: true}

      iex> Face.new()
      %Face{name: "_"}
  """
  @spec new(keyword()) :: t()
  def new(attrs \\ []) when is_list(attrs) do
    from_style("_", attrs)
  end

  @doc """
  Converts a face to a style keyword list compatible with `Protocol.style()`.

  This is the bridge between the face system and the existing render
  pipeline. Only includes fields that differ from the `base` face
  (defaults to `default/0`), matching the existing convention where
  styles are sparse (absent fields use the editor's default
  colors/attributes).

  The keyword list may include: `fg`, `bg`, `bold`, `italic`, `underline`,
  `strikethrough`, `underline_style`, `underline_color`, `blend`.
  """
  @spec to_style(t(), t()) :: keyword()
  def to_style(%__MODULE__{} = face, %__MODULE__{} = base \\ default()) do
    []
    |> add_colors(face, base)
    |> add_attrs(face)
    |> add_extended_attrs(face)
  end

  @spec add_colors(keyword(), t(), t()) :: keyword()
  defp add_colors(style, face, base) do
    style = if face.fg && face.fg != base.fg, do: [{:fg, face.fg} | style], else: style
    if face.bg && face.bg != base.bg, do: [{:bg, face.bg} | style], else: style
  end

  @spec add_attrs(keyword(), t()) :: keyword()
  defp add_attrs(style, face) do
    style = if face.bold, do: [{:bold, true} | style], else: style
    style = if face.italic, do: [{:italic, true} | style], else: style
    style = if face.underline, do: [{:underline, true} | style], else: style
    style = if face.strikethrough, do: [{:strikethrough, true} | style], else: style
    if face.reverse, do: [{:reverse, true} | style], else: style
  end

  @spec add_extended_attrs(keyword(), t()) :: keyword()
  defp add_extended_attrs(style, face) do
    style =
      if face.underline_style && face.underline_style != :line,
        do: [{:underline_style, face.underline_style} | style],
        else: style

    style =
      if face.underline_color,
        do: [{:underline_color, face.underline_color} | style],
        else: style

    style =
      if face.blend && face.blend < 100,
        do: [{:blend, face.blend} | style],
        else: style

    style =
      if face.font_weight && face.font_weight != :regular,
        do: [{:font_weight, face.font_weight} | style],
        else: style

    if face.font_family,
      do: [{:font_family, face.font_family} | style],
      else: style
  end

  @doc """
  Creates a face from a style keyword list (as used in Theme syntax maps).

  This converts the existing `[fg: 0xFF6C6B, bold: true]` format into a
  Face struct. The `name` and optional `inherit` are provided separately.

  ## Examples

      iex> Face.from_style("keyword", [fg: 0xC678DD, bold: true])
      %Face{name: "keyword", fg: 0xC678DD, bold: true, inherit: nil}

      iex> Face.from_style("keyword.function", [fg: 0xC678DD, bold: true], inherit: "keyword")
      %Face{name: "keyword.function", fg: 0xC678DD, bold: true, inherit: "keyword"}
  """
  @spec from_style(String.t(), keyword(), keyword()) :: t()
  def from_style(name, style, opts \\ []) when is_binary(name) and is_list(style) do
    inherit = Keyword.get(opts, :inherit)

    %__MODULE__{
      name: name,
      inherit: inherit,
      fg: Keyword.get(style, :fg),
      bg: Keyword.get(style, :bg),
      bold: Keyword.get(style, :bold),
      italic: Keyword.get(style, :italic),
      underline: Keyword.get(style, :underline),
      underline_style: Keyword.get(style, :underline_style),
      underline_color: Keyword.get(style, :underline_color),
      strikethrough: Keyword.get(style, :strikethrough),
      reverse: Keyword.get(style, :reverse),
      blend: Keyword.get(style, :blend),
      font_family: Keyword.get(style, :font_family),
      font_weight: Keyword.get(style, :font_weight),
      font_slant: Keyword.get(style, :font_slant),
      font_features: Keyword.get(style, :font_features)
    }
  end

  @doc """
  Infers the parent face name from a dotted capture name.

  Strips the last `.segment` to produce the parent. Single-segment
  names (e.g., `"keyword"`) return `"default"`.

  ## Examples

      iex> Face.infer_parent("keyword.function.builtin")
      "keyword.function"

      iex> Face.infer_parent("keyword")
      "default"

      iex> Face.infer_parent("default")
      nil
  """
  @spec infer_parent(String.t()) :: String.t() | nil
  def infer_parent("default"), do: nil

  def infer_parent(name) when is_binary(name) do
    case String.split(name, ".") do
      [_single] -> "default"
      parts -> parts |> Enum.slice(0..-2//1) |> Enum.join(".")
    end
  end
end
