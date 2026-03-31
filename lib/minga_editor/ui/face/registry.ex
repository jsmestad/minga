defmodule MingaEditor.UI.Face.Registry do
  @moduledoc """
  Named face storage and lookup with cached inheritance resolution.

  The registry holds all defined faces and caches their resolved
  (fully-inherited) forms. When a face is looked up, the registry
  returns the resolved version with no `nil` fields.

  ## Building a registry

  A registry is built from a theme's syntax map using `from_theme/1`,
  which converts every `capture_name => style` entry into a `Face`
  struct with proper inheritance wired by dotted-name convention.

  ## Resolution caching

  `resolve_all/1` pre-computes every face's resolved form and stores
  it alongside the raw faces. Subsequent `resolve/2` calls return the
  cached result in O(1).

  ## Buffer-local overrides

  `with_overrides/2` merges buffer-local face overrides (e.g., from
  face remapping) on top of the base registry. The overrides are
  merged attribute-by-attribute, and the resolution cache is rebuilt.
  """

  alias Minga.Core.Face

  @enforce_keys [:faces, :resolved]
  defstruct faces: %{},
            resolved: %{}

  @typedoc "Map of face name to face struct."
  @type face_map :: %{String.t() => Face.t()}

  @type t :: %__MODULE__{
          faces: face_map(),
          resolved: face_map()
        }

  @doc """
  Creates an empty registry with only the default face.
  """
  @spec new() :: t()
  def new do
    default = Face.default()

    %__MODULE__{
      faces: %{"default" => default},
      resolved: %{"default" => default}
    }
  end

  @doc """
  Builds a registry from a theme's syntax map.

  Converts each `capture_name => style_keyword_list` entry into a Face
  struct. Inheritance is inferred from dotted names: `"keyword.function"`
  inherits from `"keyword"`, which inherits from `"default"`.

  The registry is pre-resolved after building, so all lookups return
  fully resolved faces.

  ## Examples

      iex> syntax = %{"keyword" => [fg: 0xC678DD, bold: true], "keyword.function" => [fg: 0xC678DD]}
      iex> reg = Registry.from_syntax(syntax)
      iex> face = Registry.resolve(reg, "keyword.function")
      iex> face.bold
      true
  """
  @spec from_syntax(MingaEditor.UI.Theme.syntax()) :: t()
  def from_syntax(syntax) when is_map(syntax) do
    default = Face.default()

    faces =
      syntax
      |> Enum.reduce(%{"default" => default}, fn {name, style}, acc ->
        parent = Face.infer_parent(name)
        face = Face.from_style(name, style, inherit: parent)
        Map.put(acc, name, face)
      end)

    %__MODULE__{faces: faces, resolved: %{}}
    |> resolve_all()
  end

  @doc """
  Builds a registry from a full `MingaEditor.UI.Theme.t()` struct.

  Uses the theme's syntax map and sets the default face's fg/bg from
  the theme's editor colors.
  """
  @spec from_theme(MingaEditor.UI.Theme.t()) :: t()
  def from_theme(%MingaEditor.UI.Theme{} = theme) do
    default =
      %{Face.default() | fg: theme.editor.fg, bg: theme.editor.bg}

    faces =
      theme.syntax
      |> Enum.reduce(%{"default" => default}, fn {name, style}, acc ->
        parent = Face.infer_parent(name)
        face = Face.from_style(name, style, inherit: parent)
        Map.put(acc, name, face)
      end)

    %__MODULE__{faces: faces, resolved: %{}}
    |> resolve_all()
  end

  @doc """
  Looks up a face by name. Returns the raw (unresolved) face or nil.
  """
  @spec get(t(), String.t()) :: Face.t() | nil
  def get(%__MODULE__{faces: faces}, name) when is_binary(name) do
    Map.get(faces, name)
  end

  @doc """
  Resolves a face by name, returning the fully-inherited version.

  If the face is in the resolution cache, returns it directly.
  If not found by exact name, falls back through the dotted name
  hierarchy (e.g., `"keyword.function.builtin"` tries
  `"keyword.function"`, then `"keyword"`, then `"default"`).

  Always returns a face (falls back to default).
  """
  @spec resolve(t(), String.t()) :: Face.t()
  def resolve(%__MODULE__{resolved: resolved} = reg, name) when is_binary(name) do
    case Map.get(resolved, name) do
      nil -> resolve_with_fallback(reg, name)
      face -> face
    end
  end

  @doc """
  Resolves a face by name and returns a `Face.t()`.

  This is the main entry point for the render pipeline, replacing
  `Theme.style_for_capture/2`. Returns a fully resolved face struct.
  For composite capture names (e.g., "@lsp.type.variable+deprecated"),
  modifier attributes are composed on top of the base face.

  Always returns a face (falls back to default).
  """
  @spec style_for(t(), String.t()) :: Face.t()
  def style_for(%__MODULE__{} = reg, name) when is_binary(name) do
    # Check for composite capture names (e.g., "@lsp.type.variable+deprecated")
    case String.split(name, "+") do
      [base_name | modifiers] when modifiers != [] ->
        mod_names = Enum.map(modifiers, &"@lsp.mod.#{&1}")
        style_for_with_modifiers(reg, base_name, mod_names)

      _ ->
        resolve(reg, name)
    end
  end

  @doc """
  Adds or replaces a face in the registry.

  The resolution cache is invalidated for any face that could be
  affected (the face itself and all descendants). Call `resolve_all/1`
  after batch updates to rebuild the cache.
  """
  @spec put(t(), Face.t()) :: t()
  def put(%__MODULE__{faces: faces} = reg, %Face{name: name} = face) do
    updated_faces = Map.put(faces, name, face)
    # Invalidate this face and all descendants from the cache
    invalidated =
      reg.resolved
      |> Map.reject(fn {rname, _} ->
        rname == name || String.starts_with?(rname, name <> ".")
      end)

    %{reg | faces: updated_faces, resolved: invalidated}
  end

  @doc """
  Merges buffer-local face overrides on top of the base registry.

  Each override is a `{face_name, attribute_overrides}` pair where
  attribute_overrides is a keyword list of face fields to override.
  Returns a new registry with the overrides merged and the resolution
  cache rebuilt.

  ## Examples

      iex> reg = Registry.from_syntax(%{"keyword" => [fg: 0xC678DD, bold: true]})
      iex> reg = Registry.with_overrides(reg, %{"keyword" => [fg: 0xFF0000]})
      iex> face = Registry.resolve(reg, "keyword")
      iex> face.fg
      0xFF0000
      iex> face.bold
      true
  """
  @face_fields MapSet.new(Map.keys(%Face{name: ""}) -- [:__struct__])

  @spec with_overrides(t(), %{String.t() => keyword()}) :: t()
  def with_overrides(%__MODULE__{} = reg, overrides) when is_map(overrides) do
    updated =
      Enum.reduce(overrides, reg.faces, fn {name, attrs}, faces ->
        base = Map.get(faces, name, %Face{name: name, inherit: Face.infer_parent(name)})
        merged = merge_face_attrs(base, name, attrs)
        Map.put(faces, name, merged)
      end)

    %{reg | faces: updated, resolved: %{}}
    |> resolve_all()
  end

  @spec merge_face_attrs(Face.t(), String.t(), keyword()) :: Face.t()
  defp merge_face_attrs(face, name, attrs) do
    Enum.reduce(attrs, face, fn {key, value}, acc ->
      unless MapSet.member?(@face_fields, key) do
        raise ArgumentError,
              "unknown face field #{inspect(key)} in override for #{inspect(name)}"
      end

      %{acc | key => value}
    end)
  end

  @doc """
  Pre-resolves all faces and populates the resolution cache.
  """
  @spec resolve_all(t()) :: t()
  def resolve_all(%__MODULE__{faces: faces} = reg) do
    lookup = fn name -> Map.get(faces, name) end

    resolved =
      faces
      |> Enum.reduce(%{}, fn {name, face}, acc ->
        Map.put(acc, name, Face.resolve(face, lookup))
      end)

    %{reg | resolved: resolved}
  end

  @doc """
  Returns all face names in the registry.
  """
  @spec names(t()) :: [String.t()]
  def names(%__MODULE__{faces: faces}) do
    Map.keys(faces)
  end

  @doc """
  Adds default LSP semantic token faces to the registry.

  Maps `@lsp.type.*` captures to their closest tree-sitter equivalents
  so semantic tokens render with sensible colors even without explicit
  theme support. Themes can override these by defining faces for
  `@lsp.type.variable`, `@lsp.mod.deprecated`, etc.

  Also adds modifier faces:
  - `@lsp.mod.deprecated` gets strikethrough
  - `@lsp.mod.readonly` inherits from the type face (no visual change by default)
  """
  @spec with_lsp_defaults(t()) :: t()
  def with_lsp_defaults(%__MODULE__{} = reg) do
    # Map LSP types to tree-sitter equivalents for fallback styling
    lsp_type_mappings = %{
      "@lsp.type.namespace" => "type",
      "@lsp.type.type" => "type",
      "@lsp.type.class" => "type",
      "@lsp.type.enum" => "type",
      "@lsp.type.interface" => "type",
      "@lsp.type.struct" => "type",
      "@lsp.type.typeParameter" => "type",
      "@lsp.type.parameter" => "variable",
      "@lsp.type.variable" => "variable",
      "@lsp.type.property" => "property",
      "@lsp.type.enumMember" => "constant",
      "@lsp.type.event" => "function",
      "@lsp.type.function" => "function",
      "@lsp.type.method" => "function.method",
      "@lsp.type.macro" => "function.macro",
      "@lsp.type.keyword" => "keyword",
      "@lsp.type.modifier" => "keyword.modifier",
      "@lsp.type.comment" => "comment",
      "@lsp.type.string" => "string",
      "@lsp.type.number" => "number",
      "@lsp.type.regexp" => "string.special.regex",
      "@lsp.type.operator" => "operator",
      "@lsp.type.decorator" => "attribute"
    }

    # Add type faces that inherit from their tree-sitter equivalent,
    # but don't overwrite faces the theme already defines.
    reg =
      Enum.reduce(lsp_type_mappings, reg, fn {lsp_name, ts_name}, acc ->
        if get(acc, lsp_name) do
          acc
        else
          put(acc, %Face{name: lsp_name, inherit: ts_name})
        end
      end)

    # Add modifier faces (only if not already defined)
    modifier_defaults = [
      %Face{name: "@lsp.mod.deprecated", inherit: "default", strikethrough: true},
      %Face{name: "@lsp.mod.readonly", inherit: "default"}
    ]

    reg =
      Enum.reduce(modifier_defaults, reg, fn face, acc ->
        if get(acc, face.name), do: acc, else: put(acc, face)
      end)

    resolve_all(reg)
  end

  @doc """
  Resolves a face with modifier composition.

  Takes a base capture name and a list of modifier names, resolves each,
  and merges modifier attributes on top of the base face. This is how
  `@lsp.mod.deprecated` adds strikethrough to whatever the type's color
  is, rather than replacing it.

  Returns a `Face.t()` with the base face's colors and the modifier
  face's decorative attributes composed.
  """
  @spec style_for_with_modifiers(t(), String.t(), [String.t()]) :: Face.t()
  def style_for_with_modifiers(%__MODULE__{} = reg, base_name, modifiers)
      when is_binary(base_name) and is_list(modifiers) do
    base_face = style_for(reg, base_name)

    Enum.reduce(modifiers, base_face, fn mod_name, acc ->
      mod_face = resolve(reg, mod_name)
      compose_modifier(acc, mod_face)
    end)
  end

  # Compose modifier attributes on top of a base face.
  # Only merges decorative attributes (strikethrough, underline, blend, italic, bold).
  # Does NOT override fg/bg from the modifier (those come from the base type).
  @spec compose_modifier(Face.t(), Face.t()) :: Face.t()
  defp compose_modifier(%Face{} = base, %Face{} = mod) do
    base
    |> merge_face_if(mod.strikethrough, :strikethrough)
    |> merge_face_if(mod.underline, :underline)
    |> merge_face_if(mod.italic, :italic)
    |> merge_face_if(mod.bold, :bold)
    |> merge_face_underline_style(mod)
    |> merge_face_blend(mod)
  end

  @spec merge_face_if(Face.t(), boolean() | nil, atom()) :: Face.t()
  defp merge_face_if(face, true, key), do: Map.put(face, key, true)
  defp merge_face_if(face, _, _key), do: face

  @spec merge_face_underline_style(Face.t(), Face.t()) :: Face.t()
  defp merge_face_underline_style(face, %Face{underline_style: nil}), do: face
  defp merge_face_underline_style(face, %Face{underline_style: :line}), do: face

  defp merge_face_underline_style(face, %Face{underline_style: us}),
    do: %{face | underline_style: us}

  @spec merge_face_blend(Face.t(), Face.t()) :: Face.t()
  defp merge_face_blend(face, %Face{blend: nil}), do: face
  defp merge_face_blend(face, %Face{blend: 100}), do: face
  defp merge_face_blend(face, %Face{blend: b}), do: %{face | blend: b}

  # Walk up the dotted name hierarchy to find the nearest matching face.
  @spec resolve_with_fallback(t(), String.t()) :: Face.t()
  defp resolve_with_fallback(%__MODULE__{resolved: resolved}, name) do
    case do_fallback(resolved, name) do
      nil -> Map.get(resolved, "default", Face.default())
      face -> face
    end
  end

  @spec do_fallback(face_map(), String.t()) :: Face.t() | nil
  defp do_fallback(resolved, name) do
    case Map.get(resolved, name) do
      nil ->
        parent = Face.infer_parent(name)

        case parent do
          nil -> nil
          pname -> do_fallback(resolved, pname)
        end

      face ->
        face
    end
  end
end
