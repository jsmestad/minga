defmodule Minga.Test.Generators do
  @moduledoc """
  StreamData generators for property-based tests.

  Provides reusable generators for buffer content, cursor positions,
  protocol messages, and other domain types used across property tests.
  """

  use ExUnitProperties

  alias Minga.Buffer.Document

  # ── Buffer content generators ─────────────────────────────────────────────

  @doc "Generates a multi-line string suitable for buffer content."
  @spec buffer_content() :: StreamData.t(String.t())
  def buffer_content do
    gen all(
          line_count <- integer(1..20),
          lines <- list_of(line_text(), length: line_count)
        ) do
      Enum.join(lines, "\n")
    end
  end

  @doc "Generates a single line of text (ASCII, no newlines)."
  @spec line_text() :: StreamData.t(String.t())
  def line_text do
    gen all(
          len <- integer(0..80),
          chars <- list_of(member_of(printable_ascii_chars()), length: len)
        ) do
      List.to_string(chars)
    end
  end

  @doc "Generates a valid cursor position for the given document."
  @spec valid_position(Document.t()) :: StreamData.t(Document.position())
  def valid_position(doc) do
    content = Document.content(doc)
    lines = String.split(content, "\n")
    line_count = length(lines)

    gen all(
          line <- integer(0..max(line_count - 1, 0)),
          line_text = Enum.at(lines, line, ""),
          col <- integer(0..byte_size(line_text))
        ) do
      {line, col}
    end
  end

  @doc "Generates buffer content and a valid position within it."
  @spec content_and_position() :: StreamData.t({String.t(), Document.position()})
  def content_and_position do
    gen all(
          content <- buffer_content(),
          doc = Document.new(content),
          pos <- valid_position(doc)
        ) do
      {content, pos}
    end
  end

  # ── Protocol event generators ──────────────────────────────────────────────

  @doc "Generates a valid key_press event binary."
  @spec key_press_event() :: StreamData.t(binary())
  def key_press_event do
    gen all(
          codepoint <- integer(1..0x10FFFF),
          modifiers <- integer(0..15)
        ) do
      <<0x01, codepoint::32, modifiers::8>>
    end
  end

  @doc "Generates a valid resize event binary."
  @spec resize_event() :: StreamData.t(binary())
  def resize_event do
    gen all(
          width <- integer(1..500),
          height <- integer(1..200)
        ) do
      <<0x02, width::16, height::16>>
    end
  end

  @doc "Generates a valid ready event binary."
  @spec ready_event() :: StreamData.t(binary())
  def ready_event do
    gen all(
          width <- integer(1..500),
          height <- integer(1..200)
        ) do
      <<0x03, width::16, height::16>>
    end
  end

  @doc "Generates a valid mouse_event binary."
  @spec mouse_event() :: StreamData.t(binary())
  def mouse_event do
    gen all(
          row <- integer(0..200),
          col <- integer(0..500),
          button <- integer(0..5),
          modifiers <- integer(0..15),
          event_type <- integer(0..2),
          click_count <- integer(1..3)
        ) do
      <<0x04, row::16, col::16, button::8, modifiers::8, event_type::8, click_count::8>>
    end
  end

  @doc "Generates a valid paste_event binary."
  @spec paste_event() :: StreamData.t(binary())
  def paste_event do
    gen all(text <- string(:ascii, min_length: 0, max_length: 100)) do
      text_len = byte_size(text)
      <<0x06, text_len::16, text::binary>>
    end
  end

  # ── Line list generators (for Git.Diff) ─────────────────────────────────

  @doc "Generates a list of lines for diff testing."
  @spec line_list() :: StreamData.t([String.t()])
  def line_list do
    list_of(line_text(), min_length: 1, max_length: 30)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec printable_ascii_chars() :: [integer()]
  defp printable_ascii_chars do
    Enum.to_list(32..126)
  end
end
