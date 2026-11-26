defmodule Minga.Project.ProjectSearchTest do
  # Serializes because these tests run the actual search tool.
  use ExUnit.Case, async: false

  alias Minga.Project.ProjectSearch
  alias Minga.Project.Root

  defp directory!(path) do
    {:ok, root} = Root.directory(path)
    root
  end

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

  describe "parse_query/1" do
    test "splits ripgrep flags after -- from the pattern, as in Doom" do
      for {query, parsed} <- [
            {"limit_lable", {"limit_lable", []}},
            {"limit_lable -- -u", {"limit_lable", ["-u"]}},
            {"limit_lable -- -u --hidden", {"limit_lable", ["-u", "--hidden"]}},
            {"limit_lable -- -g *.ex -t elixir", {"limit_lable", ["-g", "*.ex", "-t", "elixir"]}},
            {"limit_lable -- -g", {"limit_lable", ["-g"]}},
            {"limit_lable -- --glob=*.ex", {"limit_lable", ["--glob=*.ex"]}},
            {"a -- b -- -uu", {"a", ["-uu"]}},
            {"limit_lable -- lib", {"limit_lable", []}},
            {"limit_lable -- ", {"limit_lable", []}}
          ] do
        assert ProjectSearch.parse_query(query) == parsed, query
      end
    end

    test "a query that is only flags has no pattern to search for" do
      assert ProjectSearch.search(" -- -u", Root.file("/")) == {:error, "Empty search query"}
    end
  end

  describe "search/2" do
    test "returns error for empty query" do
      assert {:error, "Empty search query"} = ProjectSearch.search("", Root.file("/tmp"))
    end

    test "rejects a file-scoped root before searching" do
      assert {:error, "Project search root is not authorized: not_a_directory_root"} =
               ProjectSearch.search("needle", Root.file(System.user_home!()))
    end

    test "detects a search strategy" do
      strategy = ProjectSearch.detect_strategy()
      assert strategy in [:rg, :grep, :none]
    end

    test "returns the selected tool's parsed matches" do
      root =
        Path.join(System.tmp_dir!(), "minga-search-tool-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(Path.join(root, "haystack.txt"), "skip\nbefore NEEDLE after\n")
      result = ProjectSearch.search("NEEDLE", directory!(root))

      case ProjectSearch.detect_strategy() do
        :rg ->
          assert {:ok, [%{file: "haystack.txt", line: 2, col: 7, text: "before NEEDLE after"}],
                  false, :visible} = result

        :grep ->
          assert {:ok, [%{file: "haystack.txt", line: 2, col: 0, text: "before NEEDLE after"}],
                  false, :all} = result

        :none ->
          assert {:error, "No search tool available. Install `ripgrep` (rg) for best results."} =
                   result
      end
    end

    @tag :tmp_dir
    test "returns empty results for a pattern that does not match", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "sample.txt"), "present\n")

      case ProjectSearch.search("not-present", directory!(dir)) do
        {:ok, matches, false, _coverage} ->
          assert matches == []

        {:error, _} ->
          :ok
      end
    end

    test "caps results in-process and reports truncation when matches exceed the cap" do
      dir = Path.join(System.tmp_dir!(), "minga-search-cap-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      over_cap = ProjectSearch.max_results() + 50
      lines = Enum.map_join(1..over_cap, "\n", fn _ -> "NEEDLE here" end)
      File.write!(Path.join(dir, "haystack.txt"), lines <> "\n")

      case ProjectSearch.search("NEEDLE", directory!(dir)) do
        {:ok, matches, truncated?, _coverage} ->
          # The cap is enforced while collecting: we never accumulate more than
          # the cap regardless of how many lines the subprocess could emit.
          assert truncated?
          assert Enum.count(matches) == ProjectSearch.max_results()

        {:error, _} ->
          :ok
      end
    end

    test "ripgrep preserves the initial pattern, reports effective coverage, and rejects output overrides" do
      if ProjectSearch.detect_strategy() == :rg do
        root =
          Path.join(
            System.tmp_dir!(),
            "minga-search-options-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(root)
        on_exit(fn -> File.rm_rf!(root) end)
        File.write!(Path.join(root, "visible.txt"), "primary\nsecondary\n")
        File.write!(Path.join(root, "ignored.txt"), "primary\n")
        File.write!(Path.join(root, ".hidden.txt"), "primary\n")
        File.write!(Path.join(root, ".ignore"), "ignored.txt\n")
        root = directory!(root)

        assert {:ok, matches, false, :visible} =
                 ProjectSearch.search("primary -- -e secondary", root)

        assert Enum.map(matches, & &1.text) == ["primary", "secondary"]

        assert {:ok, widened, false, :all} = ProjectSearch.search("primary -- -u -u", root)

        assert widened |> Enum.map(& &1.file) |> Enum.sort() ==
                 [".hidden.txt", "ignored.txt", "visible.txt"]

        assert {:error, "Unsupported search option --quiet."} =
                 ProjectSearch.search("primary -- --quiet", root)

        assert {:error, "Missing value for search option -g."} =
                 ProjectSearch.search("primary -- -g", root)
      end
    end
  end
end
