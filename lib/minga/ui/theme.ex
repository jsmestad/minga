defmodule Minga.UI.Theme do
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

  alias Minga.UI.Theme.{CatppuccinFrappe, CatppuccinLatte, CatppuccinMacchiato, CatppuccinMocha}
  alias Minga.UI.Theme.{DoomOne, OneDark, OneLight}

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

  @typedoc "A style keyword list compatible with `Minga.Frontend.Protocol.style()`."
  @type style :: keyword()

  @typedoc "Syntax theme: tree-sitter capture name → style."
  @type syntax :: %{String.t() => style()}

  @type t :: %__MODULE__{
          name: atom(),
          syntax: syntax(),
          editor: Minga.UI.Theme.Editor.t(),
          gutter: Minga.UI.Theme.Gutter.t(),
          git: Minga.UI.Theme.Git.t(),
          modeline: Minga.UI.Theme.Modeline.t(),
          picker: Minga.UI.Theme.Picker.t(),
          minibuffer: Minga.UI.Theme.Minibuffer.t(),
          search: Minga.UI.Theme.Search.t(),
          popup: Minga.UI.Theme.Popup.t(),
          tree: Minga.UI.Theme.Tree.t(),
          agent: Minga.UI.Theme.Agent.t() | nil,
          tab_bar: Minga.UI.Theme.TabBar.t() | nil,
          dashboard: Minga.UI.Theme.Dashboard.t() | nil
        }

  # ── Color group structs ─────────────────────────────────────────────────────

  defmodule Editor do
    @moduledoc "Editor chrome colors: background, foreground, tilde lines, split borders, cursorline, nav-flash, highlight/selection."
    @enforce_keys [:bg, :fg, :tilde_fg, :split_border_fg]
    defstruct [
      :bg,
      :fg,
      :tilde_fg,
      :split_border_fg,
      :cursorline_bg,
      :nav_flash_bg,
      :highlight_read_bg,
      :highlight_write_bg,
      :selection_bg
    ]

    @type t :: %__MODULE__{
            bg: Minga.UI.Theme.color(),
            fg: Minga.UI.Theme.color(),
            tilde_fg: Minga.UI.Theme.color(),
            split_border_fg: Minga.UI.Theme.color(),
            cursorline_bg: Minga.UI.Theme.color() | nil,
            nav_flash_bg: Minga.UI.Theme.color() | nil,
            highlight_read_bg: Minga.UI.Theme.color() | nil,
            highlight_write_bg: Minga.UI.Theme.color() | nil,
            selection_bg: Minga.UI.Theme.color() | nil
          }
  end

  defmodule Gutter do
    @moduledoc "Gutter (line number column) colors."
    @enforce_keys [:fg, :current_fg, :error_fg, :warning_fg, :info_fg, :hint_fg]
    defstruct [:fg, :current_fg, :error_fg, :warning_fg, :info_fg, :hint_fg, :separator_fg]

    @type t :: %__MODULE__{
            fg: Minga.UI.Theme.color(),
            current_fg: Minga.UI.Theme.color(),
            error_fg: Minga.UI.Theme.color(),
            warning_fg: Minga.UI.Theme.color(),
            info_fg: Minga.UI.Theme.color(),
            hint_fg: Minga.UI.Theme.color(),
            separator_fg: Minga.UI.Theme.color() | nil
          }
  end

  defmodule Git do
    @moduledoc "Git gutter indicator colors."
    @enforce_keys [:added_fg, :modified_fg, :deleted_fg]
    defstruct [:added_fg, :modified_fg, :deleted_fg]

    @type t :: %__MODULE__{
            added_fg: Minga.UI.Theme.color(),
            modified_fg: Minga.UI.Theme.color(),
            deleted_fg: Minga.UI.Theme.color()
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
            bar_fg: Minga.UI.Theme.color(),
            bar_bg: Minga.UI.Theme.color(),
            info_fg: Minga.UI.Theme.color(),
            info_bg: Minga.UI.Theme.color(),
            filetype_fg: Minga.UI.Theme.color(),
            mode_colors: %{atom() => {fg :: Minga.UI.Theme.color(), bg :: Minga.UI.Theme.color()}},
            lsp_ready: Minga.UI.Theme.color() | nil,
            lsp_initializing: Minga.UI.Theme.color() | nil,
            lsp_starting: Minga.UI.Theme.color() | nil,
            lsp_error: Minga.UI.Theme.color() | nil
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
            bg: Minga.UI.Theme.color(),
            sel_bg: Minga.UI.Theme.color(),
            prompt_bg: Minga.UI.Theme.color(),
            dim_fg: Minga.UI.Theme.color(),
            text_fg: Minga.UI.Theme.color(),
            highlight_fg: Minga.UI.Theme.color(),
            match_fg: Minga.UI.Theme.color(),
            border_fg: Minga.UI.Theme.color(),
            menu_bg: Minga.UI.Theme.color(),
            menu_fg: Minga.UI.Theme.color(),
            menu_sel_bg: Minga.UI.Theme.color(),
            menu_sel_fg: Minga.UI.Theme.color()
          }
  end

  defmodule Minibuffer do
    @moduledoc "Minibuffer (command line) colors."
    @enforce_keys [:fg, :bg, :warning_fg, :dim_fg]
    defstruct [:fg, :bg, :warning_fg, :dim_fg]

    @type t :: %__MODULE__{
            fg: Minga.UI.Theme.color(),
            bg: Minga.UI.Theme.color(),
            warning_fg: Minga.UI.Theme.color(),
            dim_fg: Minga.UI.Theme.color()
          }
  end

  defmodule Search do
    @moduledoc "Search highlight colors."
    @enforce_keys [:highlight_fg, :highlight_bg, :current_bg]
    defstruct [:highlight_fg, :highlight_bg, :current_bg]

    @type t :: %__MODULE__{
            highlight_fg: Minga.UI.Theme.color(),
            highlight_bg: Minga.UI.Theme.color(),
            current_bg: Minga.UI.Theme.color()
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
            fg: Minga.UI.Theme.color(),
            bg: Minga.UI.Theme.color(),
            border_fg: Minga.UI.Theme.color(),
            sel_fg: Minga.UI.Theme.color() | nil,
            sel_bg: Minga.UI.Theme.color() | nil,
            title_fg: Minga.UI.Theme.color() | nil,
            key_fg: Minga.UI.Theme.color() | nil,
            separator_fg: Minga.UI.Theme.color() | nil,
            group_fg: Minga.UI.Theme.color() | nil
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
            active_fg: Minga.UI.Theme.color(),
            active_bg: Minga.UI.Theme.color(),
            inactive_fg: Minga.UI.Theme.color(),
            inactive_bg: Minga.UI.Theme.color(),
            separator_fg: Minga.UI.Theme.color(),
            modified_fg: Minga.UI.Theme.color(),
            attention_fg: Minga.UI.Theme.color(),
            close_hover_fg: Minga.UI.Theme.color(),
            bg: Minga.UI.Theme.color()
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
      :dashboard_label,
      :delimiter_dim,
      :link_fg
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
      :dashboard_label,
      :delimiter_dim,
      :link_fg
    ]

    @type t :: %__MODULE__{
            panel_bg: Minga.UI.Theme.color(),
            panel_border: Minga.UI.Theme.color(),
            header_fg: Minga.UI.Theme.color(),
            header_bg: Minga.UI.Theme.color(),
            user_border: Minga.UI.Theme.color(),
            user_label: Minga.UI.Theme.color(),
            assistant_border: Minga.UI.Theme.color(),
            assistant_label: Minga.UI.Theme.color(),
            tool_border: Minga.UI.Theme.color(),
            tool_header: Minga.UI.Theme.color(),
            code_bg: Minga.UI.Theme.color(),
            code_border: Minga.UI.Theme.color(),
            input_border: Minga.UI.Theme.color(),
            input_bg: Minga.UI.Theme.color(),
            input_placeholder: Minga.UI.Theme.color(),
            thinking_fg: Minga.UI.Theme.color(),
            status_thinking: Minga.UI.Theme.color(),
            status_tool: Minga.UI.Theme.color(),
            status_error: Minga.UI.Theme.color(),
            status_idle: Minga.UI.Theme.color(),
            text_fg: Minga.UI.Theme.color(),
            context_low: Minga.UI.Theme.color(),
            context_mid: Minga.UI.Theme.color(),
            context_high: Minga.UI.Theme.color(),
            usage_fg: Minga.UI.Theme.color(),
            toast_bg: Minga.UI.Theme.color(),
            toast_fg: Minga.UI.Theme.color(),
            toast_border: Minga.UI.Theme.color(),
            system_fg: Minga.UI.Theme.color(),
            search_match_bg: Minga.UI.Theme.color(),
            search_current_bg: Minga.UI.Theme.color(),
            heading1_fg: Minga.UI.Theme.color(),
            heading2_fg: Minga.UI.Theme.color(),
            heading3_fg: Minga.UI.Theme.color(),
            hint_fg: Minga.UI.Theme.color(),
            dashboard_label: Minga.UI.Theme.color(),
            delimiter_dim: Minga.UI.Theme.color(),
            link_fg: Minga.UI.Theme.color()
          }
  end

  defmodule Dashboard do
    @moduledoc "Dashboard (home screen) colors."
    @enforce_keys [:bg, :logo_fg, :heading_fg, :item_fg, :item_active_bg, :shortcut_fg, :muted_fg]
    defstruct [:bg, :logo_fg, :heading_fg, :item_fg, :item_active_bg, :shortcut_fg, :muted_fg]

    @type t :: %__MODULE__{
            bg: Minga.UI.Theme.color(),
            logo_fg: Minga.UI.Theme.color(),
            heading_fg: Minga.UI.Theme.color(),
            item_fg: Minga.UI.Theme.color(),
            item_active_bg: Minga.UI.Theme.color(),
            shortcut_fg: Minga.UI.Theme.color(),
            muted_fg: Minga.UI.Theme.color()
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
            bg: Minga.UI.Theme.color(),
            fg: Minga.UI.Theme.color(),
            dir_fg: Minga.UI.Theme.color(),
            active_fg: Minga.UI.Theme.color(),
            cursor_bg: Minga.UI.Theme.color(),
            header_fg: Minga.UI.Theme.color(),
            header_bg: Minga.UI.Theme.color(),
            separator_fg: Minga.UI.Theme.color(),
            modified_fg: Minga.UI.Theme.color() | nil,
            git_modified_fg: Minga.UI.Theme.color() | nil,
            git_staged_fg: Minga.UI.Theme.color() | nil,
            git_untracked_fg: Minga.UI.Theme.color() | nil,
            git_conflict_fg: Minga.UI.Theme.color() | nil
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

  @doc """
  Returns the theme struct for the given name atom.

  Checks user-defined themes first, then built-in themes.
  """
  @spec get(atom()) :: {:ok, t()} | :error
  def get(name) when is_atom(name) do
    case get_user_theme(name) do
      {:ok, _} = result -> result
      :error -> get_builtin(name)
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

  @doc """
  Returns all available theme name atoms (built-in + user-defined).
  """
  @spec available() :: [atom()]
  def available do
    builtin = Map.keys(@themes)
    user = Map.keys(user_themes())
    Enum.uniq(builtin ++ user) |> Enum.sort()
  end

  @doc "Returns the default theme name atom."
  @spec default() :: atom()
  def default, do: :doom_one

  @doc """
  Registers user-defined themes loaded from disk.

  Called by the theme loader at startup and on reload. Stores themes
  in `:persistent_term` for fast reads on the render path.
  """
  @spec register_user_themes(%{atom() => Minga.UI.Theme.Loader.loaded_theme()}) :: :ok
  def register_user_themes(themes) when is_map(themes) do
    :persistent_term.put({__MODULE__, :user_themes}, themes)
    :ok
  end

  @doc "Returns the map of registered user themes."
  @spec user_themes() :: %{atom() => Minga.UI.Theme.Loader.loaded_theme()}
  def user_themes do
    :persistent_term.get({__MODULE__, :user_themes}, %{})
  end

  # ── Private: theme lookup helpers ──

  @spec get_builtin(atom()) :: {:ok, t()} | :error
  defp get_builtin(name) do
    case Map.get(@themes, name) do
      nil -> :error
      module -> {:ok, module.theme()}
    end
  end

  @spec get_user_theme(atom()) :: {:ok, t()} | :error
  defp get_user_theme(name) do
    case Map.get(user_themes(), name) do
      nil -> :error
      loaded -> {:ok, loaded.theme}
    end
  end

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
      dashboard_label: 0x61AFEF,
      delimiter_dim: 0x3E4452,
      link_fg: 0x61AFEF
    }
  end

  def agent_theme(%__MODULE__{agent: agent}), do: agent

  @doc """
  Returns a syntax theme map customized for the agent chat buffer.

  Overrides delimiter and punctuation captures to use the agent theme's
  `delimiter_dim` color, so tree-sitter naturally dims markdown syntax
  characters (`**`, `*`, `` ` ``, `#`, ` ``` `, brackets, list markers).
  Link text uses `link_fg` and URLs use `delimiter_dim`.

  The base syntax map comes from the editor's global theme; only the
  agent-specific overrides are merged on top.
  """
  @spec agent_syntax(t()) :: syntax()
  def agent_syntax(%__MODULE__{syntax: base_syntax} = theme) do
    agent = agent_theme(theme)
    dim = agent.delimiter_dim

    Map.merge(base_syntax, %{
      # Markdown delimiters: **, *, `, ```, brackets in links
      "punctuation.delimiter" => [fg: dim],
      # Heading markers (#), list markers (-, *, +, 1.)
      "punctuation.special" => [fg: dim],
      # Link text and URLs (markup.* standard names)
      "markup.link.label" => [fg: agent.link_fg],
      "markup.link.url" => [fg: dim],
      "markup.link" => [fg: dim],
      # Per-level heading colors (markup.heading.* from nvim-treesitter)
      "markup.heading" => [fg: agent.heading1_fg, bold: true],
      "markup.heading.1" => [fg: agent.heading1_fg, bold: true],
      "markup.heading.2" => [fg: agent.heading2_fg, bold: true],
      "markup.heading.3" => [fg: agent.heading3_fg, bold: true],
      "markup.heading.4" => [fg: agent.heading3_fg],
      "markup.heading.5" => [fg: agent.heading3_fg],
      "markup.heading.6" => [fg: agent.heading3_fg]
    })
  end

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

      iex> theme = Minga.UI.Theme.get!(:doom_one)
      iex> style = Minga.UI.Theme.style_for_capture(theme, "keyword")
      iex> Keyword.get(style, :bold)
      true

      iex> theme = Minga.UI.Theme.get!(:doom_one)
      iex> Minga.UI.Theme.style_for_capture(theme, "nonexistent")
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
