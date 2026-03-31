defmodule MingaAgent.FileMentionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.FileMention

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

  # ── Image support ────────────────────────────────────────────────────────────

  describe "image_path?/1" do
    test "recognizes image extensions" do
      assert FileMention.image_path?("screenshot.png")
      assert FileMention.image_path?("photo.jpg")
      assert FileMention.image_path?("photo.jpeg")
      assert FileMention.image_path?("anim.gif")
      assert FileMention.image_path?("modern.webp")
    end

    test "case insensitive" do
      assert FileMention.image_path?("PHOTO.PNG")
      assert FileMention.image_path?("image.JPG")
    end

    test "rejects non-image extensions" do
      refute FileMention.image_path?("code.ex")
      refute FileMention.image_path?("readme.md")
      refute FileMention.image_path?("data.json")
    end
  end

  describe "resolve_prompt/2 with images" do
    test "returns ContentPart list when image is mentioned", %{tmp_dir: dir} do
      # Create a minimal 1x1 red PNG (67 bytes)
      png_data = create_minimal_png()
      path = Path.join(dir, "screenshot.png")
      File.write!(path, png_data)

      {:ok, parts} = FileMention.resolve_prompt("@screenshot.png what is this?", dir)

      assert is_list(parts)
      assert length(parts) == 2

      [text_part, image_part] = parts
      assert text_part.type == :text
      assert text_part.text =~ "what is this?"

      assert image_part.type == :image
      assert image_part.media_type == "image/png"
      assert is_binary(image_part.data)
    end

    test "mixes text files and images as content parts", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "code.ex"), "defmodule Foo do\nend")
      File.write!(Path.join(dir, "design.png"), create_minimal_png())

      {:ok, parts} = FileMention.resolve_prompt("@code.ex @design.png compare", dir)

      assert is_list(parts)
      text_parts = Enum.filter(parts, &(&1.type == :text))
      image_parts = Enum.filter(parts, &(&1.type == :image))

      assert length(text_parts) == 1
      assert length(image_parts) == 1

      assert hd(text_parts).text =~ "defmodule Foo"
      assert hd(text_parts).text =~ "compare"
    end

    test "rejects oversized images", %{tmp_dir: dir} do
      # Create a file that exceeds the 5MB limit
      path = Path.join(dir, "huge.png")
      File.write!(path, :binary.copy(<<0>>, 6 * 1024 * 1024))

      assert {:error, msg} = FileMention.resolve_prompt("@huge.png look", dir)
      assert msg =~ "image too large"
    end

    test "returns error for missing image file", %{tmp_dir: dir} do
      assert {:error, msg} = FileMention.resolve_prompt("@missing.png look", dir)
      assert msg =~ "file not found"
    end

    test "text-only mentions still return a string", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.ex"), "code")

      {:ok, result} = FileMention.resolve_prompt("@test.ex explain", dir)
      assert is_binary(result)
    end
  end

  # Helper to create a minimal valid PNG for testing
  defp create_minimal_png do
    # Minimal 1x1 red PNG
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 2,
      0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8, 215, 99, 248, 207, 192, 0, 0, 0,
      3, 0, 1, 24, 216, 141, 110, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
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
