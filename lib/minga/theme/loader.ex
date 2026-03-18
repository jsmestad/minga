defmodule Minga.Theme.Loader do
  @moduledoc """
  Discovers and loads user-defined theme files from disk.

  Theme files are Elixir scripts (`.exs`) that return a map describing
  face overrides, editor chrome colors, and optional inheritance from
  a built-in theme. They live in `~/.config/minga/themes/` and are
  evaluated at startup and on `:reload_themes`.

  ## Theme file format

  A theme file must return a map with at least a `:name` key:

      # ~/.config/minga/themes/my_dark.exs
      %{
        name: :my_dark,
        inherits: :doom_one,
        faces: %{
          "keyword" => [fg: 0xFF79C6, bold: true],
          "comment" => [fg: 0x6272A4, italic: true],
          "@lsp.type.variable" => [fg: 0xBD93F9]
        },
        editor: %{bg: 0x282A36, fg: 0xF8F8F2}
      }

  ## Schema

  - `:name` (required) — atom identifying the theme
  - `:inherits` (optional) — atom name of a built-in theme to extend.
    The built-in theme's syntax map and editor colors are used as the
    base; the file's `:faces` and `:editor` fields override them.
  - `:faces` (optional) — map of face name strings to style keyword
    lists. Merged via `Face.Registry.with_overrides/2`.
  - `:editor` (optional) — map of editor chrome color overrides
    (`:bg`, `:fg`, `:tilde_fg`, `:split_border_fg`, etc.)

  ## Discovery

  Theme files are found at:
  1. `$XDG_CONFIG_HOME/minga/themes/*.exs` (if `$XDG_CONFIG_HOME` is set)
  2. `~/.config/minga/themes/*.exs`
  """

  alias Minga.Face.Registry, as: FaceRegistry
  alias Minga.Theme

  defmodule LoadedTheme do
    @moduledoc "A loaded user theme with its face registry and metadata."
    @enforce_keys [:name, :theme, :face_registry, :source_path]
    defstruct [:name, :theme, :face_registry, :source_path]

    @type t :: %__MODULE__{
            name: atom(),
            theme: Minga.Theme.t(),
            face_registry: Minga.Face.Registry.t(),
            source_path: String.t()
          }
  end

  defmodule LoadError do
    @moduledoc "An error encountered while loading a theme file."
    @enforce_keys [:path, :error]
    defstruct [:path, :error]

    @type t :: %__MODULE__{
            path: String.t(),
            error: String.t()
          }
  end

  @typedoc "A loaded user theme with its face registry and metadata."
  @type loaded_theme :: LoadedTheme.t()

  @typedoc "An error encountered while loading a theme file."
  @type load_error :: LoadError.t()

  @doc """
  Discovers and loads all theme files from the themes directory.

  Returns `{loaded_themes, errors}` where `loaded_themes` is a map
  of theme name atoms to loaded theme structs, and `errors` is a
  list of load errors.
  """
  @spec load_all(String.t()) :: {%{atom() => loaded_theme()}, [load_error()]}
  def load_all(dir \\ themes_dir()) do
    if File.dir?(dir) do
      dir
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce({%{}, []}, &accumulate_theme/2)
      |> then(fn {themes, errors} -> {themes, Enum.reverse(errors)} end)
    else
      {%{}, []}
    end
  end

  @spec accumulate_theme(String.t(), {map(), [load_error()]}) :: {map(), [load_error()]}
  defp accumulate_theme(path, {themes, errors}) do
    case load_file(path) do
      {:ok, loaded} -> {Map.put(themes, loaded.name, loaded), errors}
      {:error, error} -> {themes, [error | errors]}
    end
  end

  @doc """
  Loads a single theme file.

  Returns `{:ok, loaded_theme}` or `{:error, load_error}`.
  """
  @spec load_file(String.t()) :: {:ok, loaded_theme()} | {:error, load_error()}
  def load_file(path) when is_binary(path) do
    case eval_theme_file(path) do
      {:ok, data} -> build_theme(data, path)
      {:error, reason} -> {:error, %LoadError{path: path, error: reason}}
    end
  end

  @doc """
  Returns the themes directory path.
  """
  @spec themes_dir() :: String.t()
  def themes_dir do
    config_home =
      System.get_env("XDG_CONFIG_HOME") ||
        Path.join(System.user_home!(), ".config")

    Path.join([config_home, "minga", "themes"])
  end

  # ── Private ──────────────────────────────────────────────────────────

  @spec eval_theme_file(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp eval_theme_file(path) do
    {result, _bindings} = Code.eval_file(path)

    case result do
      %{name: name} when is_atom(name) -> {:ok, result}
      %{} -> {:error, "theme file must include a :name key (atom)"}
      _ -> {:error, "theme file must return a map, got: #{inspect(result)}"}
    end
  rescue
    e -> {:error, "#{Exception.format(:error, e)}"}
  end

  @spec build_theme(map(), String.t()) :: {:ok, loaded_theme()} | {:error, load_error()}
  defp build_theme(data, path) do
    name = data.name
    base_theme = resolve_base_theme(data)

    # Apply editor color overrides
    theme = apply_editor_overrides(base_theme, data)
    theme = %{theme | name: name}

    # Build face registry from the theme, then apply face overrides
    registry = FaceRegistry.from_theme(theme)

    registry =
      case Map.get(data, :faces) do
        nil -> registry
        faces when is_map(faces) -> FaceRegistry.with_overrides(registry, faces)
      end

    registry = FaceRegistry.with_lsp_defaults(registry)

    {:ok, %LoadedTheme{name: name, theme: theme, face_registry: registry, source_path: path}}
  rescue
    e ->
      {:error,
       %LoadError{
         path: path,
         error: "building theme #{inspect(data[:name])}: #{Exception.format(:error, e)}"
       }}
  end

  @spec resolve_base_theme(map()) :: Theme.t()
  defp resolve_base_theme(%{inherits: base_name}) when is_atom(base_name) do
    case Theme.get(base_name) do
      {:ok, theme} -> theme
      :error -> Theme.get!(:doom_one)
    end
  end

  defp resolve_base_theme(_data), do: Theme.get!(:doom_one)

  @editor_fields MapSet.new(
                   Map.keys(%Theme.Editor{bg: 0, fg: 0, tilde_fg: 0, split_border_fg: 0}) --
                     [:__struct__]
                 )

  @spec apply_editor_overrides(Theme.t(), map()) :: Theme.t()
  defp apply_editor_overrides(theme, %{editor: overrides}) when is_map(overrides) do
    editor =
      Enum.reduce(overrides, theme.editor, fn {key, value}, ed ->
        if MapSet.member?(@editor_fields, key) do
          %{ed | key => value}
        else
          ed
        end
      end)

    %{theme | editor: editor}
  end

  defp apply_editor_overrides(theme, _data), do: theme
end
