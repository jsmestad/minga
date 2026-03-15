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
    :popup,
    :tree
  ]

  defstruct [
    :name,
    :syntax,
    :editor,
    :gutter,
    :git,
    :modeline,
    :picker,
    :minibuffer,
    :search,
    :popup,
    :tree,
    :agent,
    :tab_bar,
    :dashboard
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
          git: Minga.Theme.Git.t(),
          modeline: Minga.Theme.Modeline.t(),
          picker: Minga.Theme.Picker.t(),
          minibuffer: Minga.Theme.Minibuffer.t(),
          search: Minga.Theme.Search.t(),
          popup: Minga.Theme.Popup.t(),
          tree: Minga.Theme.Tree.t(),
          agent: Minga.Theme.Agent.t() | nil,
          tab_bar: Minga.Theme.TabBar.t() | nil,
          dashboard: Minga.Theme.Dashboard.t() | nil
        }

  # ── Color group structs ─────────────────────────────────────────────────────

  defmodule Editor do
    @moduledoc "Editor chrome colors: background, foreground, tilde lines, split borders, cursorline, nav-flash."
    @enforce_keys [:bg, :fg, :tilde_fg, :split_border_fg]
    defstruct [:bg, :fg, :tilde_fg, :split_border_fg, :cursorline_bg, :nav_flash_bg]

    @type t :: %__MODULE__{
            bg: Minga.Theme.color(),
            fg: Minga.Theme.color(),
            tilde_fg: Minga.Theme.color(),
            split_border_fg: Minga.Theme.color(),
            cursorline_bg: Minga.Theme.color() | nil,
            nav_flash_bg: Minga.Theme.color() | nil
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

  defmodule Git do
    @moduledoc "Git gutter indicator colors."
    @enforce_keys [:added_fg, :modified_fg, :deleted_fg]
    defstruct [:added_fg, :modified_fg, :deleted_fg]

    @type t :: %__MODULE__{
            added_fg: Minga.Theme.color(),
            modified_fg: Minga.Theme.color(),
            deleted_fg: Minga.Theme.color()
          }
  end

  defmodule Modeline do
    @moduledoc "Modeline (status bar) colors."
    @enforce_keys [:bar_fg, :bar_bg, :info_fg, :info_bg, :filetype_fg, :mode_colors]
    defstruct [
      :bar_fg,
      :bar_bg,
      :info_fg,
      :info_bg,
      :filetype_fg,
      :mode_colors,
      lsp_ready: nil,
      lsp_initializing: nil,
      lsp_starting: nil,
      lsp_error: nil
    ]

    @type t :: %__MODULE__{
            bar_fg: Minga.Theme.color(),
            bar_bg: Minga.Theme.color(),
            info_fg: Minga.Theme.color(),
            info_bg: Minga.Theme.color(),
            filetype_fg: Minga.Theme.color(),
            mode_colors: %{atom() => {fg :: Minga.Theme.color(), bg :: Minga.Theme.color()}},
            lsp_ready: Minga.Theme.color() | nil,
            lsp_initializing: Minga.Theme.color() | nil,
            lsp_starting: Minga.Theme.color() | nil,
            lsp_error: Minga.Theme.color() | nil
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
    @moduledoc "Popup (which-key, floating window, etc.) colors."
    @enforce_keys [:fg, :bg, :border_fg]
    defstruct [
      :fg,
      :bg,
      :border_fg,
      :sel_fg,
      :sel_bg,
      :title_fg,
      :key_fg,
      :separator_fg,
      :group_fg
    ]

    @type t :: %__MODULE__{
            fg: Minga.Theme.color(),
            bg: Minga.Theme.color(),
            border_fg: Minga.Theme.color(),
            sel_fg: Minga.Theme.color() | nil,
            sel_bg: Minga.Theme.color() | nil,
            title_fg: Minga.Theme.color() | nil,
            key_fg: Minga.Theme.color() | nil,
            separator_fg: Minga.Theme.color() | nil,
            group_fg: Minga.Theme.color() | nil
          }
  end

  defmodule TabBar do
    @moduledoc "Tab bar colors."
    @enforce_keys [
      :active_fg,
      :active_bg,
      :inactive_fg,
      :inactive_bg,
      :separator_fg,
      :modified_fg,
      :attention_fg,
      :close_hover_fg,
      :bg
    ]
    defstruct [
      :active_fg,
      :active_bg,
      :inactive_fg,
      :inactive_bg,
      :separator_fg,
      :modified_fg,
      :attention_fg,
      :close_hover_fg,
      :bg
    ]

    @type t :: %__MODULE__{
            active_fg: Minga.Theme.color(),
            active_bg: Minga.Theme.color(),
            inactive_fg: Minga.Theme.color(),
            inactive_bg: Minga.Theme.color(),
            separator_fg: Minga.Theme.color(),
            modified_fg: Minga.Theme.color(),
            attention_fg: Minga.Theme.color(),
            close_hover_fg: Minga.Theme.color(),
            bg: Minga.Theme.color()
          }
  end

  defmodule Agent do
    @moduledoc "AI agent chat panel colors."
    @enforce_keys [
      :panel_bg,
      :panel_border,
      :header_fg,
      :header_bg,
      :user_border,
      :user_label,
      :assistant_border,
      :assistant_label,
      :tool_border,
      :tool_header,
      :code_bg,
      :code_border,
      :input_border,
      :input_bg,
      :input_placeholder,
      :thinking_fg,
      :status_thinking,
      :status_tool,
      :status_error,
      :status_idle,
      :text_fg,
      :context_low,
      :context_mid,
      :context_high,
      :usage_fg,
      :toast_bg,
      :toast_fg,
      :toast_border,
      :system_fg,
      :search_match_bg,
      :search_current_bg,
      :heading1_fg,
      :heading2_fg,
      :heading3_fg,
      :hint_fg,
      :dashboard_label
    ]

    defstruct [
      :panel_bg,
      :panel_border,
      :header_fg,
      :header_bg,
      :user_border,
      :user_label,
      :assistant_border,
      :assistant_label,
      :tool_border,
      :tool_header,
      :code_bg,
      :code_border,
      :input_border,
      :input_bg,
      :input_placeholder,
      :thinking_fg,
      :status_thinking,
      :status_tool,
      :status_error,
      :status_idle,
      :text_fg,
      :context_low,
      :context_mid,
      :context_high,
      :usage_fg,
      :toast_bg,
      :toast_fg,
      :toast_border,
      :system_fg,
      :search_match_bg,
      :search_current_bg,
      :heading1_fg,
      :heading2_fg,
      :heading3_fg,
      :hint_fg,
      :dashboard_label
    ]

    @type t :: %__MODULE__{
            panel_bg: Minga.Theme.color(),
            panel_border: Minga.Theme.color(),
            header_fg: Minga.Theme.color(),
            header_bg: Minga.Theme.color(),
            user_border: Minga.Theme.color(),
            user_label: Minga.Theme.color(),
            assistant_border: Minga.Theme.color(),
            assistant_label: Minga.Theme.color(),
            tool_border: Minga.Theme.color(),
            tool_header: Minga.Theme.color(),
            code_bg: Minga.Theme.color(),
            code_border: Minga.Theme.color(),
            input_border: Minga.Theme.color(),
            input_bg: Minga.Theme.color(),
            input_placeholder: Minga.Theme.color(),
            thinking_fg: Minga.Theme.color(),
            status_thinking: Minga.Theme.color(),
            status_tool: Minga.Theme.color(),
            status_error: Minga.Theme.color(),
            status_idle: Minga.Theme.color(),
            text_fg: Minga.Theme.color(),
            context_low: Minga.Theme.color(),
            context_mid: Minga.Theme.color(),
            context_high: Minga.Theme.color(),
            usage_fg: Minga.Theme.color(),
            toast_bg: Minga.Theme.color(),
            toast_fg: Minga.Theme.color(),
            toast_border: Minga.Theme.color(),
            system_fg: Minga.Theme.color(),
            search_match_bg: Minga.Theme.color(),
            search_current_bg: Minga.Theme.color(),
            heading1_fg: Minga.Theme.color(),
            heading2_fg: Minga.Theme.color(),
            heading3_fg: Minga.Theme.color(),
            hint_fg: Minga.Theme.color(),
            dashboard_label: Minga.Theme.color()
          }
  end

  defmodule Dashboard do
    @moduledoc "Dashboard (home screen) colors."
    @enforce_keys [:bg, :logo_fg, :heading_fg, :item_fg, :item_active_bg, :shortcut_fg, :muted_fg]
    defstruct [:bg, :logo_fg, :heading_fg, :item_fg, :item_active_bg, :shortcut_fg, :muted_fg]

    @type t :: %__MODULE__{
            bg: Minga.Theme.color(),
            logo_fg: Minga.Theme.color(),
            heading_fg: Minga.Theme.color(),
            item_fg: Minga.Theme.color(),
            item_active_bg: Minga.Theme.color(),
            shortcut_fg: Minga.Theme.color(),
            muted_fg: Minga.Theme.color()
          }
  end

  defmodule Tree do
    @moduledoc "File tree sidebar colors."
    @enforce_keys [
      :bg,
      :fg,
      :dir_fg,
      :active_fg,
      :cursor_bg,
      :header_fg,
      :header_bg,
      :separator_fg
    ]
    defstruct [
      :bg,
      :fg,
      :dir_fg,
      :active_fg,
      :cursor_bg,
      :header_fg,
      :header_bg,
      :separator_fg,
      :modified_fg,
      :git_modified_fg,
      :git_staged_fg,
      :git_untracked_fg,
      :git_conflict_fg
    ]

    @type t :: %__MODULE__{
            bg: Minga.Theme.color(),
            fg: Minga.Theme.color(),
            dir_fg: Minga.Theme.color(),
            active_fg: Minga.Theme.color(),
            cursor_bg: Minga.Theme.color(),
            header_fg: Minga.Theme.color(),
            header_bg: Minga.Theme.color(),
            separator_fg: Minga.Theme.color(),
            modified_fg: Minga.Theme.color() | nil,
            git_modified_fg: Minga.Theme.color() | nil,
            git_staged_fg: Minga.Theme.color() | nil,
            git_untracked_fg: Minga.Theme.color() | nil,
            git_conflict_fg: Minga.Theme.color() | nil
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

  @doc "Returns the agent theme section, falling back to a basic default."
  @spec agent_theme(t()) :: Agent.t()
  def agent_theme(%__MODULE__{agent: nil}) do
    # Fallback for themes that don't define agent colors (safety net; all
    # built-in themes now define agent colors so this should not be hit).
    %Agent{
      panel_bg: 0x23272E,
      panel_border: 0x5B6268,
      header_fg: 0x51AFEF,
      header_bg: 0x1E2127,
      user_border: 0x51AFEF,
      user_label: 0x51AFEF,
      assistant_border: 0x98BE65,
      assistant_label: 0x98BE65,
      tool_border: 0xECBE7B,
      tool_header: 0xECBE7B,
      code_bg: 0x1E2127,
      code_border: 0x5B6268,
      input_border: 0x51AFEF,
      input_bg: 0x23272E,
      input_placeholder: 0x5B6268,
      thinking_fg: 0xECBE7B,
      status_thinking: 0xECBE7B,
      status_tool: 0x46D9FF,
      status_error: 0xFF6C6B,
      status_idle: 0x5B6268,
      text_fg: 0xBBC2CF,
      context_low: 0x98BE65,
      context_mid: 0xECBE7B,
      context_high: 0xFF6C6B,
      usage_fg: 0x5B6268,
      toast_bg: 0x3F444A,
      toast_fg: 0xBBC2CF,
      toast_border: 0x73797E,
      system_fg: 0x73797E,
      search_match_bg: 0xECBE7B,
      search_current_bg: 0xFF6C6B,
      heading1_fg: 0xC678DD,
      heading2_fg: 0x51AFEF,
      heading3_fg: 0x98BE65,
      hint_fg: 0x5C6370,
      dashboard_label: 0x61AFEF
    }
  end

  def agent_theme(%__MODULE__{agent: agent}), do: agent

  @doc "Returns the dashboard theme section, falling back to a basic default."
  @spec dashboard_theme(t()) :: Dashboard.t()
  def dashboard_theme(%__MODULE__{dashboard: nil}) do
    %Dashboard{
      bg: 0x282C34,
      logo_fg: 0xECBE7B,
      heading_fg: 0x51AFEF,
      item_fg: 0xBBC2CF,
      item_active_bg: 0x3E4451,
      shortcut_fg: 0x98BE65,
      muted_fg: 0x5B6268
    }
  end

  def dashboard_theme(%__MODULE__{dashboard: dashboard}), do: dashboard

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
  @spec style_for_capture(t() | syntax(), String.t()) :: style()
  def style_for_capture(%__MODULE__{syntax: syntax}, name) when is_binary(name) do
    do_capture_lookup(syntax, name)
  end

  def style_for_capture(syntax, name) when is_map(syntax) and is_binary(name) do
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
