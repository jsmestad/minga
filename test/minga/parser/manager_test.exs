defmodule Minga.Parser.ManagerTest do
  # Spawns the real Zig parser Port, so this test must not run concurrently with other OS-process tests.
  use ExUnit.Case, async: false

  @moduletag :heavy
  @moduletag timeout: 10_000

  alias Minga.Buffer.Document
  alias Minga.Parser.Manager
  alias Minga.Parser.Protocol

  describe "document_symbols" do
    test "parser publishes symbols from built-in tags query after parse" do
      server = start_parser_manager()
      buffer_id = 11
      content = "defmodule Foo do\n  def bar do\n    :ok\n  end\nend\n"

      :ok = Manager.subscribe(server)
      setup_buffer(server, buffer_id, content)
      _indent = Manager.request_indent(buffer_id, 1, server)

      assert_receive {:minga_highlight, {:document_symbols, ^buffer_id, 0, symbols}}, 2_000
      assert Enum.any?(symbols, &match?(%Minga.Language.Symbol{kind: :module, name: "Foo"}, &1))
      assert Enum.any?(symbols, &match?(%Minga.Language.Symbol{kind: :function, name: "bar"}, &1))
    end

    test "parser publishes updated symbols after edit_buffer" do
      server = start_parser_manager()
      buffer_id = 12
      content = "defmodule Foo do\n  def foo do\n    :ok\n  end\nend\n"

      :ok = Manager.subscribe(server)
      setup_buffer(server, buffer_id, content)

      assert_receive {:minga_highlight, {:document_symbols, ^buffer_id, 0, initial_symbols}},
                     2_000

      assert Enum.any?(
               initial_symbols,
               &match?(%Minga.Language.Symbol{kind: :function, name: "foo"}, &1)
             )

      edit = replacement_delta(content, "foo", "bar")
      Manager.send_commands(server, [Protocol.encode_edit_buffer(buffer_id, 1, [edit])])

      assert_receive {:minga_highlight, {:document_symbols, ^buffer_id, 1, edited_symbols}}, 2_000

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

      assert Manager.request_indent(1, 0, server) == nil
    end

    test "returns tree-sitter indent levels from the parser" do
      server = start_parser_manager()
      content = "def foo do\nif bar do\nbaz\nend\nend"
      buffer_id = 1

      setup_buffer(server, buffer_id, "elixir", content)

      assert Manager.request_indent(buffer_id, 2, server) == 2
      assert Manager.request_indent(buffer_id, 3, server) == 1
    end

    test "returns first-enter indentation after the newline is present in a complete block" do
      server = start_parser_manager()
      content = "def foo do\n\nend"
      buffer_id = 1

      setup_buffer(server, buffer_id, "elixir", content)

      assert Manager.request_indent(buffer_id, 1, server) == 1
    end
  end

  describe "request_structural_nav/5" do
    test "returns nil without waiting when the parser port is unavailable" do
      server = start_parser_manager(parser_path: "/missing/minga-parser")

      assert Manager.request_structural_nav(1, 0, 0, 0, server) == nil
    end

    test "returns target node ranges and type names from the parser" do
      server = start_parser_manager()
      content = "function add(a, b) {\n  return a + b;\n}\n"
      buffer_id = 2

      setup_buffer(server, buffer_id, "javascript", content)

      parent = Manager.request_structural_nav(buffer_id, 0, 20, 0, server)
      first_child = Manager.request_structural_nav(buffer_id, 0, 0, 1, server)
      next_sibling = Manager.request_structural_nav(buffer_id, 0, 13, 2, server)
      prev_sibling = Manager.request_structural_nav(buffer_id, 0, 16, 3, server)

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

  @spec replacement_delta(String.t(), String.t(), String.t()) ::
          Minga.Parser.Protocol.edit_delta()
  defp replacement_delta(content, old_text, new_text) do
    {start_byte, _length} = :binary.match(content, old_text)
    old_end_byte = start_byte + byte_size(old_text)
    new_end_byte = start_byte + byte_size(new_text)

    start_position = Document.offset_to_position(Document.new(content), start_byte)
    old_end_position = Document.offset_to_position(Document.new(content), old_end_byte)
    new_content = String.replace(content, old_text, new_text)
    new_end_position = Document.offset_to_position(Document.new(new_content), new_end_byte)

    %{
      start_byte: start_byte,
      old_end_byte: old_end_byte,
      new_end_byte: new_end_byte,
      start_position: start_position,
      old_end_position: old_end_position,
      new_end_position: new_end_position,
      inserted_text: new_text
    }
  end

  defp setup_buffer(server, buffer_id, content) do
    setup_buffer(server, buffer_id, "elixir", content)
  end

  defp setup_buffer(server, buffer_id, language, content) do
    Manager.send_commands(server, [
      Protocol.encode_set_language(buffer_id, language),
      Protocol.encode_parse_buffer(buffer_id, 0, content)
    ])

    Manager.register_buffer(buffer_id, language, fn -> content end, server: server)
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
