defmodule Minga.Command.Parser do
  @moduledoc """
  Parser for Vim-style `:` command-line input.

  Converts a raw string (without the leading `:`) into a structured
  `t:parsed/0` value that the editor can act on.

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
  | `<number>`       | `{:goto_line, number}`         |
  | anything else    | `{:unknown, original_string}`  |
  """

  @typedoc """
  Structured result of parsing a command-line string.

  * `{:save, []}` — write the current buffer to disk (`:w`)
  * `{:force_save, []}` — force-write, skipping mtime check (`:w!`)
  * `{:quit, []}` — close current tab or quit if last tab (`:q`)
  * `{:force_quit, []}` — force close tab or quit without saving (`:q!`)
  * `{:quit_all, []}` — quit the entire editor (`:qa`)
  * `{:force_quit_all, []}` — force quit the entire editor (`:qa!`)
  * `{:save_quit, []}` — save and close tab, or save and quit if last tab (`:wq`)
  * `{:save_quit_all, []}` — save all buffers and quit (`:wqa`)
  * `{:edit, filename}` — open a file (`:e filename`)
  * `{:force_edit, []}` — reload current buffer from disk (`:e!`)
  * `{:new_buffer, []}` — create a new empty buffer (`:new` / `:enew`)
  * `{:goto_line, n}` — jump to line *n* (`:<number>`)
  * `{:substitute, pattern, replacement, flags}` — `:%s/old/new/flags`
  * `{:unknown, raw}` — unrecognised command
  """
  @type parsed ::
          {:save, []}
          | {:force_save, []}
          | {:quit, []}
          | {:force_quit, []}
          | {:quit_all, []}
          | {:force_quit_all, []}
          | {:save_quit, []}
          | {:save_quit_all, []}
          | {:edit, String.t()}
          | {:force_edit, []}
          | {:checktime, []}
          | {:new_buffer, []}
          | {:lsp_info, []}
          | {:extensions, []}
          | {:extension_update, []}
          | {:extension_update_all, []}
          | {:parser_restart, []}
          | {:agent_abort, []}
          | {:agent_new_session, []}
          | {:agent_set_provider, [String.t()]}
          | {:agent_set_model, [String.t()]}
          | {:agent_pick_model, []}
          | {:agent_cycle_model, []}
          | {:agent_cycle_thinking, []}
          | {:tool_install_named, [String.t()]}
          | {:tool_uninstall_named, [String.t()]}
          | {:tool_update_named, [String.t()]}
          | {:goto_line, pos_integer()}
          | {:set, atom()}
          | {:setglobal, atom()}
          | {:substitute, String.t(), String.t(), [substitute_flag()]}
          | {:unknown, String.t()}

  @typedoc "Flags for :%s substitution."
  @type substitute_flag :: :global | :confirm

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
    do_parse(trimmed)
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
  defp do_parse("agent-provider " <> provider), do: {:agent_set_provider, [String.trim(provider)]}
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
  defp do_parse("warnings"), do: {:view_warnings, []}
  defp do_parse("vsplit"), do: {:split_vertical, []}
  defp do_parse("vs"), do: {:split_vertical, []}
  defp do_parse("split"), do: {:split_horizontal, []}
  defp do_parse("sp"), do: {:split_horizontal, []}
  defp do_parse("close"), do: {:window_close, []}

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
end
