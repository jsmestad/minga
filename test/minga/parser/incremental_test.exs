defmodule Minga.Parser.IncrementalTest do
  @moduledoc """
  Integration tests verifying that incremental parsing via edit_buffer
  produces the same highlight spans as a full reparse via parse_buffer.

  These tests start a real minga-parser process and send actual protocol
  commands to it. They require the parser binary to be built.
  """

  use ExUnit.Case, async: true

  alias Minga.Parser.Manager, as: ParserManager
  alias Minga.Port.Protocol

  @moduletag :parser_integration
  @parser_path Path.join([File.cwd!(), "priv", "minga-parser"])

  setup do
    name = :"parser_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = ParserManager.start_link(name: name, parser_path: @parser_path)
    ParserManager.subscribe(pid)
    Process.sleep(50)
    {:ok, parser: pid}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp setup_elixir(parser) do
    ParserManager.send_commands(parser, [Protocol.encode_set_language("elixir")])
    Process.sleep(20)
  end

  defp full_parse(parser, version, content) do
    ParserManager.send_commands(parser, [Protocol.encode_parse_buffer(version, content)])
    receive_spans(version)
  end

  defp incremental_parse(parser, version, edits) do
    ParserManager.send_commands(parser, [Protocol.encode_edit_buffer(version, edits)])
    receive_spans(version)
  end

  defp receive_spans(expected_version) do
    receive_spans_loop(expected_version, 2000)
  end

  defp receive_spans_loop(version, timeout) do
    receive do
      {:minga_highlight, {:highlight_spans, ^version, spans}} ->
        spans

      {:minga_highlight, {:highlight_names, _names}} ->
        receive_spans_loop(version, timeout)

      {:minga_highlight, {:highlight_spans, _other_version, _spans}} ->
        receive_spans_loop(version, timeout)

      {:minga_highlight, _other} ->
        receive_spans_loop(version, timeout)
    after
      timeout -> {:error, :timeout}
    end
  end

  defp make_edit(
         start_byte,
         old_end_byte,
         new_end_byte,
         start_pos,
         old_end_pos,
         new_end_pos,
         text
       ) do
    %{
      start_byte: start_byte,
      old_end_byte: old_end_byte,
      new_end_byte: new_end_byte,
      start_position: start_pos,
      old_end_position: old_end_pos,
      new_end_position: new_end_pos,
      inserted_text: text
    }
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "incremental vs full reparse" do
    @tag timeout: 30_000
    test "single character insert produces same spans as full reparse", ctx do
      parser = ctx.parser
      original = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      edited = "defmodule Foo do\n  def bar, do: :ok!\nend\n"

      setup_elixir(parser)

      # Full parse of the edited content
      full_spans = full_parse(parser, 1, edited)
      assert is_list(full_spans), "Expected spans list, got: #{inspect(full_spans)}"

      # Parse original, then apply incremental edit
      full_parse(parser, 2, original)

      insert_pos = byte_size("defmodule Foo do\n  def bar, do: :ok")
      edit = make_edit(insert_pos, insert_pos, insert_pos + 1, {1, 20}, {1, 20}, {1, 21}, "!")

      incremental_spans = incremental_parse(parser, 3, [edit])
      assert is_list(incremental_spans), "Expected spans list, got: #{inspect(incremental_spans)}"

      assert full_spans == incremental_spans,
             "Incremental spans differ from full reparse.\nFull: #{inspect(full_spans)}\nIncremental: #{inspect(incremental_spans)}"
    end

    @tag timeout: 30_000
    test "deletion produces same spans as full reparse", ctx do
      parser = ctx.parser
      original = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      edited = "defmodule Foo do\n  def , do: :ok\nend\n"

      setup_elixir(parser)

      full_spans = full_parse(parser, 1, edited)
      assert is_list(full_spans)

      full_parse(parser, 2, original)

      del_start = byte_size("defmodule Foo do\n  def ")
      del_end = del_start + 3
      edit = make_edit(del_start, del_end, del_start, {1, 6}, {1, 9}, {1, 6}, "")

      incremental_spans = incremental_parse(parser, 3, [edit])
      assert is_list(incremental_spans)

      assert full_spans == incremental_spans,
             "Deletion: incremental spans differ from full reparse"
    end

    @tag timeout: 30_000
    test "replacement produces same spans as full reparse", ctx do
      parser = ctx.parser
      original = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      edited = "defmodule Foo do\n  def baz_qux, do: :ok\nend\n"

      setup_elixir(parser)

      full_spans = full_parse(parser, 1, edited)
      assert is_list(full_spans)

      full_parse(parser, 2, original)

      rep_start = byte_size("defmodule Foo do\n  def ")
      rep_end = rep_start + 3
      edit = make_edit(rep_start, rep_end, rep_start + 7, {1, 6}, {1, 9}, {1, 13}, "baz_qux")

      incremental_spans = incremental_parse(parser, 3, [edit])
      assert is_list(incremental_spans)

      assert full_spans == incremental_spans,
             "Replacement: incremental spans differ from full reparse"
    end

    @tag timeout: 60_000
    test "multiple sequential edits produce same spans as full reparse", ctx do
      parser = ctx.parser
      v0 = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      v2 = "defmodule Foo do\n  def bar, do: :ok!\n  def baz, do: :err\nend\n"

      setup_elixir(parser)

      # Full parse of final version
      full_spans = full_parse(parser, 1, v2)
      assert is_list(full_spans)

      # Incremental: parse v0, edit to v1, edit to v2
      full_parse(parser, 2, v0)

      # Edit 1: insert "!" at end of :ok
      insert1 = byte_size("defmodule Foo do\n  def bar, do: :ok")
      edit1 = make_edit(insert1, insert1, insert1 + 1, {1, 20}, {1, 20}, {1, 21}, "!")
      incremental_parse(parser, 3, [edit1])

      # Edit 2: insert new line before "end"
      insert2 = byte_size("defmodule Foo do\n  def bar, do: :ok!\n")
      new_line = "  def baz, do: :err\n"

      edit2 =
        make_edit(
          insert2,
          insert2,
          insert2 + byte_size(new_line),
          {2, 0},
          {2, 0},
          {3, 0},
          new_line
        )

      incremental_spans = incremental_parse(parser, 4, [edit2])
      assert is_list(incremental_spans)

      assert full_spans == incremental_spans,
             "Multi-edit: incremental spans differ from full reparse"
    end
  end
end
