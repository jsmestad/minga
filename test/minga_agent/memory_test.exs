defmodule MingaAgent.MemoryTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Memory

  setup do
    tmp_config = Path.join(System.tmp_dir!(), "minga_test_config_#{:rand.uniform(100_000)}")
    File.mkdir_p!(Path.join(tmp_config, "minga"))
    memory_path = Path.join([tmp_config, "minga", "MEMORY.md"])

    on_exit(fn -> File.rm_rf(tmp_config) end)

    %{config_dir: tmp_config, memory_path: memory_path}
  end

  describe "read/1" do
    test "returns nil when no memory file exists", %{config_dir: dir} do
      assert Memory.read(dir) == nil
    end

    test "returns content when memory file exists", %{config_dir: dir, memory_path: path} do
      File.write!(path, "- some memory entry\n")
      assert Memory.read(dir) == "- some memory entry\n"
    end

    test "returns nil for empty file", %{config_dir: dir, memory_path: path} do
      File.write!(path, "")
      assert Memory.read(dir) == nil
    end
  end

  describe "append/2" do
    test "creates file and appends entry", %{config_dir: dir, memory_path: path} do
      assert :ok = Memory.append("user prefers tabs", dir)
      content = File.read!(path)
      assert content =~ "user prefers tabs"
      assert content =~ "[20"
    end

    test "appends to existing file", %{config_dir: dir, memory_path: path} do
      File.write!(path, "- existing entry\n")
      assert :ok = Memory.append("new entry", dir)
      content = File.read!(path)
      assert content =~ "existing entry"
      assert content =~ "new entry"
    end
  end

  describe "for_prompt/1" do
    test "returns nil when no memory exists", %{config_dir: dir} do
      assert Memory.for_prompt(dir) == nil
    end

    test "returns formatted prompt section with content", %{config_dir: dir, memory_path: path} do
      File.write!(path, "- user likes Elixir\n- use pattern matching\n")
      result = Memory.for_prompt(dir)
      assert result =~ "User Memory"
      assert result =~ "user likes Elixir"
    end
  end

  describe "clear/1" do
    test "removes the memory file", %{config_dir: dir, memory_path: path} do
      File.write!(path, "content")
      assert :ok = Memory.clear(dir)
      refute File.exists?(path)
    end

    test "succeeds when file doesn't exist", %{config_dir: dir} do
      assert :ok = Memory.clear(dir)
    end
  end

  describe "summary/1" do
    test "shows path when no file exists", %{config_dir: dir} do
      result = Memory.summary(dir)
      assert result =~ "No memory file"
    end

    test "shows stats when file exists", %{config_dir: dir, memory_path: path} do
      File.write!(path, "- entry one\n- entry two\n")
      result = Memory.summary(dir)
      assert result =~ "Entries: 2"
      assert result =~ "entry one"
    end
  end
end
