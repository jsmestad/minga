defmodule Minga.Snippet do
  @moduledoc """
  Parses and manages LSP snippet syntax for completion tabstop navigation.

  Parses snippet strings like `"fn ${1:name}(${2:args}) do\\n  $0\\nend"`
  into a list of tabstops and static text segments. The editor inserts the
  expanded text and tracks tabstop positions for Tab/S-Tab navigation.

  ## Snippet Syntax (LSP spec subset)

  - `$1`, `$2`, ... — tabstop positions (cursor jumps here)
  - `${1:placeholder}` — tabstop with default text
  - `$0` — final cursor position after all tabstops visited
  - `\\t`, `\\n` — tab and newline escapes
  - `\\$`, `\\}`, `\\\\` — literal escape sequences
  """

  @enforce_keys [:text, :tabstops]
  defstruct [:text, :tabstops]

  @typedoc "A single tabstop: index, byte offset in expanded text, and placeholder length."
  @type tabstop :: %{
          index: non_neg_integer(),
          offset: non_neg_integer(),
          length: non_neg_integer(),
          placeholder: String.t()
        }

  @type t :: %__MODULE__{
          text: String.t(),
          tabstops: [tabstop()]
        }

  @doc """
  Parses a snippet string into expanded text and tabstop positions.

  Returns `{:ok, %Snippet{}}` if the string contains snippet syntax,
  or `:plain` if it's a plain text string with no tabstops.
  """
  @spec parse(String.t()) :: {:ok, t()} | :plain
  def parse(input) when is_binary(input) do
    case do_parse(input, [], [], 0) do
      {_text, []} ->
        :plain

      {text, tabstops} ->
        sorted = Enum.sort_by(tabstops, & &1.index)
        {:ok, %__MODULE__{text: text, tabstops: sorted}}
    end
  end

  # ── Parser ─────────────────────────────────────────────────────────────────

  @spec do_parse(String.t(), [String.t()], [tabstop()], non_neg_integer()) ::
          {String.t(), [tabstop()]}

  # End of input
  defp do_parse("", text_acc, stops, _offset) do
    {text_acc |> Enum.reverse() |> IO.iodata_to_binary(), stops}
  end

  # Escaped characters
  defp do_parse("\\$" <> rest, text_acc, stops, offset) do
    do_parse(rest, ["$" | text_acc], stops, offset + 1)
  end

  defp do_parse("\\}" <> rest, text_acc, stops, offset) do
    do_parse(rest, ["}" | text_acc], stops, offset + 1)
  end

  defp do_parse("\\\\" <> rest, text_acc, stops, offset) do
    do_parse(rest, ["\\" | text_acc], stops, offset + 1)
  end

  # Tabstop with placeholder: ${N:text}
  defp do_parse("${" <> rest, text_acc, stops, offset) do
    case parse_placeholder(rest) do
      {:ok, index, placeholder, remaining} ->
        stop = %{
          index: index,
          offset: offset,
          length: byte_size(placeholder),
          placeholder: placeholder
        }

        do_parse(
          remaining,
          [placeholder | text_acc],
          [stop | stops],
          offset + byte_size(placeholder)
        )

      :error ->
        do_parse(rest, ["${" | text_acc], stops, offset + 2)
    end
  end

  # Simple tabstop: $N
  defp do_parse("$" <> rest, text_acc, stops, offset) do
    case parse_tabstop_number(rest) do
      {:ok, index, remaining} ->
        stop = %{index: index, offset: offset, length: 0, placeholder: ""}
        do_parse(remaining, text_acc, [stop | stops], offset)

      :error ->
        do_parse(rest, ["$" | text_acc], stops, offset + 1)
    end
  end

  # Regular character
  defp do_parse(<<c::utf8, rest::binary>>, text_acc, stops, offset) do
    char = <<c::utf8>>
    do_parse(rest, [char | text_acc], stops, offset + byte_size(char))
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec parse_placeholder(String.t()) :: {:ok, non_neg_integer(), String.t(), String.t()} | :error
  defp parse_placeholder(input) do
    case Integer.parse(input) do
      {index, ":" <> rest} ->
        case find_closing_brace(rest, []) do
          {:ok, placeholder, remaining} -> {:ok, index, placeholder, remaining}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  @spec find_closing_brace(String.t(), [String.t()]) :: {:ok, String.t(), String.t()} | :error
  defp find_closing_brace("", _acc), do: :error
  defp find_closing_brace("\\}" <> rest, acc), do: find_closing_brace(rest, ["}" | acc])

  defp find_closing_brace("}" <> rest, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp find_closing_brace(<<c::utf8, rest::binary>>, acc) do
    find_closing_brace(rest, [<<c::utf8>> | acc])
  end

  @spec parse_tabstop_number(String.t()) :: {:ok, non_neg_integer(), String.t()} | :error
  defp parse_tabstop_number(input) do
    case Integer.parse(input) do
      {n, rest} when n >= 0 -> {:ok, n, rest}
      _ -> :error
    end
  end
end
