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
      bg: p.bg,
      fg: p.fg,
      tilde_fg: p.subtle,
      split_border_fg: p.border,
      cursorline_bg: p.surface,
      nav_flash_bg: p.subtle,
      yank_flash_bg: p.subtle,
      highlight_read_bg: p.subtle,
      highlight_write_bg: p.selection_bg,
      selection_bg: p.selection_bg,
      whitespace_fg: p.muted,
      indent_guide_fg: p.subtle,
      indent_guide_active_fg: p.muted
    }
  end

  @spec gutter(Palette.t()) :: Theme.Gutter.t()
  defp gutter(%Palette{} = p) do
    %Theme.Gutter{
      fg: p.muted,
      current_fg: p.fg,
      error_fg: p.error,
      warning_fg: p.warning,
      info_fg: p.info,
      hint_fg: p.muted,
      fold_fg: p.muted,
      separator_fg: p.border
    }
  end

  @spec git(Palette.t()) :: Theme.Git.t()
  defp git(%Palette{} = p) do
    %Theme.Git{added_fg: p.success, modified_fg: p.warning, deleted_fg: p.error}
  end

  @spec modeline(Palette.t()) :: Theme.Modeline.t()
  defp modeline(%Palette{} = p) do
    %Theme.Modeline{
      bar_fg: p.fg,
      bar_bg: p.overlay,
      info_fg: p.fg,
      info_bg: p.border,
      filetype_fg: p.success,
      mode_colors: %{
        normal: {p.contrast_fg, p.highlight},
        insert: {p.contrast_fg, p.success},
        visual: {p.contrast_fg, p.functions},
        operator_pending: {p.contrast_fg, p.warning},
        command: {p.contrast_fg, p.warning},
        replace: {p.contrast_fg, p.error},
        search: {p.contrast_fg, p.info}
      },
      lsp_ready: p.success,
      lsp_initializing: p.warning,
      lsp_starting: p.muted,
      lsp_error: p.error
    }
  end

  @spec picker(Palette.t()) :: Theme.Picker.t()
  defp picker(%Palette{} = p) do
    %Theme.Picker{
      bg: p.surface,
      sel_bg: p.selection_bg,
      prompt_bg: p.surface,
      dim_fg: p.muted,
      text_fg: p.fg,
      highlight_fg: p.highlight,
      match_fg: p.match,
      border_fg: p.border,
      menu_bg: p.bg,
      menu_fg: p.fg,
      menu_sel_bg: p.selection_bg,
      menu_sel_fg: p.highlight
    }
  end

  @spec minibuffer(Palette.t()) :: Theme.Minibuffer.t()
  defp minibuffer(%Palette{} = p) do
    %Theme.Minibuffer{fg: p.fg, bg: p.overlay, warning_fg: p.warning, dim_fg: p.muted}
  end

  @spec search(Palette.t()) :: Theme.Search.t()
  defp search(%Palette{} = p) do
    %Theme.Search{highlight_fg: p.contrast_fg, highlight_bg: p.match, current_bg: p.error}
  end

  @spec popup(Palette.t()) :: Theme.Popup.t()
  defp popup(%Palette{} = p) do
    %Theme.Popup{
      fg: p.fg,
      bg: p.surface,
      border_fg: p.border,
      sel_fg: p.contrast_fg,
      sel_bg: p.selection_bg,
      title_fg: p.highlight,
      key_fg: p.info,
      separator_fg: p.border,
      group_fg: p.highlight
    }
  end

  @spec tree(Palette.t()) :: Theme.Tree.t()
  defp tree(%Palette{} = p) do
    %Theme.Tree{
      bg: p.surface,
      fg: p.fg,
      dir_fg: p.info,
      active_fg: p.success,
      cursor_bg: p.selection_bg,
      header_fg: p.highlight,
      header_bg: p.surface,
      separator_fg: p.border,
      modified_fg: p.warning,
      git_modified_fg: p.warning,
      git_staged_fg: p.success,
      git_untracked_fg: p.muted,
      git_conflict_fg: p.error
    }
  end

  @spec agent(Palette.t()) :: Theme.Agent.t()
  defp agent(%Palette{} = p) do
    %Theme.Agent{
      panel_bg: p.bg,
      panel_border: p.border,
      header_fg: p.highlight,
      header_bg: p.surface,
      user_border: p.highlight,
      user_label: p.highlight,
      assistant_border: p.success,
      assistant_label: p.success,
      tool_border: p.warning,
      tool_header: p.warning,
      code_bg: p.surface,
      code_border: p.border,
      input_border: p.highlight,
      input_bg: p.bg,
      input_placeholder: p.muted,
      thinking_fg: p.warning,
      status_thinking: p.warning,
      status_tool: p.info,
      status_error: p.error,
      status_idle: p.muted,
      text_fg: p.fg,
      context_low: p.success,
      context_mid: p.warning,
      context_high: p.error,
      usage_fg: p.muted,
      toast_bg: p.surface,
      toast_fg: p.fg,
      toast_border: p.border,
      system_fg: p.muted,
      search_match_bg: p.match,
      search_current_bg: p.error,
      heading1_fg: p.keywords,
      heading2_fg: p.functions,
      heading3_fg: p.success,
      hint_fg: p.muted,
      dashboard_label: p.highlight,
      delimiter_dim: p.subtle,
      link_fg: p.link
    }
  end

  @spec dashboard(Palette.t()) :: Theme.Dashboard.t()
  defp dashboard(%Palette{} = p) do
    %Theme.Dashboard{
      bg: p.bg,
      logo_fg: p.warning,
      heading_fg: p.highlight,
      item_fg: p.fg,
      item_active_bg: p.surface,
      shortcut_fg: p.success,
      muted_fg: p.muted
    }
  end

  @spec tab_bar(Palette.t()) :: Theme.TabBar.t()
  defp tab_bar(%Palette{} = p) do
    %Theme.TabBar{
      active_fg: p.fg,
      active_bg: p.bg,
      inactive_fg: p.muted,
      inactive_bg: p.surface,
      separator_fg: p.border,
      modified_fg: p.warning,
      attention_fg: p.error,
      close_hover_fg: p.error,
      bg: p.surface
    }
  end

  @spec hl_todo(Palette.t()) :: %{atom() => Face.t()}
  defp hl_todo(%Palette{} = p) do
    %{
      todo: Face.new(fg: p.warning, bold: true),
      fixme: Face.new(fg: p.error, bold: true),
      note: Face.new(fg: p.info, bold: true),
      hack: Face.new(fg: p.constants, bold: true),
      review: Face.new(fg: p.keywords, bold: true),
      deprecated: Face.new(fg: p.muted, strikethrough: true)
    }
  end

  @spec syntax(Palette.t()) :: Theme.syntax()
  defp syntax(%Palette{} = p) do
    %{
      "keyword" => [fg: p.keywords, bold: true],
      "keyword.function" => [fg: p.keywords, bold: true],
      "keyword.operator" => [fg: p.operators],
      "keyword.return" => [fg: p.keywords, bold: true],
      "keyword.conditional" => [fg: p.keywords, bold: true],
      "keyword.coroutine" => [fg: p.keywords, bold: true],
      "keyword.directive" => [fg: p.keywords],
      "keyword.exception" => [fg: p.keywords],
      "keyword.import" => [fg: p.keywords],
      "keyword.modifier" => [fg: p.keywords, bold: true],
      "keyword.repeat" => [fg: p.keywords, bold: true],
      "keyword.type" => [fg: p.keywords, bold: true],
      "conditional" => [fg: p.keywords, bold: true],
      "exception" => [fg: p.keywords],
      "include" => [fg: p.keywords],
      "import" => [fg: p.keywords],
      "repeat" => [fg: p.keywords, bold: true],
      "string" => [fg: p.strings],
      "string.special" => [fg: p.constants],
      "string.special.symbol" => [fg: p.builtin],
      "string.special.key" => [fg: p.functions],
      "string.special.regex" => [fg: p.constants],
      "string.escape" => [fg: p.operators],
      "string.regex" => [fg: p.constants],
      "character" => [fg: p.builtin],
      "comment" => [fg: p.comments, italic: true],
      "comment.doc" => [fg: p.muted, italic: true],
      "comment.documentation" => [fg: p.muted, italic: true],
      "comment.unused" => [fg: p.comments, italic: true],
      "comment.discard" => [fg: p.comments, italic: true],
      "function" => [fg: p.functions],
      "function.call" => [fg: p.functions],
      "function.builtin" => [fg: p.builtin],
      "function.macro" => [fg: p.keywords, bold: true],
      "function.method" => [fg: p.methods],
      "function.method.builtin" => [fg: p.builtin],
      "function.special" => [fg: p.keywords],
      "method" => [fg: p.methods],
      "method.call" => [fg: p.methods],
      "type" => [fg: p.type],
      "type.builtin" => [fg: p.type, bold: true],
      "variable" => [fg: p.variables],
      "variable.builtin" => [fg: p.error],
      "variable.parameter" => [fg: p.variables],
      "variable.member" => [fg: p.builtin],
      "parameter" => [fg: p.variables],
      "field" => [fg: p.builtin],
      "constant" => [fg: p.constants],
      "constant.builtin" => [fg: p.constants, bold: true],
      "boolean" => [fg: p.constants, bold: true],
      "number" => [fg: p.numbers],
      "number.float" => [fg: p.numbers],
      "float" => [fg: p.numbers],
      "operator" => [fg: p.operators],
      "punctuation" => [fg: p.muted],
      "punctuation.bracket" => [fg: p.muted],
      "punctuation.delimiter" => [fg: p.muted],
      "punctuation.special" => [fg: p.operators],
      "delimiter" => [fg: p.muted],
      "module" => [fg: p.type],
      "namespace" => [fg: p.type],
      "attribute" => [fg: p.builtin],
      "property" => [fg: p.builtin],
      "label" => [fg: p.info],
      "tag" => [fg: p.keywords],
      "tag.attribute" => [fg: p.type],
      "tag.error" => [fg: p.error, bold: true],
      "preproc" => [fg: p.operators, bold: true],
      "markup.heading" => [fg: p.error, bold: true],
      "markup.heading.1" => [fg: p.error, bold: true],
      "markup.heading.2" => [fg: p.constants, bold: true],
      "markup.heading.3" => [fg: p.warning, bold: true],
      "markup.heading.4" => [fg: p.success, bold: true],
      "markup.heading.5" => [fg: p.functions, bold: true],
      "markup.heading.6" => [fg: p.keywords, bold: true],
      "markup.bold" => [fg: p.constants, bold: true],
      "markup.strong" => [fg: p.constants, bold: true],
      "markup.italic" => [fg: p.variables, italic: true],
      "markup.strikethrough" => [fg: p.muted, strikethrough: true],
      "markup.raw" => [fg: p.strings],
      "markup.raw.block" => [fg: p.strings],
      "markup.raw.inline" => [fg: p.strings],
      "markup.link" => [fg: p.link],
      "markup.link.url" => [fg: p.link, underline: true],
      "markup.link.label" => [fg: p.functions],
      "markup.list" => [fg: p.error],
      "markup.list.numbered" => [fg: p.error],
      "markup.list.unnumbered" => [fg: p.error],
      "markup.list.checked" => [fg: p.success],
      "markup.list.unchecked" => [fg: p.muted],
      "markup.quote" => [fg: p.muted, italic: true],
      "charset" => [fg: p.keywords, bold: true],
      "keyframes" => [fg: p.keywords, bold: true],
      "media" => [fg: p.keywords, bold: true],
      "supports" => [fg: p.keywords, bold: true],
      "escape" => [fg: p.operators],
      "embedded" => [fg: p.variables],
      "constructor" => [fg: p.info, bold: true],
      "error" => [fg: p.error, bold: true],
      "warning" => [fg: p.warning, bold: true]
    }
  end

  @spec apply_overrides(Theme.t(), overrides()) :: Theme.t()
  defp apply_overrides(theme, overrides) when map_size(overrides) == 0, do: theme

  defp apply_overrides(%Theme{} = theme, overrides) when is_map(overrides) do
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
        %{acc | key => merge_value(Map.get(acc, key), value)}
      else
        raise ArgumentError,
              "unknown theme override field #{inspect(section)}.#{inspect(key)}"
      end
    end)
  end

  @spec merge_value(term(), term()) :: term()
  defp merge_value(%_{} = _current, value), do: value

  defp merge_value(current, value) when is_map(current) and is_map(value),
    do: Map.merge(current, value)

  defp merge_value(_current, value), do: value
end
