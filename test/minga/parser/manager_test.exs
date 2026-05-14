defmodule Minga.Parser.ManagerTest do
  # Spawns the real Zig parser Port, so this test must not run concurrently with other OS-process tests.
  use ExUnit.Case, async: false

  @moduletag :heavy
  @moduletag timeout: 10_000

  alias Minga.Parser.Manager
  alias Minga.Parser.Protocol

  describe "request_indent/3" do
    test "returns nil without waiting when the parser port is unavailable" do
      server = start_parser_manager(parser_path: "/missing/minga-parser")

      assert Manager.request_indent(1, 0, server) == nil
    end

    test "returns tree-sitter indent levels from the parser" do
      server = start_parser_manager()
      content = "def foo do\nif bar do\nbaz\nend\nend"
      buffer_id = 1

      setup_buffer(server, buffer_id, content)

      assert Manager.request_indent(buffer_id, 2, server) == 2
      assert Manager.request_indent(buffer_id, 3, server) == 1
    end

    test "returns first-enter indentation after the newline is present in a complete block" do
      server = start_parser_manager()
      content = "def foo do\n\nend"
      buffer_id = 1

      setup_buffer(server, buffer_id, content)

      assert Manager.request_indent(buffer_id, 1, server) == 1
    end
  end

  defp setup_buffer(server, buffer_id, content) do
    Manager.send_commands(server, [
      Protocol.encode_set_language(buffer_id, "elixir"),
      Protocol.encode_parse_buffer(buffer_id, 0, content)
    ])

    Manager.register_buffer(buffer_id, "elixir", fn -> content end, server: server)
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
