defmodule MingaEditor.UI.Theme do
  @moduledoc """
  Unified color theme for the entire editor.

  A theme holds every color the UI needs, organized into semantic groups:
  syntax highlighting, editor chrome, modeline, gutter, search highlights, and popups.

  Built-in themes are shipped as bundled theme pack extensions under `Minga.Extensions.ThemePacks`. The core retains a single minimal theme (`:minga_default`) for tests and explicit use, but startup does not silently fall back to it when the configured theme is unavailable.

  ## Usage in config

      use Minga.Config
      set :theme, :catppuccin_mocha
  """

  alias Minga.Core.Face
  alias MingaEditor.UI.Theme.Fallback
  alias MingaEditor.UI.Theme.Loader.LoadedTheme

  @enforce_keys [
    :name,
    :syntax,
    :editor,
    :gutter,
    :modeline,
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
    :search,
    :popup,
    :tree,
    :hl_todo,
    :agent,
    :tab_bar,
    :dashboard,
    :icon
  ]

  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | {:extension, atom()}

  @type register_error ::
          {:duplicate_name, atom(), existing_source :: contribution_source(),
           attempted_source :: contribution_source()}

  @typedoc "RGB color as a non-negative integer (e.g., `0xFF6C6B`)."
  @type color :: non_neg_integer()

  @typedoc "A style keyword list compatible with `MingaEditor.Frontend.Protocol.style()`."
  @type style :: keyword()

  @typedoc "Syntax theme: tree-sitter capture name → style."
  @type syntax :: %{String.t() => style()}

  @typedoc """
  Optional per-filetype icon color overrides, keyed by filetype atom (e.g. `:rust`)
  with a special `:directory` key for folder icons. Unset filetypes fall back to the
  language's default `icon_color`. `nil`/empty means \"use defaults everywhere\".
  """
  @type icon_overrides :: %{atom() => color()}

  @type t :: %__MODULE__{
          name: atom(),
          syntax: syntax(),
          editor: MingaEditor.UI.Theme.Editor.t(),
          gutter: MingaEditor.UI.Theme.Gutter.t(),
          git: MingaEditor.UI.Theme.Git.t(),
          modeline: MingaEditor.UI.Theme.Modeline.t(),
          search: MingaEditor.UI.Theme.Search.t(),
          popup: MingaEditor.UI.Theme.Popup.t(),
          tree: MingaEditor.UI.Theme.Tree.t(),
          hl_todo: %{atom() => Face.t()} | nil,
          agent: MingaEditor.UI.Theme.Agent.t() | nil,
          tab_bar: MingaEditor.UI.Theme.TabBar.t() | nil,
          dashboard: MingaEditor.UI.Theme.Dashboard.t() | nil,
          icon: icon_overrides() | nil
        }

  # ── Color group structs ─────────────────────────────────────────────────────

  defmodule Editor do
    @moduledoc "Editor chrome colors: background, foreground, split borders, cursorline, nav-flash, highlight/selection."
    @enforce_keys [:bg, :fg, :split_border_fg]
    defstruct [
      :bg,
      :fg,
      :split_border_fg,
      :cursorline_bg,
      :nav_flash_bg,
      :yank_flash_bg,
      :highlight_read_bg,
      :highlight_write_bg,
      :selection_bg,
      :whitespace_fg,
      :indent_guide_fg,
      :indent_guide_active_fg,
      :link_fg
    ]

    @type t :: %__MODULE__{
            bg: MingaEditor.UI.Theme.color(),
            fg: MingaEditor.UI.Theme.color(),
            split_border_fg: MingaEditor.UI.Theme.color(),
            cursorline_bg: MingaEditor.UI.Theme.color() | nil,
            nav_flash_bg: MingaEditor.UI.Theme.color() | nil,
            yank_flash_bg: MingaEditor.UI.Theme.color() | nil,
            highlight_read_bg: MingaEditor.UI.Theme.color() | nil,
            highlight_write_bg: MingaEditor.UI.Theme.color() | nil,
            selection_bg: MingaEditor.UI.Theme.color() | nil,
            whitespace_fg: MingaEditor.UI.Theme.color() | nil,
            indent_guide_fg: MingaEditor.UI.Theme.color() | nil,
            indent_guide_active_fg: MingaEditor.UI.Theme.color() | nil,
            link_fg: MingaEditor.UI.Theme.color() | nil
          }
  end

  defmodule Gutter do
    @moduledoc "Gutter (line number column) colors."
    @enforce_keys [:fg, :current_fg, :error_fg, :warning_fg, :info_fg, :hint_fg, :fold_fg]
    defstruct [
      :fg,
      :current_fg,
      :error_fg,
      :warning_fg,
      :info_fg,
      :hint_fg,
      :fold_fg,
      :separator_fg,
      # Advisory (extension-sourced) diagnostic sign color. Optional override:
      # when nil, the renderer derives it from this theme's own warning/error
      # colors so the amber suits each theme instead of a baked constant.
      :advisory_fg
    ]

    @type t :: %__MODULE__{
            fg: MingaEditor.UI.Theme.color(),
            current_fg: MingaEditor.UI.Theme.color(),
            error_fg: MingaEditor.UI.Theme.color(),
            warning_fg: MingaEditor.UI.Theme.color(),
            info_fg: MingaEditor.UI.Theme.color(),
            hint_fg: MingaEditor.UI.Theme.color(),
            fold_fg: MingaEditor.UI.Theme.color(),
            separator_fg: MingaEditor.UI.Theme.color() | nil,
            advisory_fg: MingaEditor.UI.Theme.color() | nil
          }
  end

  defmodule Git do
    @moduledoc "Git gutter indicator colors."
    @enforce_keys [:added_fg, :modified_fg, :deleted_fg]
    defstruct [:added_fg, :modified_fg, :deleted_fg]

    @type t :: %__MODULE__{
            added_fg: MingaEditor.UI.Theme.color(),
            modified_fg: MingaEditor.UI.Theme.color(),
            deleted_fg: MingaEditor.UI.Theme.color()
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
            bar_fg: MingaEditor.UI.Theme.color(),
            bar_bg: MingaEditor.UI.Theme.color(),
            info_fg: MingaEditor.UI.Theme.color(),
            info_bg: MingaEditor.UI.Theme.color(),
            filetype_fg: MingaEditor.UI.Theme.color(),
            mode_colors: %{
              atom() => {fg :: MingaEditor.UI.Theme.color(), bg :: MingaEditor.UI.Theme.color()}
            },
            lsp_ready: MingaEditor.UI.Theme.color() | nil,
            lsp_initializing: MingaEditor.UI.Theme.color() | nil,
            lsp_starting: MingaEditor.UI.Theme.color() | nil,
            lsp_error: MingaEditor.UI.Theme.color() | nil
          }
  end

  defmodule Search do
    @moduledoc "Search highlight colors."
    @enforce_keys [:highlight_fg, :highlight_bg, :current_bg]
    defstruct [:highlight_fg, :highlight_bg, :current_bg]

    @type t :: %__MODULE__{
            highlight_fg: MingaEditor.UI.Theme.color(),
            highlight_bg: MingaEditor.UI.Theme.color(),
            current_bg: MingaEditor.UI.Theme.color()
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
            fg: MingaEditor.UI.Theme.color(),
            bg: MingaEditor.UI.Theme.color(),
            border_fg: MingaEditor.UI.Theme.color(),
            sel_fg: MingaEditor.UI.Theme.color() | nil,
            sel_bg: MingaEditor.UI.Theme.color() | nil,
            title_fg: MingaEditor.UI.Theme.color() | nil,
            key_fg: MingaEditor.UI.Theme.color() | nil,
            separator_fg: MingaEditor.UI.Theme.color() | nil,
            group_fg: MingaEditor.UI.Theme.color() | nil
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
            active_fg: MingaEditor.UI.Theme.color(),
            active_bg: MingaEditor.UI.Theme.color(),
            inactive_fg: MingaEditor.UI.Theme.color(),
            inactive_bg: MingaEditor.UI.Theme.color(),
            separator_fg: MingaEditor.UI.Theme.color(),
            modified_fg: MingaEditor.UI.Theme.color(),
            attention_fg: MingaEditor.UI.Theme.color(),
            close_hover_fg: MingaEditor.UI.Theme.color(),
            bg: MingaEditor.UI.Theme.color()
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
            panel_bg: MingaEditor.UI.Theme.color(),
            panel_border: MingaEditor.UI.Theme.color(),
            header_fg: MingaEditor.UI.Theme.color(),
            header_bg: MingaEditor.UI.Theme.color(),
            user_border: MingaEditor.UI.Theme.color(),
            user_label: MingaEditor.UI.Theme.color(),
            assistant_border: MingaEditor.UI.Theme.color(),
            assistant_label: MingaEditor.UI.Theme.color(),
            tool_border: MingaEditor.UI.Theme.color(),
            tool_header: MingaEditor.UI.Theme.color(),
            code_bg: MingaEditor.UI.Theme.color(),
            code_border: MingaEditor.UI.Theme.color(),
            input_border: MingaEditor.UI.Theme.color(),
            input_bg: MingaEditor.UI.Theme.color(),
            input_placeholder: MingaEditor.UI.Theme.color(),
            thinking_fg: MingaEditor.UI.Theme.color(),
            status_thinking: MingaEditor.UI.Theme.color(),
            status_tool: MingaEditor.UI.Theme.color(),
            status_error: MingaEditor.UI.Theme.color(),
            status_idle: MingaEditor.UI.Theme.color(),
            text_fg: MingaEditor.UI.Theme.color(),
            context_low: MingaEditor.UI.Theme.color(),
            context_mid: MingaEditor.UI.Theme.color(),
            context_high: MingaEditor.UI.Theme.color(),
            usage_fg: MingaEditor.UI.Theme.color(),
            toast_bg: MingaEditor.UI.Theme.color(),
            toast_fg: MingaEditor.UI.Theme.color(),
            toast_border: MingaEditor.UI.Theme.color(),
            system_fg: MingaEditor.UI.Theme.color(),
            search_match_bg: MingaEditor.UI.Theme.color(),
            search_current_bg: MingaEditor.UI.Theme.color(),
            heading1_fg: MingaEditor.UI.Theme.color(),
            heading2_fg: MingaEditor.UI.Theme.color(),
            heading3_fg: MingaEditor.UI.Theme.color(),
            hint_fg: MingaEditor.UI.Theme.color(),
            dashboard_label: MingaEditor.UI.Theme.color(),
            delimiter_dim: MingaEditor.UI.Theme.color(),
            link_fg: MingaEditor.UI.Theme.color()
          }
  end

  defmodule Dashboard do
    @moduledoc "Dashboard (home screen) colors."
    @enforce_keys [:bg, :logo_fg, :heading_fg, :item_fg, :item_active_bg, :shortcut_fg, :muted_fg]
    defstruct [:bg, :logo_fg, :heading_fg, :item_fg, :item_active_bg, :shortcut_fg, :muted_fg]

    @type t :: %__MODULE__{
            bg: MingaEditor.UI.Theme.color(),
            logo_fg: MingaEditor.UI.Theme.color(),
            heading_fg: MingaEditor.UI.Theme.color(),
            item_fg: MingaEditor.UI.Theme.color(),
            item_active_bg: MingaEditor.UI.Theme.color(),
            shortcut_fg: MingaEditor.UI.Theme.color(),
            muted_fg: MingaEditor.UI.Theme.color()
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
      :git_modified_fg,
      :git_staged_fg,
      :git_untracked_fg
    ]

    @type t :: %__MODULE__{
            bg: MingaEditor.UI.Theme.color(),
            fg: MingaEditor.UI.Theme.color(),
            dir_fg: MingaEditor.UI.Theme.color(),
            active_fg: MingaEditor.UI.Theme.color(),
            cursor_bg: MingaEditor.UI.Theme.color(),
            header_fg: MingaEditor.UI.Theme.color(),
            header_bg: MingaEditor.UI.Theme.color(),
            separator_fg: MingaEditor.UI.Theme.color(),
            git_modified_fg: MingaEditor.UI.Theme.color() | nil,
            git_staged_fg: MingaEditor.UI.Theme.color() | nil,
            git_untracked_fg: MingaEditor.UI.Theme.color() | nil
          }
  end

  # ── Theme registry ──────────────────────────────────────────────────────────

  @doc """
  Returns the theme struct for the given name atom.

  Checks registered themes (extension packs + user themes) first, then the core fallback.
  """
  @spec get(atom()) :: {:ok, t()} | :error
  def get(name) when is_atom(name) do
    case get_registered_theme(name) do
      {:ok, _} = result -> result
      :error -> get_fallback(name)
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
  Returns all available theme name atoms (fallback + packs + user-defined).
  """
  @spec available() :: [atom()]
  def available do
    Minga.Config.ThemeRegistry.available()
  end

  @doc "Returns the configured default theme name atom. Startup fails if this theme is unavailable."
  @spec default() :: atom()
  def default, do: :astrodark

  # Folder icons have no language definition; this is their default tint when a
  # theme does not override the `:directory` key.
  @folder_icon_color 0x519ABA

  @doc """
  Resolves the icon color for a filetype, preferring the theme's `:icon` overrides
  over the language's default `icon_color`. The special `:directory` key colors
  folder icons. Themes without overrides fall back to language/folder defaults.
  """
  @spec icon_color(t(), atom()) :: color()
  def icon_color(%__MODULE__{icon: overrides}, filetype) do
    case overrides && Map.get(overrides, filetype) do
      color when is_integer(color) and color >= 0 -> color
      _ -> default_icon_color(filetype)
    end
  end

  @doc """
  The theme-independent default icon color for a filetype (or `:directory`), used
  when no theme override applies. Equivalent to `icon_color/2` against a theme with
  no `:icon` overrides.
  """
  @spec default_icon_color(atom()) :: color()
  def default_icon_color(:directory), do: @folder_icon_color
  def default_icon_color(filetype), do: Minga.Language.Devicon.color(filetype)

  @doc """
  Registers user-defined themes loaded from disk.

  Called by the theme loader at startup and on reload. Stores themes
  in `:persistent_term` for fast reads on the render path.
  """
  @spec register_user_themes(%{atom() => MingaEditor.UI.Theme.Loader.loaded_theme()}) ::
          :ok | {:error, register_error()}
  def register_user_themes(themes) when is_map(themes) do
    register_themes(themes, :config)
  end

  @doc "Registers themes with explicit source ownership. Wraps raw theme structs in LoadedTheme."
  @spec register_themes(
          %{atom() => t() | MingaEditor.UI.Theme.Loader.loaded_theme()},
          contribution_source()
        ) :: :ok | {:error, register_error()}
  def register_themes(themes, source) when is_map(themes) do
    normalized =
      Map.new(themes, fn {name, data} -> {name, normalize_loaded_theme(name, data)} end)

    Minga.Config.ThemeRegistry.register_themes(normalized, source)
  end

  @doc "Removes every theme contributed by a source while keeping the core fallback available."
  @spec unregister_source(contribution_source()) :: :ok
  def unregister_source(source), do: Minga.Config.ThemeRegistry.unregister_source(source)

  @doc "Returns the map of registered themes."
  @spec user_themes() :: %{atom() => MingaEditor.UI.Theme.Loader.loaded_theme()}
  def user_themes do
    Minga.Config.ThemeRegistry.stored_themes()
  end

  @doc "Returns theme source ownership metadata."
  @spec user_theme_sources() :: %{atom() => contribution_source()}
  def user_theme_sources do
    Minga.Config.ThemeRegistry.stored_sources()
  end

  # ── Private: theme lookup helpers ──

  @spec normalize_loaded_theme(atom(), t() | MingaEditor.UI.Theme.Loader.loaded_theme()) ::
          MingaEditor.UI.Theme.Loader.loaded_theme()
  defp normalize_loaded_theme(_name, %LoadedTheme{} = loaded), do: loaded

  defp normalize_loaded_theme(name, %__MODULE__{} = theme) do
    %LoadedTheme{name: name, theme: theme, face_registry: %{}, source_path: "<runtime>"}
  end

  @spec get_fallback(atom()) :: {:ok, t()} | :error
  defp get_fallback(:minga_default), do: {:ok, Fallback.theme()}
  defp get_fallback(_name), do: :error

  @spec get_registered_theme(atom()) :: {:ok, t()} | :error
  defp get_registered_theme(name) do
    case Minga.Config.ThemeRegistry.get_theme(name) do
      {:ok, %LoadedTheme{theme: theme}} -> {:ok, theme}
      {:ok, %__MODULE__{} = theme} -> {:ok, theme}
      :error -> :error
    end
  end

  @doc "Returns the TODO keyword faces, falling back to Doom One-compatible defaults."
  @spec hl_todo_faces(t()) :: %{atom() => Face.t()}
  def hl_todo_faces(%__MODULE__{hl_todo: faces}) when is_map(faces), do: faces

  def hl_todo_faces(%__MODULE__{}) do
    %{
      todo: Face.new(fg: 0xECBE7B, bold: true),
      fixme: Face.new(fg: 0xFF6C6B, bold: true),
      note: Face.new(fg: 0x51AFEF, bold: true),
      hack: Face.new(fg: 0xDA8548, bold: true),
      review: Face.new(fg: 0xC678DD, bold: true),
      deprecated: Face.new(fg: 0x5B6268, strikethrough: true)
    }
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

      iex> theme = MingaEditor.UI.Theme.get!(:doom_one)
      iex> style = MingaEditor.UI.Theme.style_for_capture(theme, "keyword")
      iex> Keyword.get(style, :bold)
      true

      iex> theme = MingaEditor.UI.Theme.get!(:doom_one)
      iex> MingaEditor.UI.Theme.style_for_capture(theme, "nonexistent")
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
