defmodule Minga.Theme do
  @moduledoc """
  Unified color theme for the entire editor.

  A theme holds every color the UI needs, organized into semantic groups:
  syntax highlighting, editor chrome, modeline, gutter, picker, minibuffer,
  search highlights, and popups. Built-in themes are functions that return
  a populated `%Theme{}` struct.

  ## Usage in config

      use Minga.Config
      set :theme, :catppuccin_mocha

  ## Built-in themes

  #{Enum.map_join([:doom_one, :catppuccin_frappe, :catppuccin_latte, :catppuccin_macchiato, :catppuccin_mocha, :one_dark, :one_light], "\n", &"  - `:#{&1}`")}
  """

  alias Minga.Theme.{CatppuccinFrappe, CatppuccinLatte, CatppuccinMacchiato, CatppuccinMocha}
  alias Minga.Theme.{DoomOne, OneDark, OneLight}

  @enforce_keys [
    :name,
    :syntax,
    :editor,
    :gutter,
    :modeline,
    :picker,
    :minibuffer,
    :search,
    :popup
  ]

  defstruct [
    :name,
    :syntax,
    :editor,
    :gutter,
    :modeline,
    :picker,
    :minibuffer,
    :search,
    :popup
  ]

  @typedoc "RGB color as a non-negative integer (e.g., `0xFF6C6B`)."
  @type color :: non_neg_integer()

  @typedoc "A style keyword list compatible with `Minga.Port.Protocol.style()`."
  @type style :: keyword()

  @typedoc "Syntax theme: tree-sitter capture name → style."
  @type syntax :: %{String.t() => style()}

  @type t :: %__MODULE__{
          name: atom(),
          syntax: syntax(),
          editor: Minga.Theme.Editor.t(),
          gutter: Minga.Theme.Gutter.t(),
          modeline: Minga.Theme.Modeline.t(),
          picker: Minga.Theme.Picker.t(),
          minibuffer: Minga.Theme.Minibuffer.t(),
          search: Minga.Theme.Search.t(),
          popup: Minga.Theme.Popup.t()
        }

  # ── Color group structs ─────────────────────────────────────────────────────

  defmodule Editor do
    @moduledoc "Editor chrome colors: background, foreground, tilde lines, split borders."
    @enforce_keys [:bg, :fg, :tilde_fg, :split_border_fg]
    defstruct [:bg, :fg, :tilde_fg, :split_border_fg]

    @type t :: %__MODULE__{
            bg: Minga.Theme.color(),
            fg: Minga.Theme.color(),
            tilde_fg: Minga.Theme.color(),
            split_border_fg: Minga.Theme.color()
          }
  end

  defmodule Gutter do
    @moduledoc "Gutter (line number column) colors."
    @enforce_keys [:fg, :current_fg, :error_fg, :warning_fg, :info_fg, :hint_fg]
    defstruct [:fg, :current_fg, :error_fg, :warning_fg, :info_fg, :hint_fg]

    @type t :: %__MODULE__{
            fg: Minga.Theme.color(),
            current_fg: Minga.Theme.color(),
            error_fg: Minga.Theme.color(),
            warning_fg: Minga.Theme.color(),
            info_fg: Minga.Theme.color(),
            hint_fg: Minga.Theme.color()
          }
  end

  defmodule Modeline do
    @moduledoc "Modeline (status bar) colors."
    @enforce_keys [:bar_fg, :bar_bg, :info_fg, :info_bg, :filetype_fg, :mode_colors]
    defstruct [:bar_fg, :bar_bg, :info_fg, :info_bg, :filetype_fg, :mode_colors]

    @type t :: %__MODULE__{
            bar_fg: Minga.Theme.color(),
            bar_bg: Minga.Theme.color(),
            info_fg: Minga.Theme.color(),
            info_bg: Minga.Theme.color(),
            filetype_fg: Minga.Theme.color(),
            mode_colors: %{atom() => {fg :: Minga.Theme.color(), bg :: Minga.Theme.color()}}
          }
  end

  defmodule Picker do
    @moduledoc "Picker (fuzzy finder) colors."

    @enforce_keys [
      :bg,
      :sel_bg,
      :prompt_bg,
      :dim_fg,
      :text_fg,
      :highlight_fg,
      :match_fg,
      :border_fg,
      :menu_bg,
      :menu_fg,
      :menu_sel_bg,
      :menu_sel_fg
    ]

    defstruct [
      :bg,
      :sel_bg,
      :prompt_bg,
      :dim_fg,
      :text_fg,
      :highlight_fg,
      :match_fg,
      :border_fg,
      :menu_bg,
      :menu_fg,
      :menu_sel_bg,
      :menu_sel_fg
    ]

    @type t :: %__MODULE__{
            bg: Minga.Theme.color(),
            sel_bg: Minga.Theme.color(),
            prompt_bg: Minga.Theme.color(),
            dim_fg: Minga.Theme.color(),
            text_fg: Minga.Theme.color(),
            highlight_fg: Minga.Theme.color(),
            match_fg: Minga.Theme.color(),
            border_fg: Minga.Theme.color(),
            menu_bg: Minga.Theme.color(),
            menu_fg: Minga.Theme.color(),
            menu_sel_bg: Minga.Theme.color(),
            menu_sel_fg: Minga.Theme.color()
          }
  end

  defmodule Minibuffer do
    @moduledoc "Minibuffer (command line) colors."
    @enforce_keys [:fg, :bg, :warning_fg, :dim_fg]
    defstruct [:fg, :bg, :warning_fg, :dim_fg]

    @type t :: %__MODULE__{
            fg: Minga.Theme.color(),
            bg: Minga.Theme.color(),
            warning_fg: Minga.Theme.color(),
            dim_fg: Minga.Theme.color()
          }
  end

  defmodule Search do
    @moduledoc "Search highlight colors."
    @enforce_keys [:highlight_fg, :highlight_bg, :current_bg]
    defstruct [:highlight_fg, :highlight_bg, :current_bg]

    @type t :: %__MODULE__{
            highlight_fg: Minga.Theme.color(),
            highlight_bg: Minga.Theme.color(),
            current_bg: Minga.Theme.color()
          }
  end

  defmodule Popup do
    @moduledoc "Popup (which-key, etc.) colors."
    @enforce_keys [:fg, :bg, :border_fg]
    defstruct [:fg, :bg, :border_fg]

    @type t :: %__MODULE__{
            fg: Minga.Theme.color(),
            bg: Minga.Theme.color(),
            border_fg: Minga.Theme.color()
          }
  end

  # ── Theme registry ──────────────────────────────────────────────────────────

  @themes %{
    doom_one: DoomOne,
    catppuccin_frappe: CatppuccinFrappe,
    catppuccin_latte: CatppuccinLatte,
    catppuccin_macchiato: CatppuccinMacchiato,
    catppuccin_mocha: CatppuccinMocha,
    one_dark: OneDark,
    one_light: OneLight
  }

  @doc "Returns the theme struct for the given name atom."
  @spec get(atom()) :: {:ok, t()} | :error
  def get(name) when is_atom(name) do
    case Map.get(@themes, name) do
      nil -> :error
      module -> {:ok, module.theme()}
    end
  end

  @doc "Returns the theme struct for the given name, raising on invalid name."
  @spec get!(atom()) :: t()
  def get!(name) when is_atom(name) do
    case get(name) do
      {:ok, theme} ->
        theme

      :error ->
        raise ArgumentError,
              "unknown theme: #{inspect(name)}, available: #{inspect(available())}"
    end
  end

  @doc "Returns the list of available built-in theme name atoms."
  @spec available() :: [atom()]
  def available, do: Map.keys(@themes)

  @doc "Returns the default theme name atom."
  @spec default() :: atom()
  def default, do: :doom_one

  @doc """
  Returns the style for a tree-sitter capture name, using suffix fallback.

  Tries exact match first. If not found, strips the last `.segment` and
  retries. Returns `[]` if no match is found.

  ## Examples

      iex> theme = Minga.Theme.get!(:doom_one)
      iex> style = Minga.Theme.style_for_capture(theme, "keyword")
      iex> Keyword.get(style, :bold)
      true

      iex> theme = Minga.Theme.get!(:doom_one)
      iex> Minga.Theme.style_for_capture(theme, "nonexistent")
      []
  """
  @spec style_for_capture(t(), String.t()) :: style()
  def style_for_capture(%__MODULE__{syntax: syntax}, name) when is_binary(name) do
    do_capture_lookup(syntax, name)
  end

  @spec do_capture_lookup(syntax(), String.t()) :: style()
  defp do_capture_lookup(syntax, name) do
    case Map.get(syntax, name) do
      nil -> fallback_lookup(syntax, name)
      style -> style
    end
  end

  @spec fallback_lookup(syntax(), String.t()) :: style()
  defp fallback_lookup(syntax, name) do
    case String.split(name, ".") do
      [_single] ->
        []

      parts ->
        parent = parts |> Enum.slice(0..-2//1) |> Enum.join(".")
        do_capture_lookup(syntax, parent)
    end
  end
end
