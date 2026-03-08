defmodule Minga.Agent.FileMentionTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.FileMention

  @moduletag :tmp_dir

  # ── Extraction ──────────────────────────────────────────────────────────────

  describe "extract_mentions/1" do
    test "extracts a single @mention at start of text" do
      mentions = FileMention.extract_mentions("@lib/foo.ex what does this do?")
      assert [%{path: "lib/foo.ex"}] = mentions
    end

    test "extracts multiple @mentions" do
      mentions = FileMention.extract_mentions("look at @a.ex and @b.ex")
      paths = Enum.map(mentions, & &1.path)
      assert paths == ["a.ex", "b.ex"]
    end

    test "returns empty list when no mentions" do
      assert [] = FileMention.extract_mentions("no mentions here")
    end

    test "does not match @ in the middle of a word" do
      assert [] = FileMention.extract_mentions("email@example.com")
    end

    test "extracts mention after newline" do
      mentions = FileMention.extract_mentions("first line\n@lib/bar.ex second line")
      assert [%{path: "lib/bar.ex"}] = mentions
    end

    test "extracts mention after tab" do
      mentions = FileMention.extract_mentions("\t@lib/bar.ex")
      assert [%{path: "lib/bar.ex"}] = mentions
    end

    test "records start and stop positions" do
      mentions = FileMention.extract_mentions("@lib/foo.ex rest")
      assert [%{start: 0, stop: 11}] = mentions
    end
  end

  # ── Resolution ──────────────────────────────────────────────────────────────

  describe "resolve_prompt/2" do
    test "returns text unchanged when no mentions", %{tmp_dir: dir} do
      assert {:ok, "hello world"} = FileMention.resolve_prompt("hello world", dir)
    end

    test "prepends file content for a valid mention", %{tmp_dir: dir} do
      path = Path.join(dir, "test.ex")
      File.write!(path, "defmodule Test do\nend")

      {:ok, result} = FileMention.resolve_prompt("@test.ex explain this", dir)
      assert result =~ "Contents of test.ex:"
      assert result =~ "defmodule Test do"
      assert result =~ "explain this"
    end

    test "handles multiple mentions", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.ex"), "module_a")
      File.write!(Path.join(dir, "b.ex"), "module_b")

      {:ok, result} = FileMention.resolve_prompt("@a.ex @b.ex compare these", dir)
      assert result =~ "Contents of a.ex:"
      assert result =~ "Contents of b.ex:"
      assert result =~ "module_a"
      assert result =~ "module_b"
      assert result =~ "compare these"
    end

    test "returns error for missing file", %{tmp_dir: dir} do
      assert {:error, msg} = FileMention.resolve_prompt("@nonexistent.ex read this", dir)
      assert msg =~ "nonexistent.ex"
      assert msg =~ "file not found"
    end

    test "returns error for binary file", %{tmp_dir: dir} do
      path = Path.join(dir, "binary.bin")
      File.write!(path, <<0, 1, 2, 255, 254, 253>>)

      assert {:error, msg} = FileMention.resolve_prompt("@binary.bin read this", dir)
      assert msg =~ "binary file"
    end

    test "removes @mention from body text", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "x.ex"), "content")

      {:ok, result} = FileMention.resolve_prompt("@x.ex explain", dir)
      # The body should just say "explain", not "@x.ex explain"
      lines = String.split(result, "\n")
      last_line = List.last(lines)
      assert last_line == "explain"
    end

    test "uses file extension for code fence language", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "app.py"), "print('hello')")

      {:ok, result} = FileMention.resolve_prompt("@app.py what does this do?", dir)
      assert result =~ "```py"
    end
  end

  # ── Completion ──────────────────────────────────────────────────────────────

  describe "new_completion/3" do
    test "creates completion with all files as initial candidates" do
      files = ["lib/a.ex", "lib/b.ex", "test/c.ex"]
      comp = FileMention.new_completion(files, 0, 5)

      assert comp.prefix == ""
      assert comp.candidates == files
      assert comp.selected == 0
      assert comp.anchor_line == 0
      assert comp.anchor_col == 5
    end

    test "limits initial candidates to 10" do
      files = Enum.map(1..20, &"file_#{&1}.ex")
      comp = FileMention.new_completion(files, 0, 0)
      assert length(comp.candidates) == 10
    end
  end

  describe "update_prefix/2" do
    test "filters candidates by prefix" do
      files = ["lib/buffer.ex", "lib/editor.ex", "test/buffer_test.exs"]
      comp = FileMention.new_completion(files, 0, 0)

      comp = FileMention.update_prefix(comp, "buf")
      assert "lib/buffer.ex" in comp.candidates
      assert "test/buffer_test.exs" in comp.candidates
      refute "lib/editor.ex" in comp.candidates
    end

    test "case-insensitive filtering" do
      files = ["lib/MyModule.ex", "lib/other.ex"]
      comp = FileMention.new_completion(files, 0, 0)

      comp = FileMention.update_prefix(comp, "mymod")
      assert "lib/MyModule.ex" in comp.candidates
    end

    test "clamps selected index when candidates shrink" do
      files = ["a.ex", "b.ex", "c.ex"]
      comp = FileMention.new_completion(files, 0, 0)
      comp = %{comp | selected: 2}

      comp = FileMention.update_prefix(comp, "a")
      assert comp.selected == 0
    end
  end

  describe "select_next/1 and select_prev/1" do
    test "wraps around forward" do
      files = ["a.ex", "b.ex", "c.ex"]
      comp = FileMention.new_completion(files, 0, 0)
      assert comp.selected == 0

      comp = FileMention.select_next(comp)
      assert comp.selected == 1

      comp = FileMention.select_next(comp)
      assert comp.selected == 2

      comp = FileMention.select_next(comp)
      assert comp.selected == 0
    end

    test "wraps around backward" do
      files = ["a.ex", "b.ex", "c.ex"]
      comp = FileMention.new_completion(files, 0, 0)

      comp = FileMention.select_prev(comp)
      assert comp.selected == 2
    end

    test "no-op with empty candidates" do
      comp = FileMention.new_completion([], 0, 0)
      assert comp == FileMention.select_next(comp)
      assert comp == FileMention.select_prev(comp)
    end
  end

  describe "selected_path/1" do
    test "returns currently selected path" do
      files = ["a.ex", "b.ex"]
      comp = FileMention.new_completion(files, 0, 0)
      assert FileMention.selected_path(comp) == "a.ex"

      comp = FileMention.select_next(comp)
      assert FileMention.selected_path(comp) == "b.ex"
    end

    test "returns nil when no candidates" do
      comp = FileMention.new_completion([], 0, 0)
      assert FileMention.selected_path(comp) == nil
    end
  end
end
