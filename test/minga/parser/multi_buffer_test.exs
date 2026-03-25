defmodule Minga.Parser.MultiBufferTest do
  @moduledoc """
  Integration tests verifying that the parser can handle multiple buffers
  with different languages simultaneously. Each buffer maintains independent
  parse trees, source mirrors, and highlight spans.

  These tests start a real minga-parser process and send protocol commands
  with distinct buffer IDs.
  """
  use ExUnit.Case, async: false

  alias Minga.Frontend.Protocol
  alias Minga.Parser.Manager, as: ParserManager

  @moduletag :parser_integration
  @parser_path Path.join([File.cwd!(), "priv", "minga-parser"])

  setup do
    name = :"parser_multi_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = ParserManager.start_link(name: name, parser_path: @parser_path)
    ParserManager.subscribe(pid)
    # subscribe is a GenServer.call, so the port is already open when it returns.
    # Use :sys.get_state as a final sync barrier to ensure init completed.
    :sys.get_state(pid)
    {:ok, parser: pid}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp setup_buffer(parser, buffer_id, language, version, content) do
    ParserManager.send_commands(parser, [
      Protocol.encode_set_language(buffer_id, language),
      Protocol.encode_parse_buffer(buffer_id, version, content)
    ])

    receive_spans(buffer_id, version)
  end

  defp incremental_edit(parser, buffer_id, version, edits) do
    ParserManager.send_commands(parser, [
      Protocol.encode_edit_buffer(buffer_id, version, edits)
    ])

    receive_spans(buffer_id, version)
  end

  defp receive_spans(expected_buffer_id, expected_version) do
    receive_spans_loop(expected_buffer_id, expected_version, 3000)
  end

  defp receive_spans_loop(buffer_id, version, timeout) do
    receive do
      {:minga_highlight, {:highlight_spans, ^buffer_id, ^version, spans}} ->
        spans

      {:minga_highlight, {:highlight_names, ^buffer_id, _names}} ->
        receive_spans_loop(buffer_id, version, timeout)

      {:minga_highlight, {:highlight_spans, _other_bid, _other_ver, _spans}} ->
        receive_spans_loop(buffer_id, version, timeout)

      {:minga_highlight, _other} ->
        receive_spans_loop(buffer_id, version, timeout)
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

  describe "multiple buffers with different languages" do
    @tag timeout: 30_000
    test "two buffers with different languages produce independent highlights", ctx do
      parser = ctx.parser

      elixir_source = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      json_source = ~s({"key": "value", "num": 42}\n)

      # Parse buffer 1 as Elixir
      spans_elixir = setup_buffer(parser, 1, "elixir", 1, elixir_source)
      assert is_list(spans_elixir), "Expected Elixir spans, got: #{inspect(spans_elixir)}"
      assert spans_elixir != [], "Elixir source should produce highlight spans"

      # Parse buffer 2 as JSON
      spans_json = setup_buffer(parser, 2, "json", 1, json_source)
      assert is_list(spans_json), "Expected JSON spans, got: #{inspect(spans_json)}"
      assert spans_json != [], "JSON source should produce highlight spans"

      # Spans should be different (different languages, different source)
      refute spans_elixir == spans_json,
             "Elixir and JSON spans should differ"
    end

    @tag timeout: 30_000
    test "incremental edit on buffer A does not affect buffer B's spans", ctx do
      parser = ctx.parser

      elixir_source = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      json_source = ~s({"key": "value"}\n)

      # Parse both buffers
      _spans_elixir_v1 = setup_buffer(parser, 1, "elixir", 1, elixir_source)
      spans_json_v1 = setup_buffer(parser, 2, "json", 1, json_source)

      # Edit buffer 1 (Elixir): insert "!" after :ok
      insert_pos = byte_size("defmodule Foo do\n  def bar, do: :ok")
      edit = make_edit(insert_pos, insert_pos, insert_pos + 1, {1, 20}, {1, 20}, {1, 21}, "!")

      _spans_elixir_v2 = incremental_edit(parser, 1, 2, [edit])

      # Re-parse buffer 2 to get its current spans (should be unchanged)
      spans_json_v2 = setup_buffer(parser, 2, "json", 2, json_source)

      assert spans_json_v1 == spans_json_v2,
             "JSON buffer spans changed after editing Elixir buffer"
    end

    @tag timeout: 30_000
    test "close_buffer frees resources without affecting other buffers", ctx do
      parser = ctx.parser

      elixir_source = "defmodule A do\nend\n"
      json_source = ~s({"a": 1}\n)

      # Parse two buffers
      _spans1 = setup_buffer(parser, 1, "elixir", 1, elixir_source)
      spans2_v1 = setup_buffer(parser, 2, "json", 1, json_source)

      # Close buffer 1
      ParserManager.send_commands(parser, [Protocol.encode_close_buffer(1)])
      # send_commands is a cast; flush with :sys.get_state so the close is processed
      :sys.get_state(parser)

      # Buffer 2 should still work fine
      spans2_v2 = setup_buffer(parser, 2, "json", 2, json_source)

      assert spans2_v1 == spans2_v2,
             "Buffer 2 spans changed after closing buffer 1"
    end
  end
end
