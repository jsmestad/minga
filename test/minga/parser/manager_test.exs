defmodule Minga.Parser.ManagerTest do
  # Opens native parser and cat Ports; keep these tests serialized with other OS-process tests.
  use ExUnit.Case, async: false

  @moduletag :heavy
  @moduletag timeout: 20_000

  alias Minga.Buffer.SyncSnapshot
  alias Minga.Parser.BufferConfig
  alias Minga.Parser.EventCorrelation
  alias Minga.Parser.Manager
  alias Minga.Parser.PortLifecycle
  alias Minga.Parser.PortState
  alias Minga.Parser.Protocol
  alias Minga.Protocol.Opcodes

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

  # Highlights go first so they reach the screen early; parse_complete is the last message of every parse, so the
  # editor has the parse's fold ranges, conceals and symbols when it learns the parse is done (#4314).
  describe "parse completion" do
    test "a full parse sends spans first, then its fold ranges and symbols, and parse_complete last" do
      server = start_parser_manager()
      :ok = Manager.subscribe(server)
      buffer = setup_buffer(server, "defmodule Foo do\n  def bar do\n    :ok\n  end\nend\n")

      kinds = parse_results(buffer)
      assert hd(kinds) in [:highlight_names, :highlight_spans]
      assert :fold_ranges in kinds
      assert :document_symbols in kinds

      assert Enum.find_index(kinds, &(&1 == :highlight_spans)) <
               Enum.find_index(kinds, &(&1 == :fold_ranges))
    end

    test "an edit's parse ends with parse_complete after its fold ranges" do
      server = start_parser_manager()
      :ok = Manager.subscribe(server)
      buffer = setup_buffer(server, "defmodule Foo do\n  def foo do\n    :ok\n  end\nend\n")
      _first = parse_results(buffer)

      :ok = Minga.Buffer.apply_edit(buffer, 1, 6, 1, 8, "bar")

      assert :fold_ranges in parse_results(buffer)
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
    test "only one buffer is admitted while waiting for a snapshot or parse completion" do
      # cat accepts writes without completing a parse, so the test advances each phase.
      server = start_parser_manager(parser_path: System.find_executable("cat"))
      :ok = Manager.subscribe(server)
      first = start_snapshot_provider()
      second = self()
      config = %BufferConfig{language: "elixir"}

      %EventCorrelation{generation: generation} =
        Manager.register_buffer_correlated(first, config, server: server)

      first_id = Manager.buffer_id(first, server)
      assert_receive {:snapshot_requested, ^first, :full, manager, first_token}, 2_000

      second_id = Manager.register_buffer(second, config, server: server)
      refute_received {:request_sync_snapshot, _, ^manager, _}

      send_snapshot(manager, first, first_token, "defmodule First do\nend\n")
      %{port: %{handle: port}, work: %{scheduler: scheduler}} = :sys.get_state(server)
      assert scheduler.active == first
      assert {:parse, _ref} = scheduler.timeout_token
      refute_received {:request_sync_snapshot, _, ^manager, _}

      send_parse_spans(manager, port, first_id, 1)

      # The spans reach the editor while the parse is still in flight; only parse_complete admits the next buffer.
      assert_receive {:minga_highlight,
                      {:buffer_event, ^first,
                       %EventCorrelation{generation: ^generation, version: 1},
                       {:highlight_spans, []}}},
                     2_000

      :sys.get_state(server)
      refute_received {:request_sync_snapshot, _, ^manager, _}

      send_parse_complete(manager, port, first_id, 1)

      # Both messages come from Manager to this test; match either to check their actual order.
      assert_receive message when elem(message, 0) in [:request_sync_snapshot, :minga_highlight],
                     2_000

      assert {:request_sync_snapshot, :full, ^manager, second_token} = message

      assert_receive {:minga_highlight,
                      {:buffer_event, ^first,
                       %EventCorrelation{generation: ^generation, version: 1}, :parse_complete}},
                     2_000

      send_snapshot(manager, second, second_token, "defmodule Second do\nend\n")
      send_parse_completion(manager, port, second_id, 2)

      assert_receive {:minga_highlight,
                      {:buffer_event, ^second, %EventCorrelation{version: 2},
                       {:highlight_spans, []}}},
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

      assert_receive {:minga_highlight, {:buffer_event, ^buffer, _correlation, :parse_complete}},
                     2_000

      assert :ok = Manager.request_parse(buffer, server)

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer, _correlation, {:highlight_spans, []}}},
                     2_000

      assert_receive {:minga_highlight, {:buffer_event, ^buffer, _correlation, :parse_complete}},
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

    test "a failed snapshot write replies to pending callers and automatically resyncs" do
      server = start_parser_manager()
      :ok = Manager.subscribe(server)
      buffer = self()
      config = %BufferConfig{language: "elixir"}
      content = "defmodule RecoveredAfterWriteFailure do\nend\n"

      %EventCorrelation{generation: generation} =
        Manager.register_buffer_correlated(buffer, config, server: server)

      buffer_id = Manager.buffer_id(buffer, server)
      assert_receive {:request_sync_snapshot, :full, manager, snapshot_token}, 2_000

      request = :gen_server.send_request(server, {:request_indent, buffer, 1, 10_000})
      assert_receive {:request_sync_snapshot, 0, ^manager, _request_token}, 2_000

      replace_port_with_closed_handle(server)
      send_snapshot(manager, buffer, snapshot_token, content)

      assert :gen_server.wait_response(request, 2_000) == {:reply, nil}
      assert_receive {:minga_highlight, :parser_restarted}, 2_000
      assert_receive {:request_sync_snapshot, :full, ^manager, retry_token}
      refute retry_token == snapshot_token
      refute_received {:minga_highlight, :parser_crashed}

      assert Manager.buffer_id(buffer, server) == buffer_id
      assert Manager.resolve_buffer(buffer_id, server) == buffer
      send_snapshot(manager, buffer, retry_token, content)

      assert_receive {:minga_highlight,
                      {:buffer_event, ^buffer,
                       %EventCorrelation{generation: ^generation, version: 1},
                       {:highlight_spans, _spans}}},
                     2_000
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
      scheduler = :sys.get_state(server).work.scheduler
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
    @highlight_timeout 10_000

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

  defp start_snapshot_provider do
    test = self()

    start_supervised!({Task, fn -> relay_snapshot_requests(test) end})
  end

  defp relay_snapshot_requests(test) do
    receive do
      {:request_sync_snapshot, cursor, manager, token} ->
        send(test, {:snapshot_requested, self(), cursor, manager, token})
        relay_snapshot_requests(test)
    end
  end

  defp send_snapshot(manager, buffer, token, content) do
    send(
      manager,
      {:buffer_sync_snapshot,
       %SyncSnapshot{
         buffer: buffer,
         token: token,
         version: 1,
         sequence: 1,
         changes: {:full, content}
       }}
    )
  end

  defp send_parse_completion(manager, port, buffer_id, version) do
    send_parse_spans(manager, port, buffer_id, version)
    send_parse_complete(manager, port, buffer_id, version)
  end

  defp send_parse_spans(manager, port, buffer_id, version) do
    send(
      manager,
      {port, {:data, <<Opcodes.highlight_spans(), buffer_id::32, version::32, 0::32>>}}
    )
  end

  defp send_parse_complete(manager, port, buffer_id, version) do
    send(manager, {port, {:data, <<Opcodes.parse_complete(), buffer_id::32, version::32>>}})
  end

  defp replace_port_with_closed_handle(server) do
    # The dead handle was owned by the test, so it cannot notify Manager of an exit.
    # Any message from the former live Port no longer matches Manager's current handle.
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    Port.close(port)

    :sys.replace_state(server, fn state ->
      :ok = PortLifecycle.close(state.port.handle)
      %{state | port: PortState.opened(state.port, port)}
    end)
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

  # The kinds of this buffer's parser events, in arrival order, through the parse_complete that ends one parse.
  defp parse_results(buffer, kinds \\ []) do
    receive do
      {:minga_highlight, {:buffer_event, ^buffer, _correlation, :parse_complete}} ->
        Enum.reverse(kinds)

      {:minga_highlight, {:buffer_event, ^buffer, _correlation, {kind, _payload}}} ->
        parse_results(buffer, [kind | kinds])
    after
      2_000 ->
        flunk(
          "no parse_complete ended the parse; results so far: #{inspect(Enum.reverse(kinds))}"
        )
    end
  end
end
