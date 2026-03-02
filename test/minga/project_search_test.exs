defmodule Minga.ProjectSearchTest do
  use ExUnit.Case, async: true

  alias Minga.ProjectSearch

  defp encode_json(term), do: JSON.encode!(term)

  describe "parse_rg_json_line/1" do
    test "parses a match line with submatch" do
      json =
        encode_json(%{
          "type" => "match",
          "data" => %{
            "path" => %{"text" => "lib/foo.ex"},
            "lines" => %{"text" => "defmodule Foo\n"},
            "line_number" => 1,
            "submatches" => [%{"match" => %{"text" => "Foo"}, "start" => 10, "end" => 13}]
          }
        })

      assert {:ok, match} = ProjectSearch.parse_rg_json_line(json)
      assert match.file == "lib/foo.ex"
      assert match.line == 1
      assert match.col == 10
      assert match.text == "defmodule Foo"
    end

    test "parses match line with no submatches" do
      json =
        encode_json(%{
          "type" => "match",
          "data" => %{
            "path" => %{"text" => "./src/main.zig"},
            "lines" => %{"text" => "const x = 1;\n"},
            "line_number" => 42,
            "submatches" => []
          }
        })

      assert {:ok, match} = ProjectSearch.parse_rg_json_line(json)
      assert match.file == "src/main.zig"
      assert match.col == 0
    end

    test "skips summary lines" do
      assert :skip =
               ProjectSearch.parse_rg_json_line(
                 encode_json(%{"type" => "summary", "data" => %{}})
               )
    end

    test "skips context lines" do
      assert :skip =
               ProjectSearch.parse_rg_json_line(
                 encode_json(%{"type" => "context", "data" => %{}})
               )
    end

    test "skips invalid JSON" do
      assert :skip = ProjectSearch.parse_rg_json_line("not json at all")
    end

    test "skips begin lines" do
      json = encode_json(%{"type" => "begin", "data" => %{"path" => %{"text" => "foo.ex"}}})
      assert :skip = ProjectSearch.parse_rg_json_line(json)
    end
  end

  describe "parse_grep_line/1" do
    test "parses a standard grep match line" do
      assert {:ok, match} = ProjectSearch.parse_grep_line("lib/foo.ex:42:defmodule Foo")
      assert match.file == "lib/foo.ex"
      assert match.line == 42
      assert match.col == 0
      assert match.text == "defmodule Foo"
    end

    test "parses line with colons in the matched text" do
      assert {:ok, match} = ProjectSearch.parse_grep_line("config.exs:10:key: :value")
      assert match.file == "config.exs"
      assert match.line == 10
      assert match.text == "key: :value"
    end

    test "normalizes ./ prefix" do
      assert {:ok, match} = ProjectSearch.parse_grep_line("./lib/foo.ex:1:hello")
      assert match.file == "lib/foo.ex"
    end

    test "skips lines without line numbers" do
      assert :skip = ProjectSearch.parse_grep_line("Binary file matches")
    end

    test "skips lines with non-numeric line part" do
      assert :skip = ProjectSearch.parse_grep_line("file:abc:text")
    end

    test "skips empty lines" do
      assert :skip = ProjectSearch.parse_grep_line("")
    end
  end

  describe "search/2" do
    test "returns error for empty query" do
      assert {:error, "Empty search query"} = ProjectSearch.search("", "/tmp")
    end

    test "detects a search strategy" do
      strategy = ProjectSearch.detect_strategy()
      assert strategy in [:rg, :grep, :none]
    end

    test "searches the current project for a known term" do
      case ProjectSearch.search("defmodule", File.cwd!()) do
        {:ok, matches, _truncated?} ->
          assert matches != []
          first = hd(matches)
          assert is_binary(first.file)
          assert is_integer(first.line)
          assert first.line > 0
          assert is_binary(first.text)

        {:error, _msg} ->
          :ok
      end
    end

    test "returns empty results for nonsense query" do
      query = Base.encode64(:crypto.strong_rand_bytes(32))

      case ProjectSearch.search(query, File.cwd!()) do
        {:ok, matches, false} ->
          assert matches == []

        {:error, _} ->
          :ok
      end
    end
  end
end
