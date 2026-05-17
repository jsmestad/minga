defmodule MingaEditor.Commands.Help do
  @moduledoc """
  Help commands and special help buffer management.

  Help content is created lazily, reused across invocations, and always shown in read-only special buffers.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias Minga.Command
  alias Minga.Config.Options
  alias Minga.Keymap
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias MingaEditor.Commands
  alias MingaEditor.HighlightSync
  alias MingaEditor.KeystrokeHistory
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Workspace.State, as: WorkspaceState
  alias Minga.Mode

  @type state :: EditorState.t()
  @type binding_entry :: %{
          required(:keys) => [Bindings.key()],
          required(:command) => atom() | tuple(),
          required(:description) => String.t(),
          required(:source) => :default | :user,
          optional(:display_key) => String.t()
        }

  command(:describe_bindings, "Describe bindings", requires_buffer: false)
  command(:describe_command, "Describe command", requires_buffer: false)
  command(:describe_option, "Describe option", requires_buffer: false)
  command(:indent_picker, "Open indent settings picker", requires_buffer: false)
  command(:describe_lossage, "Show keystroke history", requires_buffer: false)
  command(:describe_function, "Describe function", requires_buffer: false)

  @spec execute(state(), Mode.command()) :: state()
  def execute(state, {:describe_key_result, key_str, command, description}) do
    content = format_describe_key(key_str, command, description)
    show_in_help_buffer(state, content)
  end

  def execute(state, {:describe_key_not_found, key_str}) do
    content = "Key not bound: #{key_str}\n"
    show_in_help_buffer(state, content)
  end

  def execute(state, :describe_bindings) do
    show_in_buffer(state, "*Bindings*", bindings_content(state))
  end

  def execute(state, :describe_command) do
    PickerUI.open(state, MingaEditor.UI.Picker.CommandHelpSource)
  end

  def execute(state, {:describe_command_named, name}) when is_atom(name) do
    describe_command_by_atom(state, name)
  end

  def execute(state, {:describe_command_named, name}) when is_binary(name) do
    describe_command_named(state, name)
  end

  def execute(state, :describe_option) do
    PickerUI.open(state, MingaEditor.UI.Picker.OptionSource)
  end

  def execute(state, :indent_picker) do
    PickerUI.open(state, MingaEditor.UI.Picker.IndentOptionSource)
  end

  def execute(state, :describe_lossage) do
    show_in_buffer(state, "*Keystrokes*", lossage_content(state))
  end

  def execute(state, :describe_function) do
    PickerUI.open(state, MingaEditor.UI.Picker.HelpSource)
  end

  def execute(state, {:describe_option_named, name}) when is_binary(name) do
    describe_option_named(state, name)
  end

  @doc "Shows content in the shared `*Help*` buffer."
  @spec show_in_help_buffer(state(), String.t()) :: state()
  @spec show_in_help_buffer(state(), String.t(), keyword()) :: state()
  def show_in_help_buffer(state, content, opts \\ []) do
    show_in_buffer(state, "*Help*", content, default_help_options(opts))
  end

  @doc "Shows the option help page for `name`."
  @spec describe_option(state(), atom()) :: state()
  def describe_option(state, name) when is_atom(name) do
    case Options.describe(name) do
      nil -> show_in_help_buffer(state, "Unknown option: #{name}\n")
      metadata -> show_in_help_buffer(state, option_content(state, metadata))
    end
  end

  @doc "Shows the extension option help page for `extension.name`."
  @spec describe_extension_option(state(), atom(), atom()) :: state()
  def describe_extension_option(state, extension, name)
      when is_atom(extension) and is_atom(name) do
    options_server = EditorState.options_server(state)

    case Options.describe_extension_option(options_server, extension, name) do
      nil -> show_in_help_buffer(state, "Unknown option: #{extension}.#{name}\n")
      metadata -> show_in_help_buffer(state, extension_option_content(state, metadata))
    end
  end

  @doc "Formats all keybindings active in the current editor state."
  @spec bindings_content(state()) :: String.t()
  def bindings_content(state) do
    sections = leader_sections(state) ++ filetype_sections(state) ++ normal_sections(state)

    ["# Keybindings", "", "Mode: #{current_mode(state)}", "", Enum.join(sections, "\n")]
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

  @doc "Formats a detailed option help page."
  @spec option_content(state(), Options.option_metadata()) :: String.t()
  def option_content(state, %{name: name, type: type, default: default, description: description}) do
    filetype = current_filetype(state)
    buffer = active_buffer(state)
    current = current_option_value(state, name, filetype, buffer)
    provenance = option_provenance(state, name, filetype, buffer)

    [
      "# Option: #{name}",
      "",
      "Name: #{name}",
      "Current value: #{inspect(current)}",
      "Default: #{inspect(default)}",
      "Type: #{format_type(type)}",
      "Set by: #{Enum.join(provenance, " → ")}",
      "",
      "Description:",
      description,
      ""
    ]
    |> Enum.join("\n")
  end

  @doc "Formats a detailed extension option help page."
  @spec extension_option_content(state(), Options.extension_option_metadata()) :: String.t()
  def extension_option_content(state, %{
        extension: extension,
        name: name,
        type: type,
        default: default,
        description: description
      }) do
    filetype = current_filetype(state)
    options_server = EditorState.options_server(state)
    current = Options.get_extension_option_for_filetype(options_server, extension, name, filetype)
    provenance = Options.extension_provenance(options_server, extension, name, filetype)

    [
      "# Option: #{extension}.#{name}",
      "",
      "Name: #{extension}.#{name}",
      "Current value: #{inspect(current)}",
      "Default: #{inspect(default)}",
      "Type: #{format_type(type)}",
      "Set by: #{Enum.join(provenance, " → ")}",
      "",
      "Description:",
      description,
      ""
    ]
    |> Enum.join("\n")
  end

  # ── Binding formatting ──────────────────────────────────────────────────────

  @spec leader_sections(state()) :: [String.t()]
  defp leader_sections(state) do
    default_map = default_leader_map()

    state
    |> active_leader_entries(default_map)
    |> Enum.group_by(&leader_group/1)
    |> ordered_group_sections()
  end

  @spec filetype_sections(state()) :: [String.t()]
  defp filetype_sections(state) do
    filetype = current_filetype(state)
    entries = active_filetype_entries(state, filetype)

    case entries do
      [] -> []
      _ -> [format_section("+filetype #{inspect(filetype)}", entries)]
    end
  end

  @spec normal_sections(state()) :: [String.t()]
  defp normal_sections(state) do
    default_map = Defaults.normal_bindings()

    normal_entries =
      state
      |> active_normal_entries(default_map)
      |> Enum.group_by(&normal_group/1)
      |> ordered_normal_sections()

    text_objects = format_section("Text objects", text_object_entries())
    normal_entries ++ [text_objects]
  end

  @spec active_leader_entries(state(), %{[Bindings.key()] => {atom() | tuple(), String.t()}}) :: [
          binding_entry()
        ]
  defp active_leader_entries(state, default_map) do
    trie = Keymap.leader_trie(EditorState.keymap_server(state))

    trie
    |> flatten_trie([])
    |> Enum.map(&mark_entry_source(&1, default_map))
    |> Enum.map(&prefix_keys(&1, [Defaults.leader_key()]))
    |> Enum.sort_by(&format_key_sequence(&1.keys))
  catch
    :exit, _ ->
      Defaults.all_bindings()
      |> Enum.map(fn {keys, command, description} ->
        %{
          keys: [Defaults.leader_key() | keys],
          command: command,
          description: description,
          source: :default
        }
      end)
  end

  @spec active_filetype_entries(state(), atom() | nil) :: [binding_entry()]
  defp active_filetype_entries(_state, nil), do: []

  defp active_filetype_entries(state, filetype) do
    default_map = default_filetype_map(filetype)
    trie = Keymap.filetype_trie(EditorState.keymap_server(state), filetype)

    trie
    |> flatten_trie([])
    |> Enum.map(&mark_entry_source(&1, default_map))
    |> Enum.map(&prefix_keys(&1, [Defaults.leader_key(), {?m, 0}]))
    |> Enum.sort_by(&format_key_sequence(&1.keys))
  catch
    :exit, _ -> []
  end

  @spec active_normal_entries(state(), %{Bindings.key() => {atom(), String.t()}}) :: [
          binding_entry()
        ]
  defp active_normal_entries(state, default_map) do
    state
    |> normal_bindings_for_state()
    |> Enum.map(fn {key, {command, description}} ->
      source = entry_source(Map.get(default_map, key), command, description)
      %{keys: [key], command: command, description: description, source: source}
    end)
    |> Enum.sort_by(&format_key_sequence(&1.keys))
  end

  @spec normal_bindings_for_state(state()) :: %{Bindings.key() => {atom(), String.t()}}
  defp normal_bindings_for_state(state) do
    Keymap.normal_bindings(EditorState.keymap_server(state))
  catch
    :exit, _ -> Defaults.normal_bindings()
  end

  @spec flatten_trie(Bindings.node_t(), [Bindings.key()]) :: [binding_entry()]
  defp flatten_trie(%Bindings.Node{} = node, prefix) do
    current = current_binding(node, prefix)

    children =
      node.children
      |> Enum.flat_map(fn {key, child} -> flatten_trie(child, prefix ++ [key]) end)

    current ++ children
  end

  @spec current_binding(Bindings.node_t(), [Bindings.key()]) :: [binding_entry()]
  defp current_binding(%Bindings.Node{command: nil}, _prefix), do: []

  defp current_binding(%Bindings.Node{command: command, description: description}, prefix) do
    [%{keys: prefix, command: command, description: description || "", source: :default}]
  end

  @spec mark_entry_source(binding_entry(), %{[Bindings.key()] => {atom() | tuple(), String.t()}}) ::
          binding_entry()
  defp mark_entry_source(
         %{keys: keys, command: command, description: description} = entry,
         default_map
       ) do
    %{entry | source: entry_source(Map.get(default_map, keys), command, description)}
  end

  @spec entry_source({atom() | tuple(), String.t()} | nil, atom() | tuple(), String.t()) ::
          :default | :user
  defp entry_source({command, description}, command, description), do: :default
  defp entry_source(_default, _command, _description), do: :user

  @spec prefix_keys(binding_entry(), [Bindings.key()]) :: binding_entry()
  defp prefix_keys(%{keys: keys} = entry, prefix), do: %{entry | keys: prefix ++ keys}

  @spec default_leader_map() :: %{[Bindings.key()] => {atom(), String.t()}}
  defp default_leader_map do
    Map.new(Defaults.all_bindings(), fn {keys, command, description} ->
      {keys, {command, description}}
    end)
  end

  @spec default_filetype_map(atom()) :: %{[Bindings.key()] => {atom(), String.t()}}
  defp default_filetype_map(filetype) do
    Defaults.filetype_bindings()
    |> Enum.filter(fn {ft, _keys, _command, _description} -> ft == filetype end)
    |> Map.new(fn {_ft, keys, command, description} -> {keys, {command, description}} end)
  end

  @spec leader_group(binding_entry()) :: String.t()
  defp leader_group(%{keys: [_leader | rest]}) do
    Defaults.group_prefixes()
    |> Enum.sort_by(fn {keys, _label} -> -length(keys) end)
    |> Enum.find_value("Ungrouped", fn {prefix, label} ->
      if prefix?(prefix, rest), do: label, else: nil
    end)
  end

  @spec prefix?([Bindings.key()], [Bindings.key()]) :: boolean()
  defp prefix?(prefix, keys), do: Enum.take(keys, length(prefix)) == prefix

  @spec normal_group(binding_entry()) :: String.t()
  defp normal_group(%{command: command})
       when command in [
              :move_left,
              :move_down,
              :move_up,
              :move_right,
              :move_to_line_start,
              :move_to_line_end,
              :move_to_first_non_blank,
              :move_to_document_end,
              :word_forward,
              :word_backward,
              :word_end,
              :word_forward_big,
              :word_backward_big,
              :word_end_big,
              :match_bracket,
              :paragraph_backward,
              :paragraph_forward,
              :move_to_screen_top,
              :move_to_screen_middle,
              :move_to_screen_bottom,
              :next_line_first_non_blank,
              :prev_line_first_non_blank
            ],
       do: "Movement"

  defp normal_group(%{command: command})
       when command in [
              :pending_find_forward,
              :pending_find_backward,
              :pending_till_forward,
              :pending_till_backward,
              :repeat_find_char,
              :repeat_find_char_reverse
            ],
       do: "Find char"

  defp normal_group(%{command: command})
       when command in [
              :operator_delete,
              :operator_change,
              :operator_yank,
              :paste_after,
              :paste_before,
              :delete_chars_at,
              :delete_chars_before,
              :delete_to_end,
              :change_to_end,
              :substitute_char,
              :substitute_line,
              :join_lines,
              :toggle_case,
              :pending_replace_char,
              :indent,
              :dedent
            ],
       do: "Operators"

  defp normal_group(%{command: command})
       when command in [
              :search_forward,
              :search_backward,
              :search_next,
              :search_prev,
              :search_word_forward,
              :search_word_backward
            ],
       do: "Search"

  defp normal_group(%{command: command})
       when command in [
              :enter_insert,
              :enter_insert_after,
              :enter_insert_end_of_line,
              :enter_insert_start_of_line,
              :insert_line_below,
              :insert_line_above,
              :enter_visual,
              :enter_visual_line,
              :enter_replace_mode,
              :enter_command,
              :enter_eval
            ],
       do: "Mode transitions"

  defp normal_group(%{command: command})
       when command in [:half_page_down, :half_page_up, :page_down, :page_up], do: "Scrolling"

  defp normal_group(%{command: command}) when command in [:undo, :redo, :dot_repeat],
    do: "Undo / Redo"

  defp normal_group(%{command: command})
       when command in [
              :pending_register,
              :pending_set_mark,
              :pending_jump_mark_line,
              :pending_jump_mark_exact,
              :toggle_macro_recording,
              :replay_macro
            ],
       do: "Registers / Marks / Macros"

  defp normal_group(_entry), do: "Misc"

  @spec ordered_group_sections(%{String.t() => [binding_entry()]}) :: [String.t()]
  defp ordered_group_sections(grouped) do
    ordered_labels =
      Enum.map(Defaults.group_prefixes(), fn {_keys, label} -> label end) ++ ["Ungrouped"]

    ordered_sections(grouped, ordered_labels)
  end

  @spec ordered_normal_sections(%{String.t() => [binding_entry()]}) :: [String.t()]
  defp ordered_normal_sections(grouped) do
    ordered_sections(grouped, [
      "Movement",
      "Find char",
      "Scrolling",
      "Mode transitions",
      "Operators",
      "Undo / Redo",
      "Search",
      "Registers / Marks / Macros",
      "Misc"
    ])
  end

  @spec ordered_sections(%{String.t() => [binding_entry()]}, [String.t()]) :: [String.t()]
  defp ordered_sections(grouped, labels) do
    labels
    |> Enum.flat_map(fn label ->
      entries = Map.get(grouped, label, [])
      if entries == [], do: [], else: [format_section(label, entries)]
    end)
  end

  @spec format_section(String.t(), [binding_entry()]) :: String.t()
  defp format_section(title, entries) do
    key_width = entries |> Enum.map(&String.length(format_entry_key(&1))) |> Enum.max(fn -> 0 end)

    command_width =
      entries |> Enum.map(&String.length(format_command(&1.command))) |> Enum.max(fn -> 0 end)

    lines = Enum.map(entries, &format_binding_line(&1, key_width, command_width))
    Enum.join([title, String.duplicate("-", String.length(title)) | lines], "\n")
  end

  @spec format_binding_line(binding_entry(), non_neg_integer(), non_neg_integer()) :: String.t()
  defp format_binding_line(entry, key_width, command_width) do
    marker = if entry.source == :user, do: " *user*", else: ""

    [
      String.pad_trailing(format_entry_key(entry), key_width),
      "    ",
      String.pad_trailing(format_command(entry.command), command_width),
      "    ",
      entry.description,
      marker
    ]
    |> Enum.join()
  end

  @spec text_object_entries() :: [binding_entry()]
  defp text_object_entries do
    [
      {"iw", :text_object_inner_word, "Inner word"},
      {"aw", :text_object_around_word, "Around word"},
      {"i\"", :text_object_inner_double_quote, "Inside double quotes"},
      {"a\"", :text_object_around_double_quote, "Around double quotes"},
      {"i'", :text_object_inner_single_quote, "Inside single quotes"},
      {"a'", :text_object_around_single_quote, "Around single quotes"},
      {"i(", :text_object_inner_paren, "Inside parentheses"},
      {"a(", :text_object_around_paren, "Around parentheses"},
      {"i[", :text_object_inner_bracket, "Inside brackets"},
      {"a[", :text_object_around_bracket, "Around brackets"},
      {"i{", :text_object_inner_brace, "Inside braces"},
      {"a{", :text_object_around_brace, "Around braces"},
      {"if", :text_object_inner_function, "Inside function"},
      {"af", :text_object_around_function, "Around function"},
      {"ic", :text_object_inner_class, "Inside class/module"},
      {"ac", :text_object_around_class, "Around class/module"}
    ]
    |> Enum.map(fn {key, command, description} ->
      %{
        keys: display_keys(key),
        command: command,
        description: description,
        source: :default,
        display_key: key
      }
    end)
  end

  @spec display_keys(String.t()) :: [Bindings.key()]
  defp display_keys(key_string) do
    key_string
    |> String.to_charlist()
    |> Enum.map(&{&1, 0})
  end

  @spec format_entry_key(binding_entry()) :: String.t()
  defp format_entry_key(%{display_key: display_key}) when is_binary(display_key), do: display_key
  defp format_entry_key(%{keys: keys}), do: format_key_sequence(keys)

  @spec format_key_sequence([Bindings.key()]) :: String.t()
  defp format_key_sequence(keys), do: Enum.map_join(keys, " ", &Bindings.format_key/1)

  @spec format_command(atom() | tuple()) :: String.t()
  defp format_command(command) when is_atom(command), do: Atom.to_string(command)
  defp format_command(command), do: inspect(command)

  # ── Option formatting ───────────────────────────────────────────────────────

  @spec describe_option_named(state(), String.t()) :: state()
  defp describe_option_named(state, raw_name) do
    case option_name_from_string(state, raw_name) do
      nil -> show_in_help_buffer(state, "Unknown option: #{String.trim(raw_name)}\n")
      {:extension, extension, name} -> describe_extension_option(state, extension, name)
      name -> describe_option(state, name)
    end
  end

  @spec option_name_from_string(state(), String.t()) ::
          atom() | {:extension, atom(), atom()} | nil
  defp option_name_from_string(state, raw_name) do
    normalized = raw_name |> String.trim() |> String.trim_leading(":")

    case Enum.find(Options.valid_names(), &(Atom.to_string(&1) == normalized)) do
      nil -> extension_option_name_from_string(state, normalized)
      name -> name
    end
  end

  @spec extension_option_name_from_string(state(), String.t()) ::
          {:extension, atom(), atom()} | nil
  defp extension_option_name_from_string(state, normalized) do
    options_server = EditorState.options_server(state)

    Options.extension_option_specs(options_server)
    |> Enum.find_value(fn %{extension: extension, name: name} ->
      if "#{extension}.#{name}" == normalized, do: {:extension, extension, name}, else: nil
    end)
  end

  @spec current_option_value(state(), Options.option_name(), atom() | nil, pid() | nil) :: term()
  defp current_option_value(state, name, filetype, buffer) when is_pid(buffer) do
    options_server = EditorState.options_server(state)

    case Map.fetch(Buffer.local_options(buffer), name) do
      {:ok, value} -> value
      :error -> Options.get_for_filetype(options_server, name, filetype)
    end
  catch
    :exit, _ -> Options.get_for_filetype(EditorState.options_server(state), name, filetype)
  end

  defp current_option_value(state, name, filetype, _buffer) do
    Options.get_for_filetype(EditorState.options_server(state), name, filetype)
  end

  @spec option_provenance(state(), Options.option_name(), atom() | nil, pid() | nil) :: [
          String.t()
        ]
  defp option_provenance(state, name, filetype, buffer) do
    state
    |> EditorState.options_server()
    |> Options.provenance(name, filetype)
    |> maybe_append_buffer_local(buffer_local_override?(buffer, name))
  end

  @spec maybe_append_buffer_local([String.t()], boolean()) :: [String.t()]
  defp maybe_append_buffer_local(provenance, true), do: provenance ++ ["buffer-local"]
  defp maybe_append_buffer_local(provenance, false), do: provenance

  @spec buffer_local_override?(pid() | nil, atom()) :: boolean()
  defp buffer_local_override?(nil, _name), do: false

  defp buffer_local_override?(buffer, name) when is_pid(buffer) do
    buffer
    |> Buffer.local_option_overrides()
    |> Map.has_key?(name)
  catch
    :exit, _ -> false
  end

  @spec format_type(Options.type_descriptor()) :: String.t()
  defp format_type(:pos_integer), do: "positive integer"
  defp format_type(:non_neg_integer), do: "non-negative integer"
  defp format_type(:integer), do: "integer"
  defp format_type(:boolean), do: "boolean"
  defp format_type(:atom), do: "atom"
  defp format_type(:theme_atom), do: "theme name atom"
  defp format_type(:string), do: "string"
  defp format_type(:string_or_nil), do: "string or nil"
  defp format_type(:string_list), do: "list of strings"
  defp format_type(:map_or_nil), do: "map or nil"
  defp format_type(:map_list), do: "list of maps"
  defp format_type(:float_or_nil), do: "positive number or nil"
  defp format_type(:any), do: "any"
  defp format_type({:enum, values}), do: "one of: #{Enum.map_join(values, ", ", &inspect/1)}"

  # ── Lossage formatting ─────────────────────────────────────────────────────

  @spec lossage_content(state()) :: String.t()
  defp lossage_content(state) do
    entries = KeystrokeHistory.entries(state.keystroke_history)

    case entries do
      [] ->
        "# Keystroke History\n\nNo keystrokes recorded yet.\n"

      _ ->
        groups = group_keystrokes(entries)
        lines = format_keystroke_groups(groups)

        [
          "# Keystroke History (last #{length(entries)} keys)",
          "",
          String.pad_trailing("Time", 13) <>
            String.pad_trailing("Mode", 18) <>
            String.pad_trailing("Keys", 20) <>
            "Info",
          String.duplicate("─", 70)
          | lines
        ]
        |> Enum.join("\n")
        |> ensure_trailing_newline()
    end
  end

  @typep keystroke_group :: %{
           entries: [KeystrokeHistory.entry()],
           kind: :operator_sequence | :insert_run | :single
         }

  @spec group_keystrokes([KeystrokeHistory.entry()]) :: [keystroke_group()]
  defp group_keystrokes(entries) do
    entries
    |> Enum.chunk_while(
      nil,
      &keystroke_chunk_fun/2,
      &keystroke_chunk_after/1
    )
  end

  @spec keystroke_chunk_fun(KeystrokeHistory.entry(), nil | keystroke_group()) ::
          {:cont, keystroke_group()} | {:cont, keystroke_group(), keystroke_group()}
  defp keystroke_chunk_fun(entry, nil) do
    {:cont, start_group(entry)}
  end

  defp keystroke_chunk_fun(entry, %{kind: :insert_run} = group) do
    if entry.mode_before == :insert and entry.mode_after == :insert do
      {:cont, %{group | entries: group.entries ++ [entry]}}
    else
      {:cont, group, start_group(entry)}
    end
  end

  defp keystroke_chunk_fun(entry, %{kind: :operator_sequence} = group) do
    if entry.mode_before == :operator_pending do
      {:cont, %{group | entries: group.entries ++ [entry]}}
    else
      {:cont, group, start_group(entry)}
    end
  end

  defp keystroke_chunk_fun(entry, %{kind: :single} = group) do
    if entry.mode_before == :operator_pending do
      prev = %{group | kind: :operator_sequence}
      {:cont, %{prev | entries: prev.entries ++ [entry]}}
    else
      {:cont, group, start_group(entry)}
    end
  end

  @spec keystroke_chunk_after(nil | keystroke_group()) ::
          {:cont, keystroke_group(), nil} | {:cont, nil}
  defp keystroke_chunk_after(nil), do: {:cont, nil}
  defp keystroke_chunk_after(group), do: {:cont, group, nil}

  @spec start_group(KeystrokeHistory.entry()) :: keystroke_group()
  defp start_group(entry) do
    kind =
      if entry.mode_before == :insert and entry.mode_after == :insert,
        do: :insert_run,
        else: :single

    %{entries: [entry], kind: kind}
  end

  @spec format_keystroke_groups([keystroke_group()]) :: [String.t()]
  defp format_keystroke_groups(groups) do
    groups
    |> Enum.reduce({[], nil}, fn group, {lines, prev_mode} ->
      first_entry = hd(group.entries)
      mode = first_entry.mode_before

      mode_annotation =
        if prev_mode != nil and prev_mode != mode do
          ["", "  ── mode: #{mode} ──", ""]
        else
          []
        end

      last_entry = List.last(group.entries)
      next_mode = last_entry.mode_after
      group_lines = format_group(group)

      {lines ++ mode_annotation ++ group_lines, next_mode}
    end)
    |> elem(0)
  end

  @spec format_group(keystroke_group()) :: [String.t()]
  defp format_group(%{kind: :insert_run, entries: entries}) when length(entries) > 3 do
    first = hd(entries)
    count = length(entries)
    keys = Enum.map_join(entries, "", fn e -> format_insert_char(e.key) end)
    display = if String.length(keys) > 18, do: String.slice(keys, 0, 15) <> "...", else: keys

    [
      String.pad_trailing(format_timestamp(first.timestamp), 13) <>
        String.pad_trailing("insert", 18) <>
        String.pad_trailing(inspect(display), 20) <>
        "(#{count} chars)"
    ]
  end

  defp format_group(%{kind: :operator_sequence, entries: entries}) do
    first = hd(entries)
    keys = Enum.map_join(entries, " ", fn e -> Bindings.format_key(e.key) end)
    last = List.last(entries)
    mode_note = if first.mode_before != last.mode_after, do: "→ #{last.mode_after}", else: ""

    [
      String.pad_trailing(format_timestamp(first.timestamp), 13) <>
        String.pad_trailing(to_string(first.mode_before), 18) <>
        String.pad_trailing(keys, 20) <>
        mode_note
    ]
  end

  defp format_group(%{entries: entries}) do
    Enum.map(entries, fn entry ->
      key_str = Bindings.format_key(entry.key)
      mode_note = if entry.mode_before != entry.mode_after, do: "→ #{entry.mode_after}", else: ""

      String.pad_trailing(format_timestamp(entry.timestamp), 13) <>
        String.pad_trailing(to_string(entry.mode_before), 18) <>
        String.pad_trailing(key_str, 20) <>
        mode_note
    end)
  end

  @spec format_insert_char({non_neg_integer(), non_neg_integer()}) :: String.t()
  defp format_insert_char({cp, _mods}) when cp >= 32 and cp < 127, do: <<cp::utf8>>
  defp format_insert_char({cp, _mods}) when cp > 127 and cp <= 0x10FFFF, do: <<cp::utf8>>
  defp format_insert_char(_key), do: "·"

  @spec format_timestamp(non_neg_integer()) :: String.t()
  defp format_timestamp(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1000)
    millis = rem(ms, 1000)

    case DateTime.from_unix(seconds) do
      {:ok, dt} ->
        pad2 = &String.pad_leading(Integer.to_string(&1), 2, "0")
        pad3 = &String.pad_leading(Integer.to_string(&1), 3, "0")
        "#{pad2.(dt.hour)}:#{pad2.(dt.minute)}:#{pad2.(dt.second)}.#{pad3.(millis)}"

      {:error, _} ->
        "??:??:??.???"
    end
  end

  defp format_timestamp(_ms), do: "??:??:??.???"

  # ── Special buffers ────────────────────────────────────────────────────────

  @spec default_help_options(keyword()) :: keyword()
  defp default_help_options(opts) do
    Keyword.put(opts, :filetype, Keyword.get(opts, :filetype) || :text)
  end

  @spec show_in_buffer(state(), String.t(), String.t(), keyword()) :: state()
  defp show_in_buffer(state, buffer_name, content, opts \\ [])

  defp show_in_buffer(state, "*Help*", content, opts) do
    {state, help_buf} = ensure_help_buffer(state)
    replace_help_content(help_buf, content)
    apply_help_options(help_buf, opts)

    state
    |> switch_to_buffer(help_buf)
    |> setup_highlight_or_defer()
  end

  defp show_in_buffer(state, buffer_name, content, opts) do
    {state, buffer} = ensure_named_buffer(state, buffer_name)
    replace_help_content(buffer, content)
    apply_help_options(buffer, opts)

    state
    |> switch_to_buffer(buffer)
    |> setup_highlight_or_defer()
  end

  @spec ensure_help_buffer(state()) :: {state(), pid()}
  defp ensure_help_buffer(%{workspace: %{buffers: %{help: buf}}} = state)
       when is_pid(buf) and buf != nil do
    Buffer.buffer_name(buf)
    {state, buf}
  catch
    :exit, _ -> start_help_buffer(state)
  end

  defp ensure_help_buffer(state) do
    start_help_buffer(state)
  end

  @spec ensure_named_buffer(state(), String.t()) :: {state(), pid()}
  defp ensure_named_buffer(state, buffer_name) do
    case find_buffer_by_name(state.workspace.buffers.list, buffer_name) do
      nil -> start_named_buffer(state, buffer_name)
      pid -> {state, pid}
    end
  end

  @spec find_buffer_by_name([pid()], String.t()) :: pid() | nil
  defp find_buffer_by_name(buffers, buffer_name) do
    Enum.find(buffers, &buffer_name_matches?(&1, buffer_name))
  end

  @spec buffer_name_matches?(pid(), String.t()) :: boolean()
  defp buffer_name_matches?(buffer, buffer_name) do
    Buffer.buffer_name(buffer) == buffer_name
  catch
    :exit, _ -> false
  end

  @spec start_help_buffer(state()) :: {state(), pid()}
  defp start_help_buffer(state) do
    {:ok, pid} = start_special_buffer(state, "*Help*")

    state =
      EditorState.update_workspace(state, fn ws ->
        WorkspaceState.set_buffers(ws, Buffers.set_help(ws.buffers, pid))
      end)

    {state, pid}
  end

  @spec start_named_buffer(state(), String.t()) :: {state(), pid()}
  defp start_named_buffer(state, buffer_name) do
    {:ok, pid} = start_special_buffer(state, buffer_name)
    {Commands.add_buffer(state, pid), pid}
  end

  @spec start_special_buffer(state(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp start_special_buffer(state, buffer_name) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {Minga.Buffer,
       content: "",
       buffer_name: buffer_name,
       read_only: true,
       unlisted: true,
       persistent: true,
       options_server: EditorState.options_server(state)}
    )
  end

  @spec switch_to_buffer(state(), pid()) :: state()
  defp switch_to_buffer(state, buffer) do
    idx = Enum.find_index(state.workspace.buffers.list, &(&1 == buffer))

    state =
      if idx do
        EditorState.switch_buffer(state, idx)
      else
        Commands.add_buffer(state, buffer)
      end

    EditorState.clear_status(state)
  end

  @spec replace_help_content(pid(), String.t()) :: :ok
  defp replace_help_content(buf, content) do
    :ok = Buffer.replace_generated_content(buf, content)
    Buffer.move_to(buf, {0, 0})
  end

  @spec apply_help_options(pid(), keyword()) :: :ok
  defp apply_help_options(buf, opts) do
    case Keyword.fetch(opts, :filetype) do
      {:ok, filetype} when is_atom(filetype) -> Buffer.set_filetype(buf, filetype)
      _ -> :ok
    end
  end

  @spec setup_highlight_or_defer(state()) :: state()
  defp setup_highlight_or_defer(%{backend: :headless} = state) do
    HighlightSync.setup_for_buffer(state)
  end

  defp setup_highlight_or_defer(state) do
    send(self(), :setup_highlight)
    state
  end

  # ── Command description ─────────────────────────────────────────────────────

  @spec describe_command_by_atom(state(), atom()) :: state()
  defp describe_command_by_atom(state, name) when is_atom(name) do
    case Command.lookup(name) do
      {:ok, cmd} ->
        keybind_map = build_reverse_keybind_map()
        content = format_describe_command(cmd, keybind_map)
        show_in_help_buffer(state, content)

      :error ->
        show_in_help_buffer(state, "Unknown command: #{name}\n")
    end
  end

  @spec describe_command_named(state(), String.t()) :: state()
  defp describe_command_named(state, raw_name) do
    normalized = raw_name |> String.trim() |> String.trim_leading(":")

    name =
      try do
        String.to_existing_atom(normalized)
      rescue
        ArgumentError -> nil
      end

    case name && Command.lookup(name) do
      {:ok, cmd} ->
        keybind_map = build_reverse_keybind_map()
        content = format_describe_command(cmd, keybind_map)
        show_in_help_buffer(state, content)

      _ ->
        show_in_help_buffer(state, "Unknown command: #{normalized}\n")
    end
  end

  @spec format_describe_command(Command.t(), %{atom() => [String.t()]}) :: String.t()
  def format_describe_command(%Command{} = cmd, keybind_map) do
    bindings = Map.get(keybind_map, cmd.name, [])

    keybinding_lines =
      case bindings do
        [] -> "none"
        multiple -> Enum.join(multiple, "\n             ")
      end

    scope_str = if cmd.scope, do: inspect(cmd.scope), else: "any"

    [
      "# Command: #{cmd.name}",
      "",
      "Command:     #{cmd.name}",
      "Description: #{cmd.description}",
      "Keybinding:  #{keybinding_lines}",
      "Scope:       #{scope_str}",
      ""
    ]
    |> Enum.join("\n")
  end

  @doc """
  Builds a reverse lookup map from command atoms to their key sequence strings.

  Merges leader bindings (prefixed with "SPC "), normal mode bindings,
  and filetype bindings (prefixed with "SPC m ") into a single map where
  each command maps to a list of all its bound key sequences.

  Reads from `Defaults` only; user overrides from `Keymap.Active` are not included.
  """
  @spec build_reverse_keybind_map() :: %{atom() => [String.t()]}
  def build_reverse_keybind_map do
    leader =
      Defaults.all_bindings()
      |> Enum.map(fn {keys, command, _desc} ->
        key_str = "SPC " <> Enum.map_join(keys, " ", &Bindings.format_key/1)
        {command, key_str}
      end)

    normal =
      Defaults.normal_bindings()
      |> Enum.map(fn {key, {command, _desc}} ->
        {command, Bindings.format_key(key)}
      end)

    filetype =
      Defaults.filetype_bindings()
      |> Enum.map(fn {_ft, keys, command, _desc} ->
        key_str = "SPC m " <> Enum.map_join(keys, " ", &Bindings.format_key/1)
        {command, key_str}
      end)

    (leader ++ normal ++ filetype)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {cmd, key_strs} -> {cmd, Enum.uniq(key_strs)} end)
  end

  # ── Shared helpers ─────────────────────────────────────────────────────────

  @spec format_describe_key(String.t(), atom(), String.t()) :: String.t()
  defp format_describe_key(key_str, command, description) do
    lines = [
      "Key:         #{key_str}",
      "Command:     #{command}",
      "Description: #{description}",
      ""
    ]

    Enum.join(lines, "\n")
  end

  @spec current_mode(state()) :: atom()
  defp current_mode(%{workspace: %{editing: %{mode: mode}}}) when is_atom(mode), do: mode
  defp current_mode(_state), do: :normal

  @spec current_filetype(state()) :: atom() | nil
  defp current_filetype(state) do
    case active_buffer(state) do
      nil -> nil
      buffer -> Buffer.filetype(buffer)
    end
  catch
    :exit, _ -> nil
  end

  @spec active_buffer(state()) :: pid() | nil
  defp active_buffer(%{workspace: %{buffers: %{active: buffer}}}) when is_pid(buffer), do: buffer
  defp active_buffer(_state), do: nil

  @spec ensure_trailing_newline(String.t()) :: String.t()
  defp ensure_trailing_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end
end
