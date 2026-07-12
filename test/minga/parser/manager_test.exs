defmodule Minga.Parser.ManagerTest do
  # Spawns the real Zig parser Port, so this test must not run concurrently with other OS-process tests.
  use ExUnit.Case, async: false

  @moduletag :heavy
  @moduletag timeout: 10_000

  alias Minga.Parser.BufferConfig
  alias Minga.Parser.Manager
  alias Minga.Parser.Protocol

  describe "document_symbols" do
    test "parser publishes symbols from built-in tags query after parse" do
      server = start_parser_manager()
      content = "defmodule Foo do\n  def bar do\n    :ok\n  end\nend\n"

      :ok = Manager.subscribe(server)
      buffer = setup_buffer(server, content)
      _indent = Manager.request_indent(buffer, 1, server)

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer, _correlation, {:document_symbols, symbols}}},
                     2_000

      assert Enum.any?(symbols, &match?(%Minga.Language.Symbol{kind: :module, name: "Foo"}, &1))
      assert Enum.any?(symbols, &match?(%Minga.Language.Symbol{kind: :function, name: "bar"}, &1))
    end

    test "parser publishes updated symbols after edit_buffer" do
      server = start_parser_manager()
      content = "defmodule Foo do\n  def foo do\n    :ok\n  end\nend\n"

      :ok = Manager.subscribe(server)
      buffer = setup_buffer(server, content)

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer, _correlation, {:document_symbols, initial_symbols}}},
                     2_000

      assert Enum.any?(
               initial_symbols,
               &match?(%Minga.Language.Symbol{kind: :function, name: "foo"}, &1)
             )

      :ok = Minga.Buffer.apply_edit(buffer, 1, 6, 1, 8, "bar")

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer, _correlation, {:document_symbols, edited_symbols}}},
                     2_000

      assert Enum.any?(
               edited_symbols,
               &match?(%Minga.Language.Symbol{kind: :function, name: "bar"}, &1)
             )

      refute Enum.any?(
               edited_symbols,
               &match?(%Minga.Language.Symbol{kind: :function, name: "foo"}, &1)
             )
    end
  end

  describe "request_indent/3" do
    test "returns nil without waiting when the parser port is unavailable" do
      server = start_parser_manager(parser_path: "/missing/minga-parser")

      buffer = start_supervised!({Minga.Buffer, content: "", filetype: :elixir})
      assert Manager.request_indent(buffer, 0, server) == nil
    end

    test "returns tree-sitter indent levels from the parser" do
      server = start_parser_manager()
      content = "def foo do\nif bar do\nbaz\nend\nend"
      buffer = setup_buffer_ready(server, "elixir", content)

      assert Manager.request_indent(buffer, 2, server) == 2
      assert Manager.request_indent(buffer, 3, server) == 1
    end

    test "returns first-enter indentation after the newline is present in a complete block" do
      server = start_parser_manager()
      content = "def foo do\n\nend"
      buffer = setup_buffer_ready(server, "elixir", content)

      assert Manager.request_indent(buffer, 1, server) == 1
    end
  end

  describe "sequence-fenced requests" do
    test "an immediate query observes the buffer edit that completed before the call" do
      server = start_parser_manager()
      buffer = setup_buffer_ready(server, "elixir", "def foo do\nvalue\nend\n")

      :ok = Minga.Buffer.apply_edit(buffer, 1, 0, 1, 0, "if true do\n")

      assert Manager.request_indent(buffer, 2, server) == 2
    end
  end

  describe "request_structural_nav/5" do
    test "returns nil without waiting when the parser port is unavailable" do
      server = start_parser_manager(parser_path: "/missing/minga-parser")

      buffer = start_supervised!({Minga.Buffer, content: "", filetype: :elixir})
      assert Manager.request_structural_nav(buffer, 0, 0, 0, server) == nil
    end

    test "returns target node ranges and type names from the parser" do
      server = start_parser_manager()
      content = "function add(a, b) {\n  return a + b;\n}\n"
      buffer = setup_buffer_ready(server, "javascript", content)

      parent = Manager.request_structural_nav(buffer, 0, 20, 0, server)
      first_child = Manager.request_structural_nav(buffer, 0, 0, 1, server)
      next_sibling = Manager.request_structural_nav(buffer, 0, 13, 2, server)
      prev_sibling = Manager.request_structural_nav(buffer, 0, 16, 3, server)

      assert parent.start_row == 0
      assert parent.start_col == 0
      assert parent.type_name == "function_declaration"
      assert first_child.start_col == 9
      assert first_child.type_name == "identifier"
      assert next_sibling.start_col == 16
      assert next_sibling.type_name == "identifier"
      assert prev_sibling.start_col == 13
      assert prev_sibling.type_name == "identifier"
    end
  end

  describe "editor buffer recovery" do
    test "global admission completes one registered buffer before starting the next" do
      server = start_parser_manager()
      :ok = Manager.subscribe(server)
      first = setup_buffer(server, "defmodule First do\nend\n")
      second = setup_buffer(server, "defmodule Second do\nend\n")

      assert_receive {:minga_highlight,
                      {:buffer_event, ^first, _correlation, {:highlight_spans, _spans}}},
                     2_000

      refute_received {:minga_highlight,
                       {:buffer_event, ^second, _correlation, {:highlight_names, _names}}}

      assert_receive {:minga_highlight,
                      {:buffer_event, ^second, _correlation, {:highlight_spans, _spans}}},
                     2_000
    end

    test "parser-side parse failure emits completion and leaves the registration pumpable" do
      server = start_parser_manager()
      :ok = Manager.subscribe(server)
      buffer = start_supervised!({Minga.Buffer, content: "content", filetype: :elixir})

      _id =
        Manager.register_buffer(buffer, %BufferConfig{language: "missing-language"},
          server: server
        )

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer, _correlation, {:highlight_spans, []}}},
                     2_000

      assert :ok = Manager.request_parse(buffer, server)

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer, _correlation, {:highlight_spans, []}}},
                     2_000
    end

    test "parser-requested recovery autonomously forces a fresh full parse" do
      server = start_parser_manager()
      content = "defmodule Recovery do\nend\n"
      :ok = Manager.subscribe(server)
      buffer = setup_buffer(server, content)
      buffer_id = Manager.buffer_id(buffer, server)

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer, _correlation, {:highlight_spans, _initial_spans}}},
                     2_000

      invalid_edit = %{
        start_byte: 10_000,
        old_end_byte: 10_001,
        new_end_byte: 10_001,
        start_position: {999, 0},
        old_end_position: {999, 1},
        new_end_position: {999, 1},
        inserted_text: "x"
      }

      Manager.send_commands(server, [
        Protocol.encode_edit_buffer(buffer_id, 2, [invalid_edit])
      ])

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer, _correlation, {:highlight_spans, _recovered_spans}}},
                     2_000

      refute_receive {:minga_highlight, {:request_reparse, ^buffer}}, 100
    end

    test "restart preserves parser identity and rebuilds registered buffers" do
      server = start_parser_manager()
      content = "defmodule Recovered do\nend\n"
      buffer = start_supervised!({Minga.Buffer, content: content, filetype: :elixir})

      buffer_id =
        Manager.register_buffer(buffer, %BufferConfig{language: "elixir"}, server: server)

      :ok = Manager.subscribe(server)

      assert :ok = Manager.restart(server)
      assert Manager.buffer_id(buffer, server) == buffer_id
      assert Manager.resolve_buffer(buffer_id, server) == buffer
      assert_receive {:minga_highlight, :parser_restarted}, 2_000

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer, _correlation, {:highlight_names, _names}}},
                     2_000

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer, _correlation, {:highlight_spans, _spans}}},
                     2_000
    end
  end

  describe "frame and admission isolation" do
    test "a source snapshot above 64 KiB parses and leaves another buffer usable" do
      server = start_parser_manager()
      :ok = Manager.subscribe(server)

      # Exercise Port framing rather than highlighter throughput: one JSON string
      # crosses 64 KiB while producing a single syntax node and capture span.
      large_source = "\"" <> String.duplicate("x", 70_000) <> "\""

      large = setup_buffer(server, "json", large_source)
      healthy = setup_buffer(server, "defmodule Healthy do\nend\n")

      assert byte_size(large_source) > 65_536

      assert_receive {:minga_highlight,
                      {:buffer_event, ^large, _correlation, {:highlight_spans, _spans}}},
                     4_000

      assert_receive {:minga_highlight,
                      {:buffer_event, ^healthy, _correlation, {:highlight_spans, _spans}}},
                     2_000

      assert is_integer(Manager.request_indent(healthy, 1, server))
    end

    test "a stalled snapshot drops only that buffer and continues queued work" do
      server = start_parser_manager()
      :ok = Manager.subscribe(server)

      stalled =
        start_supervised!(
          {Task, fn -> stalled_snapshot_provider() end},
          id: {:stalled_snapshot, System.unique_integer([:positive])}
        )

      _stalled_id =
        Manager.register_buffer(stalled, %BufferConfig{language: "elixir"}, server: server)

      healthy = setup_buffer(server, "defmodule HealthyAfterTimeout do\nend\n")
      scheduler = :sys.get_state(server).parse_scheduler
      token = scheduler.timeout_token
      send(server, {:parse_admission_timeout, stalled, token})

      assert_receive {:minga_highlight,
                      {:buffer_event, ^healthy, _correlation, {:highlight_spans, _spans}}},
                     2_000

      assert Manager.buffer_id(stalled, server) == nil
      assert Manager.available?(server)
      refute_received {:minga_highlight, :parser_crashed}
    end
  end

  describe "highlight_source/3 grammar aliasing" do
    # Generous timeout: the parser lazily loads each grammar on first use, so a
    # cold-start request can exceed the 50ms default. These tests verify alias
    # resolution, not latency.
    @highlight_timeout 2_000

    test "a short alias label like \"js\" highlights via the real parser" do
      server = start_parser_manager()
      source = "const answer = 42;\n"

      # "js" is not a registered grammar name; it must resolve to "javascript".
      assert {:ok, names, spans} =
               Manager.highlight_source("js", source, server: server, timeout: @highlight_timeout)

      assert is_list(names)
      assert spans != []
    end

    test ~S("sh" and "c++" aliases highlight via the real parser) do
      server = start_parser_manager()

      assert {:ok, _names, sh_spans} =
               Manager.highlight_source("sh", "echo hello\n",
                 server: server,
                 timeout: @highlight_timeout
               )

      assert sh_spans != []

      assert {:ok, _names, cpp_spans} =
               Manager.highlight_source("c++", "int x = 42;\n",
                 server: server,
                 timeout: @highlight_timeout
               )

      assert cpp_spans != []
    end

    test "canonical labels still highlight" do
      server = start_parser_manager()

      assert {:ok, _names, spans} =
               Manager.highlight_source("javascript", "const x = 1;\n",
                 server: server,
                 timeout: @highlight_timeout
               )

      assert spans != []
    end
  end

  describe "config-document key highlighting" do
    test "captures YAML mapping keys as @property" do
      server = start_parser_manager()
      # A mapping key, a quoted value, and a comment.
      content = "name: \"minga\" # editor\n"

      :ok = Manager.subscribe(server)
      buffer = setup_buffer(server, "yaml", content)

      captures = receive_captures(server, buffer, content)

      # The mapping key resolves to the standard @property capture, matching
      # nvim-treesitter's convention for config/document keys.
      assert {"property", "name"} in captures
      refute Enum.any?(captures, &match?({"property.yaml", _}, &1))

      # And the quoted value still resolves through the string face.
      assert {"string", "\"minga\""} in captures
    end

    test "captures Rust struct field access as @variable.member, not @property" do
      server = start_parser_manager()
      # `cfg.name` is code field access; it should not collide with config keys.
      content = "fn f(cfg: Config) { let _ = cfg.name; }\n"

      :ok = Manager.subscribe(server)
      buffer = setup_buffer(server, "rust", content)

      captures = receive_captures(server, buffer, content)

      # Code field access uses @variable.member (matches nvim-treesitter), so it
      # stays distinct from config-document keys that now own @property.
      assert {"variable.member", "name"} in captures
      refute {"property", "name"} in captures
    end
  end

  # Waits for the highlight broadcast for `buffer` and returns a list of
  # `{capture_name, captured_text}` tuples for the parsed `content`.
  defp receive_captures(_server, buffer, content) do
    assert_receive {:minga_highlight,
                    {:buffer_event, ^buffer, _correlation, {:highlight_names, names}}},
                   2_000

    assert_receive {:minga_highlight,
                    {:buffer_event, ^buffer, _correlation, {:highlight_spans, spans}}},
                   2_000

    names = List.to_tuple(names)

    Enum.map(spans, fn span ->
      name = elem(names, span.capture_id)
      text = binary_part(content, span.start_byte, span.end_byte - span.start_byte)
      {name, text}
    end)
  end

  defp setup_buffer(server, content) do
    setup_buffer(server, "elixir", content)
  end

  defp setup_buffer_ready(server, language, content) do
    :ok = Manager.subscribe(server)
    buffer = setup_buffer(server, language, content)

    assert_receive {:minga_highlight,
                    {:buffer_event, ^buffer, _correlation, {:highlight_spans, _spans}}},
                   2_000

    buffer
  end

  defp setup_buffer(server, language, content) do
    filetype = if language == "markdown", do: :markdown, else: :elixir

    buffer =
      start_supervised!(
        {Minga.Buffer, content: content, filetype: filetype},
        id: {:parser_test_buffer, System.unique_integer([:positive])}
      )

    _buffer_id =
      Manager.register_buffer(buffer, %BufferConfig{language: language}, server: server)

    buffer
  end

  defp stalled_snapshot_provider do
    receive do
      _message -> stalled_snapshot_provider()
    end
  end

  defp start_parser_manager(opts \\ []) do
    parser_path = Keyword.get(opts, :parser_path, parser_path())
    name = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
    start_supervised!({Manager, name: name, parser_path: parser_path})
    name
  end

  defp parser_path do
    Path.expand("../../../zig/zig-out/bin/minga-parser", __DIR__)
  end
end
