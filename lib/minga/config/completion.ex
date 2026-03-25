defmodule Minga.Config.Completion do
  @moduledoc """
  Generates completion items for the Minga config DSL.

  Pure calculation module with no state. Produces `Completion.item()` maps
  from the `Config.Options` registry for use in the completion popup when
  editing `config.exs` or `.minga.exs`.

  Three categories of completions:

  1. **Option names** (`set :tab_width, ...`) with type and default as detail
  2. **Option values** (`set :theme, :doom_one`) for enum, boolean, and theme types
  3. **Filetype atoms** (`for_filetype :elixir, ...`) from `Minga.Language.Filetype`
  """

  alias Minga.Config.Options
  alias Minga.Language.Filetype

  @typedoc "A completion item compatible with `Minga.Completion.item()`."
  @type item :: %{
          label: String.t(),
          kind: atom(),
          insert_text: String.t(),
          filter_text: String.t(),
          detail: String.t(),
          documentation: String.t(),
          sort_text: String.t(),
          text_edit: nil,
          raw: nil
        }

  @doc """
  Returns completion items for all config option names.

  Each item's label is the atom name (e.g., `:tab_width`), detail shows
  the type and default, and documentation provides a human-readable
  description of the option.
  """
  @spec option_name_items() :: [item()]
  def option_name_items do
    Options.option_specs()
    |> Enum.map(fn {name, type, default} ->
      name_str = Atom.to_string(name)

      %{
        label: ":#{name_str}",
        kind: :property,
        insert_text: ":#{name_str}",
        filter_text: name_str,
        detail: format_type(type),
        documentation: option_documentation(name, type, default),
        sort_text: name_str,
        text_edit: nil,
        raw: nil
      }
    end)
    |> Enum.sort_by(& &1.sort_text)
  end

  @doc """
  Returns completion items for valid values of the given option.

  Returns a non-empty list for enum types, booleans, and theme options.
  Returns `[]` for types without enumerable values (strings, integers).
  """
  @spec option_value_items(Options.option_name()) :: [item()]
  def option_value_items(option_name) when is_atom(option_name) do
    case Options.type_for(option_name) do
      {:enum, values} ->
        Enum.map(values, fn val ->
          val_str = Atom.to_string(val)
          default = Options.default(option_name)
          is_default = val == default

          %{
            label: ":#{val_str}",
            kind: :enum_member,
            insert_text: ":#{val_str}",
            filter_text: val_str,
            detail: if(is_default, do: "(default)", else: ""),
            documentation: "",
            sort_text: val_str,
            text_edit: nil,
            raw: nil
          }
        end)

      :boolean ->
        default = Options.default(option_name)

        Enum.map([true, false], fn val ->
          val_str = Atom.to_string(val)
          is_default = val == default

          %{
            label: val_str,
            kind: :value,
            insert_text: val_str,
            filter_text: val_str,
            detail: if(is_default, do: "(default)", else: ""),
            documentation: "",
            sort_text: val_str,
            text_edit: nil,
            raw: nil
          }
        end)

      :theme_atom ->
        default = Options.default(option_name)

        Minga.Theme.available()
        |> Enum.map(fn theme ->
          theme_str = Atom.to_string(theme)
          is_default = theme == default

          %{
            label: ":#{theme_str}",
            kind: :color,
            insert_text: ":#{theme_str}",
            filter_text: theme_str,
            detail: if(is_default, do: "(default)", else: ""),
            documentation: "",
            sort_text: theme_str,
            text_edit: nil,
            raw: nil
          }
        end)

      _ ->
        []
    end
  end

  def option_value_items(_unknown), do: []

  @doc """
  Returns completion items for known filetype atoms.

  Used when the cursor is after `for_filetype :` to suggest available
  filetypes like `:elixir`, `:go`, `:python`, etc.
  """
  @spec filetype_items() :: [item()]
  def filetype_items do
    filetypes =
      (Map.values(Filetype.filenames()) ++ Map.values(Filetype.extensions()))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(filetypes, fn ft ->
      ft_str = Atom.to_string(ft)
      extensions = extensions_for_filetype(ft)

      %{
        label: ":#{ft_str}",
        kind: :enum_member,
        insert_text: ":#{ft_str}",
        filter_text: ft_str,
        detail: extensions,
        documentation: "",
        sort_text: ft_str,
        text_edit: nil,
        raw: nil
      }
    end)
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec format_type(Options.type_descriptor()) :: String.t()
  defp format_type(:pos_integer), do: "positive integer"
  defp format_type(:non_neg_integer), do: "non-negative integer"
  defp format_type(:integer), do: "integer"
  defp format_type(:boolean), do: "boolean"
  defp format_type(:atom), do: "atom"
  defp format_type(:string), do: "string"
  defp format_type(:string_or_nil), do: "string or nil"
  defp format_type(:string_list), do: "list of strings"
  defp format_type(:map_or_nil), do: "map or nil"
  defp format_type(:float_or_nil), do: "float or nil"
  defp format_type(:theme_atom), do: "theme"
  defp format_type(:any), do: "any"
  defp format_type({:enum, values}), do: Enum.map_join(values, " | ", &inspect/1)

  @spec option_documentation(atom(), Options.type_descriptor(), term()) :: String.t()
  defp option_documentation(name, type, default) do
    type_line = "**Type:** #{format_type(type)}"
    default_line = "**Default:** `#{inspect(default)}`"
    desc = option_description(name)

    lines = [desc, "", type_line, default_line]
    Enum.join(lines, "\n")
  end

  @spec option_description(atom()) :: String.t()
  defp option_description(:editing_model),
    do: "Editing model: Vim keybindings or CUA (standard) keybindings."

  defp option_description(:tab_width), do: "Number of spaces per tab stop."

  defp option_description(:line_numbers),
    do: "Line number display: hybrid (relative + current absolute), absolute, relative, or none."

  defp option_description(:show_gutter_separator),
    do: "Show a vertical separator between the gutter and the buffer content."

  defp option_description(:autopair),
    do: "Automatically insert matching brackets, quotes, and parentheses."

  defp option_description(:scroll_margin),
    do: "Minimum lines to keep visible above and below the cursor when scrolling."

  defp option_description(:scroll_lines), do: "Number of lines to scroll per scroll wheel tick."
  defp option_description(:theme), do: "Color theme for syntax highlighting and UI elements."
  defp option_description(:indent_with), do: "Use spaces or tabs for indentation."
  defp option_description(:trim_trailing_whitespace), do: "Remove trailing whitespace on save."
  defp option_description(:insert_final_newline), do: "Ensure file ends with a newline on save."

  defp option_description(:format_on_save),
    do: "Run the configured formatter when saving a buffer."

  defp option_description(:formatter),
    do:
      "External formatter command (e.g., \"mix format\"). Nil uses the default for the filetype."

  defp option_description(:title_format),
    do: "Window title template. Placeholders: {filename}, {dirty}, {directory}."

  defp option_description(:recent_files_limit), do: "Maximum number of recent files to remember."

  defp option_description(:persist_recent_files),
    do: "Persist recent file list across editor restarts."

  defp option_description(:clipboard), do: "Clipboard integration mode."
  defp option_description(:wrap), do: "Soft-wrap long lines at the viewport edge."
  defp option_description(:linebreak), do: "Break lines at word boundaries when wrapping."
  defp option_description(:breakindent), do: "Preserve indentation on wrapped continuation lines."

  defp option_description(:agent_provider),
    do: "AI agent backend: auto-detect, native (built-in), or pi_rpc (delegated)."

  defp option_description(:agent_model),
    do: "Override the default AI model. Nil uses the provider's default."

  defp option_description(:agent_tool_approval),
    do: "When to require approval for agent tool calls: destructive-only, all, or none."

  defp option_description(:agent_destructive_tools),
    do:
      "List of tool names considered destructive (require approval when agent_tool_approval is :destructive)."

  defp option_description(:agent_tool_permissions),
    do: "Per-tool permission overrides as a map of tool name to :allow/:deny/:ask."

  defp option_description(:agent_session_retention_days),
    do: "Days to keep agent session history before cleanup."

  defp option_description(:agent_panel_split),
    do: "Agent panel width as a percentage of the viewport (30-80)."

  defp option_description(:startup_view),
    do: "Which view to show on startup: the agent panel or the editor."

  defp option_description(:agent_auto_context),
    do: "Automatically include buffer context in agent prompts."

  defp option_description(:agent_max_tokens), do: "Maximum tokens per agent response."
  defp option_description(:agent_max_retries), do: "Maximum retries on agent API failures."

  defp option_description(:agent_models),
    do: "List of available model identifiers for the model picker."

  defp option_description(:agent_prompt_cache),
    do: "Enable prompt caching for supported providers."

  defp option_description(:agent_notifications),
    do: "Enable desktop notifications for agent events."

  defp option_description(:agent_notify_on),
    do: "Which agent events trigger notifications: :approval, :complete, :error."

  defp option_description(:agent_system_prompt),
    do: "Custom system prompt that replaces the default agent system prompt."

  defp option_description(:agent_append_system_prompt),
    do: "Text appended to the default agent system prompt (additive, not replacing)."

  defp option_description(:agent_diff_size_threshold),
    do: "Maximum diff size in bytes before truncating in agent context."

  defp option_description(:agent_max_turns), do: "Maximum conversation turns per agent session."

  defp option_description(:agent_max_cost),
    do: "Maximum cost in dollars per agent session. Nil for unlimited."

  defp option_description(:agent_api_base_url), do: "Override the base URL for the agent API."
  defp option_description(:agent_api_endpoints), do: "Per-model API endpoint overrides as a map."

  defp option_description(:agent_compaction_threshold),
    do: "Context window usage ratio that triggers automatic compaction. Nil to disable."

  defp option_description(:agent_compaction_keep_recent),
    do: "Number of recent messages to preserve during compaction."

  defp option_description(:agent_approval_timeout),
    do: "Timeout in milliseconds for tool approval prompts."

  defp option_description(:agent_subagent_timeout),
    do: "Timeout in milliseconds for subagent tool calls."

  defp option_description(:agent_mention_max_file_size),
    do: "Maximum file size in bytes for @file mentions in agent chat."

  defp option_description(:agent_notify_debounce),
    do: "Debounce interval in milliseconds for agent notifications."

  defp option_description(:confirm_quit),
    do: "Ask for confirmation before quitting with unsaved changes."

  defp option_description(:font_family), do: "Font family name (GUI frontends only)."
  defp option_description(:font_size), do: "Font size in points (GUI frontends only)."
  defp option_description(:font_weight), do: "Font weight (GUI frontends only)."
  defp option_description(:font_ligatures), do: "Enable font ligatures (GUI frontends only)."

  defp option_description(:font_fallback),
    do: "Fallback font families for missing glyphs (GUI frontends only)."

  defp option_description(:prettify_symbols),
    do: "Replace certain symbols with Unicode equivalents (e.g., -> becomes →)."

  defp option_description(:whichkey_layout),
    do: "Which-key popup position: bottom bar or floating window."

  defp option_description(:log_level), do: "Global log level for the *Messages* buffer."

  defp option_description(:log_level_render),
    do: "Log level for the render subsystem. :default inherits from :log_level."

  defp option_description(:log_level_lsp),
    do: "Log level for LSP communication. :default inherits from :log_level."

  defp option_description(:log_level_agent),
    do: "Log level for the AI agent subsystem. :default inherits from :log_level."

  defp option_description(:log_level_editor),
    do: "Log level for editor operations. :default inherits from :log_level."

  defp option_description(:log_level_config),
    do: "Log level for config loading. :default inherits from :log_level."

  defp option_description(:log_level_port),
    do: "Log level for port/frontend communication. :default inherits from :log_level."

  defp option_description(:cursorline), do: "Highlight the line the cursor is on."

  defp option_description(:nav_flash),
    do: "Flash the cursor line after large jumps for visual orientation."

  defp option_description(:nav_flash_threshold),
    do: "Minimum line distance to trigger the navigation flash."

  defp option_description(:parser_tree_ttl),
    do: "Seconds to keep unused tree-sitter parse trees in memory."

  defp option_description(:event_retention_days),
    do: "Days to keep event log entries before cleanup."

  defp option_description(_), do: ""

  @spec extensions_for_filetype(atom()) :: String.t()
  defp extensions_for_filetype(filetype) do
    exts =
      Filetype.extensions()
      |> Enum.filter(fn {_ext, ft} -> ft == filetype end)
      |> Enum.map(fn {ext, _ft} -> ".#{ext}" end)
      |> Enum.sort()
      |> Enum.take(4)

    case exts do
      [] -> ""
      list -> Enum.join(list, ", ")
    end
  end
end
