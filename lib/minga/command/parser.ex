defmodule Minga.Command.Parser do
  @moduledoc """
  Parser for Vim-style `:` command-line input.

  Converts a raw string (without the leading `:`) into a structured
  `t:parsed/0` value that the editor can act on.

  Supports Vim-style range prefixes (1,10 | % | . | $ | '<,'>) on all commands.

  ## Supported commands

  | Input            | Result                         |
  |------------------|--------------------------------|
  | `w`              | `{:save, []}`                  |
  | `w!`             | `{:force_save, []}`            |
  | `q`              | `{:quit, []}`                  |
  | `q!`             | `{:force_quit, []}`            |
  | `qa`             | `{:quit_all, []}`              |
  | `qa!`            | `{:force_quit_all, []}`        |
  | `wq`             | `{:save_quit, []}`             |
  | `e <filename>`   | `{:edit, filename}`            |
  | `e!`             | `{:force_edit, []}`            |
  | `cq`             | `{:abort_quit, []}`             |
  | `<number>`       | `{:goto_line, number}`         |
  | `1,10s/x/y/`     | `{:substitute, range, ...}`    |
  | anything else    | `{:unknown, original_string}`  |
  """

  @typedoc """
  Range specification for ex commands.

  * `{:absolute, start_line, end_line}` — absolute line numbers (1-indexed)
  * `:whole_buffer` — entire buffer (%)
  * `:current_line` — current line (.)
  * `:last_line` — last line in buffer ($)
  * `{:visual}` — visual selection ('<,'>)
  """
  @type range ::
          {:absolute, pos_integer(), pos_integer()}
          | :whole_buffer
          | :current_line
          | :last_line
          | :visual

  @typedoc """
  Structured result of parsing a command-line string.

  * `{:save, []}` — write the current buffer to disk (`:w`)
  * `{:force_save, []}` — force-write, skipping mtime check (`:w!`)
  * `{:quit, []}` — close current tab or quit if last tab (`:q`)
  * `{:force_quit, []}` — force close tab or quit without saving (`:q!`)
  * `{:quit_all, []}` — quit the entire editor (`:qa`)
  * `{:force_quit_all, []}` — force quit the entire editor (`:qa!`)
  * `{:abort_quit, []}` — abort and quit with error exit code (`:cq` / `:cquit`)
  * `{:save_quit, []}` — save and close tab, or save and quit if last tab (`:wq`)
  * `{:save_quit_all, []}` — save all buffers and quit (`:wqa`)
  * `{:edit, filename}` — open a file (`:e filename`)
  * `{:force_edit, []}` — reload current buffer from disk (`:e!`)
  * `{:new_buffer, []}` — create a new empty buffer (`:new` / `:enew`)
  * `{:buffers, []}` — list open buffers (`:buffers` / `:ls`)
  * `{:buffer_next, []}` — move to next buffer (`:bnext` / `:bn`)
  * `{:buffer_prev, []}` — move to previous buffer (`:bprev` / `:bp`)
  * `{:goto_line, n}` — jump to line *n* (`:<number>`)
  * `{:substitute, pattern, replacement, flags}` — `:%s/old/new/flags`
  * `{:sort, range, flags}` — sort lines in range (`:sort` / `:%sort`)
  * `{:read, filename}` — read file into buffer at cursor (`:read` / `:r`)
  * `{:shell_command, command}` — run shell command and show output (`:!ls`)
  * `{:global, pattern, command}` — run ex command on matching lines (`:g/pat/cmd`)
  * `{:normal, range, keystrokes}` — execute normal mode keystrokes on a range of lines (`:normal`)
  * `{:unknown, raw}` — unrecognised command
  """
  @type parsed ::
          {:save, []}
          | {:force_save, []}
          | {:quit, []}
          | {:force_quit, []}
          | {:quit_all, []}
          | {:force_quit_all, []}
          | {:abort_quit, []}
          | {:save_quit, []}
          | {:save_quit_all, []}
          | {:edit, String.t()}
          | {:force_edit, []}
          | {:checktime, []}
          | {:new_buffer, []}
          | {:buffers, []}
          | {:buffer_next, []}
          | {:buffer_prev, []}
          | {:lsp_info, []}
          | {:lsp_restart, []}
          | {:lsp_stop, []}
          | {:lsp_start, []}
          | {:extensions, []}
          | {:extension_update, []}
          | {:extension_update_all, []}
          | {:parser_restart, []}
          | {:describe_command, []}
          | {:describe_command_named, [String.t()]}
          | {:describe_option, []}
          | {:describe_option_named, [String.t()]}
          | {:tutor, []}
          | {:agent_abort, []}
          | {:agent_new_session, []}
          | {:agent_clear_history, []}
          | {:agent_set_model, [String.t()]}
          | {:agent_pick_model, []}
          | {:agent_cycle_model, []}
          | {:agent_summarize, []}
          | {:agent_cycle_thinking, []}
          | {:tool_install_named, [String.t()]}
          | {:tool_uninstall_named, [String.t()]}
          | {:tool_update_named, [String.t()]}
          | {:tool_install, []}
          | {:tool_uninstall, []}
          | {:tool_update, []}
          | {:tool_list, []}
          | {:tool_manage, []}
          | {:view_warnings, []}
          | {:reload_highlights, []}
          | {:split_vertical, []}
          | {:split_horizontal, []}
          | {:window_close, []}
          | {:set_filetype, [String.t()]}
          | {:terminal, []}
          | {:goto_line, pos_integer()}
          | {:set, atom()}
          | {:setglobal, atom()}
          | {:substitute, String.t(), String.t(), [substitute_flag()]}
          | {:sort, range(), [sort_flag()]}
          | {:read, String.t()}
          | {:shell_command, String.t()}
          | {:global, String.t(), String.t()}
          | {:normal, range(), String.t()}
          | {:rename, String.t()}
          | {:dired, String.t() | nil}
          | {:unknown, String.t()}

  @typedoc "Flags for :%s substitution."
  @type substitute_flag :: :global | :confirm

  @typedoc "Flags for :sort command (reverse, numeric, unique)."
  @type sort_flag :: :reverse | :numeric | :unique

  @spec parse_range(String.t()) :: {range() | :no_range, String.t()}
  defp parse_range(input) do
    case input do
      "%" <> rest -> {:whole_buffer, rest}
      "." <> rest -> {:current_line, rest}
      "$" <> rest -> {:last_line, rest}
      "'<,'>'" <> rest -> {:visual, rest}
      input -> parse_numeric_range(input)
    end
  end

  @spec parse_numeric_range(String.t()) :: {range() | :no_range, String.t()}
  defp parse_numeric_range(input) do
    case Integer.parse(input) do
      {start, "," <> rest} ->
        case Integer.parse(rest) do
          {end_line, rest} when end_line > 0 and start > 0 ->
            {{:absolute, start, end_line}, rest}

          _ ->
            {:no_range, input}
        end

      {line, rest} when line > 0 ->
        {{:absolute, line, line}, rest}

      _ ->
        {:no_range, input}
    end
  end

  @doc """
  Parses a command-line string (without the leading `:`) and returns a
  `t:parsed/0` value.

  ## Examples

      iex> Minga.Command.Parser.parse("w")
      {:save, []}

      iex> Minga.Command.Parser.parse("q!")
      {:force_quit, []}

      iex> Minga.Command.Parser.parse("e README.md")
      {:edit, "README.md"}

      iex> Minga.Command.Parser.parse("42")
      {:goto_line, 42}

      iex> Minga.Command.Parser.parse("w!")
      {:force_save, []}

      iex> Minga.Command.Parser.parse("e!")
      {:force_edit, []}

      iex> Minga.Command.Parser.parse("xyz")
      {:unknown, "xyz"}
  """
  @spec parse(String.t()) :: parsed()
  def parse(input) when is_binary(input) do
    trimmed = String.trim(input)
    parse_with_range(trimmed)
  end

  @spec parse_with_range(String.t()) :: parsed()
  defp parse_with_range(input) do
    case parse_range(input) do
      {:no_range, _} ->
        do_parse(input)

      {range, rest} ->
        parse_after_range(range, input, rest)
    end
  end

  @spec parse_after_range(range(), String.t(), String.t()) :: parsed()
  defp parse_after_range(range, original, rest) do
    trimmed_rest = String.trim_leading(rest)

    if trimmed_rest == "" do
      do_parse(original)
    else
      apply_range_to_command(range, do_parse(trimmed_rest))
    end
  end

  @spec apply_range_to_command(range(), parsed()) :: parsed()
  defp apply_range_to_command(range, {:sort, :whole_buffer, flags}) do
    {:sort, range, flags}
  end

  defp apply_range_to_command(range, {:normal, :whole_buffer, keys}) do
    {:normal, range, keys}
  end

  defp apply_range_to_command(_range, other) do
    other
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec do_parse(String.t()) :: parsed()
  defp do_parse("w"), do: {:save, []}
  defp do_parse("w!"), do: {:force_save, []}
  defp do_parse("q"), do: {:quit, []}
  defp do_parse("q!"), do: {:force_quit, []}
  defp do_parse("qa"), do: {:quit_all, []}
  defp do_parse("qa!"), do: {:force_quit_all, []}
  defp do_parse("qall"), do: {:quit_all, []}
  defp do_parse("qall!"), do: {:force_quit_all, []}
  defp do_parse("cq"), do: {:abort_quit, []}
  defp do_parse("cq!"), do: {:abort_quit, []}
  defp do_parse("cquit"), do: {:abort_quit, []}
  defp do_parse("cquit!"), do: {:abort_quit, []}
  defp do_parse("wq"), do: {:save_quit, []}
  defp do_parse("wqa"), do: {:save_quit_all, []}
  defp do_parse("wqall"), do: {:save_quit_all, []}
  defp do_parse("e!"), do: {:force_edit, []}
  defp do_parse("checktime"), do: {:checktime, []}
  defp do_parse("new"), do: {:new_buffer, []}
  defp do_parse("enew"), do: {:new_buffer, []}
  defp do_parse("reload-highlights"), do: {:reload_highlights, []}
  defp do_parse("rh"), do: {:reload_highlights, []}
  defp do_parse("LspInfo"), do: {:lsp_info, []}
  defp do_parse("lspinfo"), do: {:lsp_info, []}
  defp do_parse("LspRestart"), do: {:lsp_restart, []}
  defp do_parse("lsprestart"), do: {:lsp_restart, []}
  defp do_parse("LspStop"), do: {:lsp_stop, []}
  defp do_parse("lspstop"), do: {:lsp_stop, []}
  defp do_parse("LspStart"), do: {:lsp_start, []}
  defp do_parse("lspstart"), do: {:lsp_start, []}
  defp do_parse("extensions"), do: {:extensions, []}
  defp do_parse("ext"), do: {:extensions, []}
  defp do_parse("ExtUpdate"), do: {:extension_update, []}
  defp do_parse("ExtUpdateAll"), do: {:extension_update_all, []}
  defp do_parse("parser-restart"), do: {:parser_restart, []}
  defp do_parse("ParserRestart"), do: {:parser_restart, []}
  defp do_parse("agent-stop"), do: {:agent_abort, []}
  defp do_parse("agent-new"), do: {:agent_new_session, []}
  defp do_parse("agent-clear-history"), do: {:agent_clear_history, []}
  defp do_parse("agent-model " <> model), do: {:agent_set_model, [String.trim(model)]}
  defp do_parse("agent-models"), do: {:agent_pick_model, []}
  defp do_parse("agent-cycle-model"), do: {:agent_cycle_model, []}
  defp do_parse("agent-summarize"), do: {:agent_summarize, []}
  defp do_parse("agent-thinking"), do: {:agent_cycle_thinking, []}
  defp do_parse("ToolInstall " <> name), do: {:tool_install_named, [String.trim(name)]}
  defp do_parse("ToolUninstall " <> name), do: {:tool_uninstall_named, [String.trim(name)]}
  defp do_parse("ToolUpdate " <> name), do: {:tool_update_named, [String.trim(name)]}
  defp do_parse("ToolInstall"), do: {:tool_install, []}
  defp do_parse("ToolUninstall"), do: {:tool_uninstall, []}
  defp do_parse("ToolUpdate"), do: {:tool_update, []}
  defp do_parse("ToolList"), do: {:tool_list, []}
  defp do_parse("ToolManage"), do: {:tool_manage, []}
  defp do_parse("terminal"), do: {:terminal, []}
  defp do_parse("warnings"), do: {:view_warnings, []}
  defp do_parse("describe-command"), do: {:describe_command, []}
  defp do_parse("describe-command " <> name), do: {:describe_command_named, [String.trim(name)]}
  defp do_parse("describe"), do: {:describe_option, []}
  defp do_parse("describe " <> name), do: {:describe_option_named, [String.trim(name)]}
  defp do_parse("vsplit"), do: {:split_vertical, []}
  defp do_parse("vs"), do: {:split_vertical, []}
  defp do_parse("split"), do: {:split_horizontal, []}
  defp do_parse("sp"), do: {:split_horizontal, []}
  defp do_parse("close"), do: {:window_close, []}
  defp do_parse("rename " <> name), do: {:rename, String.trim(name)}
  defp do_parse("Tutor"), do: {:tutor, []}
  defp do_parse("tutor"), do: {:tutor, []}
  defp do_parse("buffers"), do: {:buffers, []}
  defp do_parse("ls"), do: {:buffers, []}
  defp do_parse("bnext"), do: {:buffer_next, []}
  defp do_parse("bn"), do: {:buffer_next, []}
  defp do_parse("bprev"), do: {:buffer_prev, []}
  defp do_parse("bp"), do: {:buffer_prev, []}

  defp do_parse("sort"), do: {:sort, :whole_buffer, []}

  defp do_parse("sort " <> rest) do
    flags = parse_sort_flags(String.trim(rest))
    {:sort, :whole_buffer, flags}
  end

  defp do_parse("read " <> rest) do
    filename = String.trim(rest)

    if filename == "" do
      {:unknown, "read"}
    else
      {:read, filename}
    end
  end

  defp do_parse("r " <> rest) do
    filename = String.trim(rest)

    if filename == "" do
      {:unknown, "r"}
    else
      {:read, filename}
    end
  end

  defp do_parse("!" <> command) do
    {:shell_command, String.trim(command)}
  end

  defp do_parse("g" <> rest) do
    case rest do
      "/" <> rest ->
        parse_global_command(rest)

      _ ->
        {:unknown, "g" <> rest}
    end
  end

  defp do_parse("normal " <> keys) do
    trimmed = String.trim(keys)

    if trimmed == "" do
      {:unknown, "normal"}
    else
      {:normal, :whole_buffer, trimmed}
    end
  end

  defp do_parse("norm " <> keys) do
    trimmed = String.trim(keys)

    if trimmed == "" do
      {:unknown, "norm"}
    else
      {:normal, :whole_buffer, trimmed}
    end
  end

  defp do_parse("set number"), do: {:set, :number}
  defp do_parse("set nu"), do: {:set, :number}
  defp do_parse("set nonumber"), do: {:set, :nonumber}
  defp do_parse("set nonu"), do: {:set, :nonumber}
  defp do_parse("set relativenumber"), do: {:set, :relativenumber}
  defp do_parse("set rnu"), do: {:set, :relativenumber}
  defp do_parse("set norelativenumber"), do: {:set, :norelativenumber}
  defp do_parse("set nornu"), do: {:set, :norelativenumber}
  defp do_parse("set wrap"), do: {:set, :wrap}
  defp do_parse("set nowrap"), do: {:set, :nowrap}

  defp do_parse("set ft=" <> name), do: {:set_filetype, [String.trim(name)]}
  defp do_parse("set filetype=" <> name), do: {:set_filetype, [String.trim(name)]}
  defp do_parse("setf " <> name), do: {:set_filetype, [String.trim(name)]}
  defp do_parse("setfiletype " <> name), do: {:set_filetype, [String.trim(name)]}

  defp do_parse("setglobal number"), do: {:setglobal, :number}
  defp do_parse("setglobal nu"), do: {:setglobal, :number}
  defp do_parse("setglobal nonumber"), do: {:setglobal, :nonumber}
  defp do_parse("setglobal nonu"), do: {:setglobal, :nonumber}
  defp do_parse("setglobal relativenumber"), do: {:setglobal, :relativenumber}
  defp do_parse("setglobal rnu"), do: {:setglobal, :relativenumber}
  defp do_parse("setglobal norelativenumber"), do: {:setglobal, :norelativenumber}
  defp do_parse("setglobal nornu"), do: {:setglobal, :norelativenumber}
  defp do_parse("setglobal wrap"), do: {:setglobal, :wrap}
  defp do_parse("setglobal nowrap"), do: {:setglobal, :nowrap}

  defp do_parse("%s" <> rest), do: parse_substitute(rest)
  defp do_parse("s" <> rest), do: parse_substitute(rest)

  defp do_parse("dired"), do: {:dired, nil}
  defp do_parse("oil"), do: {:dired, nil}

  defp do_parse("dired " <> rest) do
    path = String.trim(rest)
    if path == "", do: {:dired, nil}, else: {:dired, path}
  end

  defp do_parse("oil " <> rest) do
    path = String.trim(rest)
    if path == "", do: {:dired, nil}, else: {:dired, path}
  end

  defp do_parse("e " <> rest) do
    filename = String.trim(rest)

    if filename == "" do
      {:unknown, "e"}
    else
      {:edit, filename}
    end
  end

  defp do_parse(input) do
    case Integer.parse(input) do
      {n, ""} when n > 0 -> {:goto_line, n}
      _ -> {:unknown, input}
    end
  end

  # Parses the substitution part after `s` or `%s`.
  # Expects `/pattern/replacement/flags` with `/` as delimiter.
  @spec parse_substitute(String.t()) :: parsed()
  defp parse_substitute(rest) do
    case rest do
      <<delimiter, tail::binary>> when delimiter in [?/, ?#, ?|] ->
        parse_substitute_parts(tail, <<delimiter>>, [])

      _ ->
        {:unknown, "s" <> rest}
    end
  end

  # First call: split out the pattern.
  @spec parse_substitute_parts(String.t(), String.t(), [String.t()]) :: parsed()
  defp parse_substitute_parts(input, delimiter, []) do
    case split_on_unescaped(input, delimiter) do
      {pattern, rest} ->
        parse_substitute_parts(rest, delimiter, [pattern])

      :no_match ->
        {:unknown, "s" <> delimiter <> input}
    end
  end

  # Second call: split out the replacement.
  defp parse_substitute_parts(input, delimiter, [pattern]) do
    case split_on_unescaped(input, delimiter) do
      {replacement, rest} ->
        {:substitute, pattern, replacement, parse_substitute_flags(rest)}

      :no_match ->
        # No trailing delimiter — remainder is the replacement, no flags.
        {:substitute, pattern, input, []}
    end
  end

  @spec split_on_unescaped(String.t(), String.t()) :: {String.t(), String.t()} | :no_match
  defp split_on_unescaped(input, delimiter) do
    do_split_unescaped(input, delimiter, [])
  end

  @spec do_split_unescaped(String.t(), String.t(), [String.t()]) ::
          {String.t(), String.t()} | :no_match
  defp do_split_unescaped("", _delimiter, _acc), do: :no_match

  defp do_split_unescaped("\\" <> <<c::utf8, rest::binary>>, delimiter, acc) do
    do_split_unescaped(rest, delimiter, [<<c::utf8>>, "\\" | acc])
  end

  defp do_split_unescaped(<<c::utf8, rest::binary>>, delimiter, acc) do
    if <<c::utf8>> == delimiter do
      {acc |> Enum.reverse() |> Enum.join(), rest}
    else
      do_split_unescaped(rest, delimiter, [<<c::utf8>> | acc])
    end
  end

  @spec parse_substitute_flags(String.t()) :: [substitute_flag()]
  defp parse_substitute_flags(flags_str) do
    flags_str
    |> String.graphemes()
    |> Enum.flat_map(fn
      "g" -> [:global]
      "c" -> [:confirm]
      _ -> []
    end)
    |> Enum.uniq()
  end

  @spec parse_sort_flags(String.t()) :: [sort_flag()]
  defp parse_sort_flags(flags_str) do
    flags_str
    |> String.graphemes()
    |> Enum.flat_map(fn
      "r" -> [:reverse]
      "n" -> [:numeric]
      "u" -> [:unique]
      _ -> []
    end)
    |> Enum.uniq()
  end

  @spec parse_global_command(String.t()) :: parsed()
  defp parse_global_command(input) do
    case split_on_unescaped(input, "/") do
      {pattern, rest} ->
        {:global, pattern, rest}

      :no_match ->
        {:unknown, "g/" <> input}
    end
  end
end
