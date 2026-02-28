defmodule Minga.Command.Parser do
  @moduledoc """
  Parser for Vim-style `:` command-line input.

  Converts a raw string (without the leading `:`) into a structured
  `t:parsed/0` value that the editor can act on.

  ## Supported commands

  | Input            | Result                         |
  |------------------|--------------------------------|
  | `w`              | `{:save, []}`                  |
  | `q`              | `{:quit, []}`                  |
  | `q!`             | `{:force_quit, []}`            |
  | `wq`             | `{:save_quit, []}`             |
  | `e <filename>`   | `{:edit, filename}`            |
  | `<number>`       | `{:goto_line, number}`         |
  | anything else    | `{:unknown, original_string}`  |
  """

  @typedoc """
  Structured result of parsing a command-line string.

  * `{:save, []}` — write the current buffer to disk (`:w`)
  * `{:quit, []}` — quit the editor (`:q`)
  * `{:force_quit, []}` — quit without saving (`:q!`)
  * `{:save_quit, []}` — save and quit (`:wq`)
  * `{:edit, filename}` — open a file (`:e filename`)
  * `{:goto_line, n}` — jump to line *n* (`:<number>`)
  * `{:unknown, raw}` — unrecognised command
  """
  @type parsed ::
          {:save, []}
          | {:quit, []}
          | {:force_quit, []}
          | {:save_quit, []}
          | {:edit, String.t()}
          | {:goto_line, pos_integer()}
          | {:set, atom()}
          | {:unknown, String.t()}

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
  defp do_parse("q"), do: {:quit, []}
  defp do_parse("q!"), do: {:force_quit, []}
  defp do_parse("wq"), do: {:save_quit, []}

  defp do_parse("set number"), do: {:set, :number}
  defp do_parse("set nu"), do: {:set, :number}
  defp do_parse("set nonumber"), do: {:set, :nonumber}
  defp do_parse("set nonu"), do: {:set, :nonumber}
  defp do_parse("set relativenumber"), do: {:set, :relativenumber}
  defp do_parse("set rnu"), do: {:set, :relativenumber}
  defp do_parse("set norelativenumber"), do: {:set, :norelativenumber}
  defp do_parse("set nornu"), do: {:set, :norelativenumber}

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
end
