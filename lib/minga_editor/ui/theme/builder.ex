defmodule MingaEditor.UI.Theme.Builder do
  @moduledoc """
  Builds complete themes from semantic palettes.

  The builder is a construction-time cascade: it expands a small `Theme.Palette` into the fully populated `Theme.t()` that renderer and UI code already consume. Consumers still read concrete theme fields directly; only theme authors get a smaller authoring surface.
  """

  alias Minga.Core.Face
  alias MingaEditor.UI.Theme
  alias MingaEditor.UI.Theme.Palette

  @type section_overrides :: %{optional(atom()) => term()}
  @type overrides :: %{
          optional(:syntax) => Theme.syntax(),
          optional(:hl_todo) => %{atom() => Face.t()},
          optional(:editor) => section_overrides(),
          optional(:gutter) => section_overrides(),
          optional(:git) => section_overrides(),
          optional(:modeline) => section_overrides(),
          optional(:picker) => section_overrides(),
          optional(:minibuffer) => section_overrides(),
          optional(:search) => section_overrides(),
          optional(:popup) => section_overrides(),
          optional(:tree) => section_overrides(),
          optional(:agent) => section_overrides(),
          optional(:tab_bar) => section_overrides(),
          optional(:dashboard) => section_overrides()
        }

  @theme_sections %{
    editor: Theme.Editor,
    gutter: Theme.Gutter,
    git: Theme.Git,
    modeline: Theme.Modeline,
    picker: Theme.Picker,
    minibuffer: Theme.Minibuffer,
    search: Theme.Search,
    popup: Theme.Popup,
    tree: Theme.Tree,
    agent: Theme.Agent,
    tab_bar: Theme.TabBar,
    dashboard: Theme.Dashboard
  }

  @color_fields %{
    editor: [
      :bg,
      :fg,
      :tilde_fg,
      :split_border_fg,
      :cursorline_bg,
      :nav_flash_bg,
      :yank_flash_bg,
      :highlight_read_bg,
      :highlight_write_bg,
      :selection_bg,
      :whitespace_fg,
      :indent_guide_fg,
      :indent_guide_active_fg
    ],
    gutter: [
      :fg,
      :current_fg,
      :error_fg,
      :warning_fg,
      :info_fg,
      :hint_fg,
      :fold_fg,
      :separator_fg
    ],
    git: [:added_fg, :modified_fg, :deleted_fg],
    modeline: [
      :bar_fg,
      :bar_bg,
      :info_fg,
      :info_bg,
      :filetype_fg,
      :lsp_ready,
      :lsp_initializing,
      :lsp_starting,
      :lsp_error
    ],
    picker: [
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
    ],
    minibuffer: [:fg, :bg, :warning_fg, :dim_fg],
    search: [:highlight_fg, :highlight_bg, :current_bg],
    popup: [
      :fg,
      :bg,
      :border_fg,
      :sel_fg,
      :sel_bg,
      :title_fg,
      :key_fg,
      :separator_fg,
      :group_fg
    ],
    tree: [
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
    ],
    agent: [
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
    ],
    tab_bar: [
      :active_fg,
      :active_bg,
      :inactive_fg,
      :inactive_bg,
      :separator_fg,
      :modified_fg,
      :attention_fg,
      :close_hover_fg,
      :bg
    ],
    dashboard: [
      :bg,
      :logo_fg,
      :heading_fg,
      :item_fg,
      :item_active_bg,
      :shortcut_fg,
      :muted_fg
    ]
  }

  @doc "Builds a complete theme from a semantic palette."
  @spec from_palette(atom(), Palette.t() | map(), overrides()) :: Theme.t()
  def from_palette(name, palette, overrides \\ %{}) when is_atom(name) and is_map(overrides) do
    palette = Palette.from_map(palette)

    %Theme{
      name: name,
      syntax: syntax(palette),
      hl_todo: hl_todo(palette),
      editor: editor(palette),
      gutter: gutter(palette),
      git: git(palette),
      modeline: modeline(palette),
      picker: picker(palette),
      minibuffer: minibuffer(palette),
      search: search(palette),
      popup: popup(palette),
      tree: tree(palette),
      agent: agent(palette),
      dashboard: dashboard(palette),
      tab_bar: tab_bar(palette)
    }
    |> apply_overrides(overrides)
  end

  @spec editor(Palette.t()) :: Theme.Editor.t()
  defp editor(%Palette{} = p) do
    %Theme.Editor{
      bg: p.base.bg,
      fg: p.base.fg,
      tilde_fg: p.base.subtle,
      split_border_fg: p.semantic.border,
      cursorline_bg: p.base.surface,
      nav_flash_bg: p.base.subtle,
      yank_flash_bg: p.base.subtle,
      highlight_read_bg: p.base.subtle,
      highlight_write_bg: p.semantic.selection_bg,
      selection_bg: p.semantic.selection_bg,
      whitespace_fg: p.base.muted,
      indent_guide_fg: p.base.subtle,
      indent_guide_active_fg: p.base.muted
    }
  end

  @spec gutter(Palette.t()) :: Theme.Gutter.t()
  defp gutter(%Palette{} = p) do
    %Theme.Gutter{
      fg: p.base.muted,
      current_fg: p.base.fg,
      error_fg: p.semantic.error,
      warning_fg: p.semantic.warning,
      info_fg: p.semantic.info,
      hint_fg: p.base.muted,
      fold_fg: p.base.muted,
      separator_fg: p.semantic.border
    }
  end

  @spec git(Palette.t()) :: Theme.Git.t()
  defp git(%Palette{} = p) do
    %Theme.Git{
      added_fg: p.semantic.success,
      modified_fg: p.semantic.warning,
      deleted_fg: p.semantic.error
    }
  end

  @spec modeline(Palette.t()) :: Theme.Modeline.t()
  defp modeline(%Palette{} = p) do
    %Theme.Modeline{
      bar_fg: p.base.fg,
      bar_bg: p.base.overlay,
      info_fg: p.base.fg,
      info_bg: p.semantic.border,
      filetype_fg: p.semantic.success,
      mode_colors: default_mode_colors(p),
      lsp_ready: p.semantic.success,
      lsp_initializing: p.semantic.warning,
      lsp_starting: p.base.muted,
      lsp_error: p.semantic.error
    }
  end

  @spec default_mode_colors(Palette.t()) :: %{
          atom() => {Theme.color(), Theme.color()}
        }
  defp default_mode_colors(%Palette{} = p) do
    %{
      normal: {p.semantic.contrast_fg, p.semantic.highlight},
      insert: {p.semantic.contrast_fg, p.semantic.success},
      visual: {p.semantic.contrast_fg, p.syntax.functions},
      operator_pending: {p.semantic.contrast_fg, p.semantic.warning},
      command: {p.semantic.contrast_fg, p.semantic.warning},
      replace: {p.semantic.contrast_fg, p.semantic.error},
      search: {p.semantic.contrast_fg, p.semantic.info}
    }
  end

  @spec picker(Palette.t()) :: Theme.Picker.t()
  defp picker(%Palette{} = p) do
    %Theme.Picker{
      bg: p.base.surface,
      sel_bg: p.semantic.selection_bg,
      prompt_bg: p.base.surface,
      dim_fg: p.base.muted,
      text_fg: p.base.fg,
      highlight_fg: p.semantic.highlight,
      match_fg: p.semantic.match,
      border_fg: p.semantic.border,
      menu_bg: p.base.bg,
      menu_fg: p.base.fg,
      menu_sel_bg: p.semantic.selection_bg,
      menu_sel_fg: p.semantic.highlight
    }
  end

  @spec minibuffer(Palette.t()) :: Theme.Minibuffer.t()
  defp minibuffer(%Palette{} = p) do
    %Theme.Minibuffer{
      fg: p.base.fg,
      bg: p.base.overlay,
      warning_fg: p.semantic.warning,
      dim_fg: p.base.muted
    }
  end

  @spec search(Palette.t()) :: Theme.Search.t()
  defp search(%Palette{} = p) do
    %Theme.Search{
      highlight_fg: p.semantic.contrast_fg,
      highlight_bg: p.semantic.match,
      current_bg: p.semantic.error
    }
  end

  @spec popup(Palette.t()) :: Theme.Popup.t()
  defp popup(%Palette{} = p) do
    %Theme.Popup{
      fg: p.base.fg,
      bg: p.base.surface,
      border_fg: p.semantic.border,
      sel_fg: p.semantic.contrast_fg,
      sel_bg: p.semantic.selection_bg,
      title_fg: p.semantic.highlight,
      key_fg: p.semantic.info,
      separator_fg: p.semantic.border,
      group_fg: p.semantic.highlight
    }
  end

  @spec tree(Palette.t()) :: Theme.Tree.t()
  defp tree(%Palette{} = p) do
    %Theme.Tree{
      bg: p.base.surface,
      fg: p.base.fg,
      dir_fg: p.semantic.info,
      active_fg: p.semantic.success,
      cursor_bg: p.semantic.selection_bg,
      header_fg: p.semantic.highlight,
      header_bg: p.base.surface,
      separator_fg: p.semantic.border,
      modified_fg: p.semantic.warning,
      git_modified_fg: p.semantic.warning,
      git_staged_fg: p.semantic.success,
      git_untracked_fg: p.base.muted,
      git_conflict_fg: p.semantic.error
    }
  end

  @spec agent(Palette.t()) :: Theme.Agent.t()
  defp agent(%Palette{} = p) do
    %Theme.Agent{
      panel_bg: p.base.bg,
      panel_border: p.semantic.border,
      header_fg: p.semantic.highlight,
      header_bg: p.base.surface,
      user_border: p.semantic.highlight,
      user_label: p.semantic.highlight,
      assistant_border: p.semantic.success,
      assistant_label: p.semantic.success,
      tool_border: p.semantic.warning,
      tool_header: p.semantic.warning,
      code_bg: p.base.surface,
      code_border: p.semantic.border,
      input_border: p.semantic.highlight,
      input_bg: p.base.bg,
      input_placeholder: p.base.muted,
      thinking_fg: p.semantic.warning,
      status_thinking: p.semantic.warning,
      status_tool: p.semantic.info,
      status_error: p.semantic.error,
      status_idle: p.base.muted,
      text_fg: p.base.fg,
      context_low: p.semantic.success,
      context_mid: p.semantic.warning,
      context_high: p.semantic.error,
      usage_fg: p.base.muted,
      toast_bg: p.base.surface,
      toast_fg: p.base.fg,
      toast_border: p.semantic.border,
      system_fg: p.base.muted,
      search_match_bg: p.semantic.match,
      search_current_bg: p.semantic.error,
      heading1_fg: p.syntax.keywords,
      heading2_fg: p.syntax.functions,
      heading3_fg: p.semantic.success,
      hint_fg: p.base.muted,
      dashboard_label: p.semantic.highlight,
      delimiter_dim: p.base.subtle,
      link_fg: p.semantic.link
    }
  end

  @spec dashboard(Palette.t()) :: Theme.Dashboard.t()
  defp dashboard(%Palette{} = p) do
    %Theme.Dashboard{
      bg: p.base.bg,
      logo_fg: p.semantic.warning,
      heading_fg: p.semantic.highlight,
      item_fg: p.base.fg,
      item_active_bg: p.base.surface,
      shortcut_fg: p.semantic.success,
      muted_fg: p.base.muted
    }
  end

  @spec tab_bar(Palette.t()) :: Theme.TabBar.t()
  defp tab_bar(%Palette{} = p) do
    %Theme.TabBar{
      active_fg: p.base.fg,
      active_bg: p.base.bg,
      inactive_fg: p.base.muted,
      inactive_bg: p.base.surface,
      separator_fg: p.semantic.border,
      modified_fg: p.semantic.warning,
      attention_fg: p.semantic.error,
      close_hover_fg: p.semantic.error,
      bg: p.base.surface
    }
  end

  @spec hl_todo(Palette.t()) :: %{atom() => Face.t()}
  defp hl_todo(%Palette{} = p) do
    %{
      todo: Face.new(fg: p.semantic.warning, bold: true),
      fixme: Face.new(fg: p.semantic.error, bold: true),
      note: Face.new(fg: p.semantic.info, bold: true),
      hack: Face.new(fg: p.syntax.constants, bold: true),
      review: Face.new(fg: p.syntax.keywords, bold: true),
      deprecated: Face.new(fg: p.base.muted, strikethrough: true)
    }
  end

  @spec syntax(Palette.t()) :: Theme.syntax()
  defp syntax(%Palette{} = p) do
    %{
      "keyword" => [fg: p.syntax.keywords, bold: true],
      "keyword.function" => [fg: p.syntax.keywords, bold: true],
      "keyword.operator" => [fg: p.syntax.operators],
      "keyword.return" => [fg: p.syntax.keywords, bold: true],
      "keyword.conditional" => [fg: p.syntax.keywords, bold: true],
      "keyword.coroutine" => [fg: p.syntax.keywords, bold: true],
      "keyword.directive" => [fg: p.syntax.keywords],
      "keyword.exception" => [fg: p.syntax.keywords],
      "keyword.import" => [fg: p.syntax.keywords],
      "keyword.modifier" => [fg: p.syntax.keywords, bold: true],
      "keyword.repeat" => [fg: p.syntax.keywords, bold: true],
      "keyword.type" => [fg: p.syntax.keywords, bold: true],
      "conditional" => [fg: p.syntax.keywords, bold: true],
      "exception" => [fg: p.syntax.keywords],
      "include" => [fg: p.syntax.keywords],
      "import" => [fg: p.syntax.keywords],
      "repeat" => [fg: p.syntax.keywords, bold: true],
      "string" => [fg: p.syntax.strings],
      "string.special" => [fg: p.syntax.constants],
      "string.special.symbol" => [fg: p.syntax.builtin],
      "string.special.key" => [fg: p.syntax.functions],
      "string.special.regex" => [fg: p.syntax.constants],
      "string.escape" => [fg: p.syntax.operators],
      "string.regex" => [fg: p.syntax.constants],
      "character" => [fg: p.syntax.builtin],
      "comment" => [fg: p.syntax.comments, italic: true],
      "comment.doc" => [fg: p.syntax.comments, italic: true],
      "comment.documentation" => [fg: p.syntax.comments, italic: true],
      "comment.unused" => [fg: p.syntax.comments, italic: true],
      "comment.discard" => [fg: p.syntax.comments, italic: true],
      "function" => [fg: p.syntax.functions],
      "function.call" => [fg: p.syntax.functions],
      "function.builtin" => [fg: p.syntax.builtin],
      "function.macro" => [fg: p.syntax.keywords, bold: true],
      "function.method" => [fg: p.syntax.methods],
      "function.method.builtin" => [fg: p.syntax.builtin],
      "function.special" => [fg: p.syntax.keywords],
      "method" => [fg: p.syntax.methods],
      "method.call" => [fg: p.syntax.methods],
      "type" => [fg: p.syntax.type],
      "type.builtin" => [fg: p.syntax.type, bold: true],
      "variable" => [fg: p.syntax.variables],
      "variable.builtin" => [fg: p.semantic.error],
      "variable.parameter" => [fg: p.syntax.variables],
      "variable.member" => [fg: p.syntax.builtin],
      "parameter" => [fg: p.syntax.variables],
      "field" => [fg: p.syntax.builtin],
      "constant" => [fg: p.syntax.constants],
      "constant.builtin" => [fg: p.syntax.constants, bold: true],
      "boolean" => [fg: p.syntax.constants, bold: true],
      "number" => [fg: p.syntax.numbers],
      "number.float" => [fg: p.syntax.numbers],
      "float" => [fg: p.syntax.numbers],
      "operator" => [fg: p.syntax.operators],
      "punctuation" => [fg: p.base.muted],
      "punctuation.bracket" => [fg: p.base.muted],
      "punctuation.delimiter" => [fg: p.base.muted],
      "punctuation.special" => [fg: p.syntax.operators],
      "delimiter" => [fg: p.base.muted],
      "module" => [fg: p.syntax.type],
      "namespace" => [fg: p.syntax.type],
      "attribute" => [fg: p.syntax.builtin],
      "property" => [fg: p.syntax.builtin],
      "label" => [fg: p.semantic.info],
      "tag" => [fg: p.syntax.keywords],
      "tag.attribute" => [fg: p.syntax.type],
      "tag.error" => [fg: p.semantic.error, bold: true],
      "preproc" => [fg: p.syntax.operators, bold: true],
      "markup.heading" => [fg: p.semantic.error, bold: true],
      "markup.heading.1" => [fg: p.semantic.error, bold: true],
      "markup.heading.2" => [fg: p.syntax.constants, bold: true],
      "markup.heading.3" => [fg: p.semantic.warning, bold: true],
      "markup.heading.4" => [fg: p.semantic.success, bold: true],
      "markup.heading.5" => [fg: p.syntax.functions, bold: true],
      "markup.heading.6" => [fg: p.syntax.keywords, bold: true],
      "markup.bold" => [fg: p.syntax.constants, bold: true],
      "markup.strong" => [fg: p.syntax.constants, bold: true],
      "markup.italic" => [fg: p.syntax.variables, italic: true],
      "markup.strikethrough" => [fg: p.base.muted, strikethrough: true],
      "markup.raw" => [fg: p.syntax.strings],
      "markup.raw.block" => [fg: p.syntax.strings],
      "markup.raw.inline" => [fg: p.syntax.strings],
      "markup.link" => [fg: p.semantic.link],
      "markup.link.url" => [fg: p.semantic.link, underline: true],
      "markup.link.label" => [fg: p.syntax.functions],
      "markup.list" => [fg: p.semantic.error],
      "markup.list.numbered" => [fg: p.semantic.error],
      "markup.list.unnumbered" => [fg: p.semantic.error],
      "markup.list.checked" => [fg: p.semantic.success],
      "markup.list.unchecked" => [fg: p.base.muted],
      "markup.quote" => [fg: p.base.muted, italic: true],
      "charset" => [fg: p.syntax.keywords, bold: true],
      "keyframes" => [fg: p.syntax.keywords, bold: true],
      "media" => [fg: p.syntax.keywords, bold: true],
      "supports" => [fg: p.syntax.keywords, bold: true],
      "escape" => [fg: p.syntax.operators],
      "embedded" => [fg: p.syntax.variables],
      "constructor" => [fg: p.semantic.info, bold: true],
      "error" => [fg: p.semantic.error, bold: true],
      "warning" => [fg: p.semantic.warning, bold: true]
    }
  end

  @doc false
  @spec apply_overrides(Theme.t(), overrides()) :: Theme.t()
  def apply_overrides(theme, overrides) when map_size(overrides) == 0, do: theme

  def apply_overrides(%Theme{} = theme, overrides) when is_map(overrides) do
    Enum.reduce(overrides, theme, &apply_override/2)
  end

  @spec apply_override({atom(), term()}, Theme.t()) :: Theme.t()
  defp apply_override({:syntax, overrides}, %Theme{} = theme) when is_map(overrides) do
    %{theme | syntax: Map.merge(theme.syntax, overrides)}
  end

  defp apply_override({:hl_todo, overrides}, %Theme{} = theme) when is_map(overrides) do
    %{theme | hl_todo: Map.merge(theme.hl_todo || %{}, overrides)}
  end

  defp apply_override({section, overrides}, %Theme{} = theme)
       when is_atom(section) and is_map(overrides) do
    case Map.fetch(@theme_sections, section) do
      {:ok, _module} -> apply_section_override(theme, section, overrides)
      :error -> raise ArgumentError, "unknown theme override section: #{inspect(section)}"
    end
  end

  defp apply_override({section, _overrides}, %Theme{}) when is_atom(section) do
    raise ArgumentError, "theme override section #{inspect(section)} must be a map"
  end

  defp apply_override(override, %Theme{}) do
    raise ArgumentError, "theme override keys must be atoms, got: #{inspect(override)}"
  end

  @spec apply_section_override(Theme.t(), atom(), map()) :: Theme.t()
  defp apply_section_override(%Theme{} = theme, section, overrides) do
    current = Map.fetch!(theme, section)
    %{theme | section => merge_struct(section, current, overrides)}
  end

  @spec merge_struct(atom(), struct(), map()) :: struct()
  defp merge_struct(section, struct, overrides) when is_map(overrides) do
    fields = struct |> Map.from_struct() |> Map.keys() |> MapSet.new()

    Enum.reduce(overrides, struct, fn {key, value}, acc ->
      if MapSet.member?(fields, key) do
        %{acc | key => validate_override_value(section, key, Map.get(acc, key), value)}
      else
        raise ArgumentError,
              "unknown theme override field #{inspect(section)}.#{inspect(key)}"
      end
    end)
  end

  @spec validate_override_value(atom(), atom(), term(), term()) :: term()
  defp validate_override_value(section, :mode_colors, current, value)
       when is_map(current) and is_map(value) do
    merge_mode_colors(section, current, value)
  end

  defp validate_override_value(section, :mode_colors, _current, value) do
    raise ArgumentError,
          "theme override #{Atom.to_string(section)}.mode_colors must be a map of {fg, bg} tuples, got: #{inspect(value)}"
  end

  defp validate_override_value(section, field, _current, value) do
    if color_field?(section, field) do
      validate_color_override(section, field, value)
    else
      value
    end
  end

  @spec merge_mode_colors(atom(), map(), map()) :: map()
  defp merge_mode_colors(section, current, overrides) do
    allowed_modes = current |> Map.keys() |> MapSet.new()

    Enum.reduce(overrides, current, fn {mode, value}, acc ->
      if MapSet.member?(allowed_modes, mode) do
        Map.put(acc, mode, validate_mode_color(section, mode, value))
      else
        raise ArgumentError,
              "unknown theme override #{Atom.to_string(section)}.mode_colors key: #{format_key(mode)}"
      end
    end)
  end

  @spec validate_mode_color(atom(), term(), term()) :: {Theme.color(), Theme.color()}
  defp validate_mode_color(_section, _mode, {fg, bg})
       when is_integer(fg) and fg >= 0 and is_integer(bg) and bg >= 0,
       do: {fg, bg}

  defp validate_mode_color(section, mode, value) do
    raise ArgumentError,
          "theme override #{Atom.to_string(section)}.mode_colors.#{format_key(mode)} must be a {fg, bg} color tuple, got: #{inspect(value)}"
  end

  @spec format_key(term()) :: String.t()
  defp format_key(key) when is_atom(key), do: Atom.to_string(key)
  defp format_key(key), do: inspect(key)

  @spec validate_color_override(atom(), atom(), term()) :: Theme.color()
  defp validate_color_override(_section, _field, value) when is_integer(value) and value >= 0,
    do: value

  defp validate_color_override(section, field, value) do
    raise ArgumentError,
          "theme override #{Atom.to_string(section)}.#{Atom.to_string(field)} must be a color, got: #{inspect(value)}"
  end

  @spec color_field?(atom(), atom()) :: boolean()
  defp color_field?(section, field) do
    field in Map.get(@color_fields, section, [])
  end
end
