defmodule MingaAgent.Tools.LspBridgeTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.LspBridge

  test "definition results project file URIs to paths without normalizing them" do
    location = %{
      "uri" => "file:///home/dev/lib/with%20space.ex",
      "range" => %{"start" => %{"line" => 10, "character" => 5}}
    }

    assert LspBridge.parse_location([location]) == {"/home/dev/lib/with%20space.ex", 10, 5}
    assert LspBridge.parse_location([%{}, location]) == nil
  end

  describe "parse_all_locations/1" do
    @tag :tmp_dir
    test "skips unknown references but keeps order, duplicates, paths, and context", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "references.ex")
      File.write!(path, "first\n  second  \n")
      uri = "file://#{path}"

      link = %{
        "targetUri" => uri,
        "targetRange" => %{"start" => %{"line" => 1, "character" => 2}}
      }

      fallback = %{"uri" => uri, "range" => nil}

      assert LspBridge.parse_all_locations([link, %{"uri" => uri}, fallback, link]) == [
               {path, 1, 2, "second"},
               {path, 0, 0, "first"},
               {path, 1, 2, "second"}
             ]
    end

    test "returns empty list for nil" do
      assert [] == LspBridge.parse_all_locations(nil)
    end

    test "returns empty list for non-list" do
      assert [] == LspBridge.parse_all_locations("not a list")
    end
  end

  describe "extract_hover_markdown/1" do
    test "extracts from MarkupContent with markdown kind" do
      content = %{"kind" => "markdown", "value" => "# Hello\n\nWorld"}
      assert "# Hello\n\nWorld" = LspBridge.extract_hover_markdown(content)
    end

    test "extracts from MarkupContent with plaintext kind" do
      content = %{"kind" => "plaintext", "value" => "simple text"}
      assert "simple text" = LspBridge.extract_hover_markdown(content)
    end

    test "extracts from plain string" do
      assert "hello" = LspBridge.extract_hover_markdown("  hello  ")
    end

    test "extracts from MarkedString with language" do
      content = %{"language" => "elixir", "value" => "@spec foo() :: :ok"}
      assert "```elixir\n@spec foo() :: :ok\n```" = LspBridge.extract_hover_markdown(content)
    end

    test "joins array of contents" do
      contents = [
        %{"kind" => "markdown", "value" => "Part 1"},
        %{"kind" => "markdown", "value" => "Part 2"}
      ]

      assert "Part 1\n\nPart 2" = LspBridge.extract_hover_markdown(contents)
    end

    test "returns empty string for nil" do
      assert "" = LspBridge.extract_hover_markdown(nil)
    end
  end

  describe "flatten_document_symbols/1" do
    test "flattens hierarchical DocumentSymbol format" do
      symbols = [
        %{
          "name" => "MyModule",
          "kind" => 2,
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 50, "character" => 3}
          },
          "children" => [
            %{
              "name" => "hello/1",
              "kind" => 12,
              "range" => %{
                "start" => %{"line" => 5, "character" => 2},
                "end" => %{"line" => 8, "character" => 5}
              },
              "children" => []
            }
          ]
        }
      ]

      items = LspBridge.flatten_document_symbols(symbols)
      assert Enum.count(items) == 2

      [module_item, func_item] = items
      {_, 0, 0, module_label} = module_item
      {_, 5, 2, func_label} = func_item

      assert module_label =~ "Module"
      assert module_label =~ "MyModule"
      assert func_label =~ "Function"
      assert func_label =~ "hello/1"
    end

    test "returns empty list for empty input" do
      assert [] = LspBridge.flatten_document_symbols([])
    end
  end

  describe "workspace_symbol_to_location/1" do
    test "converts workspace symbol to location tuple" do
      sym = %{
        "name" => "MyModule",
        "kind" => 2,
        "location" => %{
          "uri" => "file:///home/dev/lib/my_module.ex",
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 100, "character" => 3}
          }
        },
        "containerName" => ""
      }

      {path, line, col, label} = LspBridge.workspace_symbol_to_location(sym)
      assert path == "/home/dev/lib/my_module.ex"
      assert line == 0
      assert col == 0
      assert label =~ "Module"
      assert label =~ "MyModule"
    end

    test "includes container name when present" do
      sym = %{
        "name" => "start_link",
        "kind" => 12,
        "location" => %{
          "uri" => "file:///home/dev/lib/server.ex",
          "range" => %{
            "start" => %{"line" => 10, "character" => 2},
            "end" => %{"line" => 15, "character" => 5}
          }
        },
        "containerName" => "MyApp.Server"
      }

      {_path, _line, _col, label} = LspBridge.workspace_symbol_to_location(sym)
      assert label =~ "MyApp.Server.start_link"
    end
  end

  describe "symbol_kind_name/1" do
    test "maps known kinds" do
      assert "Module" = LspBridge.symbol_kind_name(2)
      assert "Function" = LspBridge.symbol_kind_name(12)
      assert "Struct" = LspBridge.symbol_kind_name(23)
    end

    test "returns Symbol for unknown kinds" do
      assert "Symbol" = LspBridge.symbol_kind_name(99)
      assert "Symbol" = LspBridge.symbol_kind_name(nil)
    end
  end

  describe "position_params/3" do
    test "builds standard LSP position params" do
      params = LspBridge.position_params("/home/dev/lib/foo.ex", 10, 5)

      assert %{
               "textDocument" => %{"uri" => "file:///home/dev/lib/foo.ex"},
               "position" => %{"line" => 10, "character" => 5}
             } = params
    end
  end

  describe "path_to_uri/1 and uri_to_path/1" do
    test "round-trips a path" do
      path = "/home/dev/lib/foo.ex"
      uri = LspBridge.path_to_uri(path)
      assert uri == "file:///home/dev/lib/foo.ex"
      assert LspBridge.uri_to_path(uri) == path
    end
  end
end
