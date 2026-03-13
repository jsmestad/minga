defmodule Minga.Agent.MemoryTest do
  use ExUnit.Case, async: false

  alias Minga.Agent.Memory

  setup do
    # Use a temp path for the memory file during tests
    _test_path = Path.join(System.tmp_dir!(), "minga_test_memory_#{:rand.uniform(100_000)}.md")
    original_env = System.get_env("XDG_CONFIG_HOME")

    # Point XDG_CONFIG_HOME to a temp dir so Memory.path() resolves there
    tmp_config = Path.join(System.tmp_dir!(), "minga_test_config_#{:rand.uniform(100_000)}")
    File.mkdir_p!(Path.join(tmp_config, "minga"))
    System.put_env("XDG_CONFIG_HOME", tmp_config)

    on_exit(fn ->
      if original_env do
        System.put_env("XDG_CONFIG_HOME", original_env)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf(tmp_config)
    end)

    %{config_dir: tmp_config, memory_path: Path.join([tmp_config, "minga", "MEMORY.md"])}
  end

  describe "read/0" do
    test "returns nil when no memory file exists" do
      assert Memory.read() == nil
    end

    test "returns content when memory file exists", %{memory_path: path} do
      File.write!(path, "- some memory entry\n")
      assert Memory.read() == "- some memory entry\n"
    end

    test "returns nil for empty file", %{memory_path: path} do
      File.write!(path, "")
      assert Memory.read() == nil
    end
  end

  describe "append/1" do
    test "creates file and appends entry", %{memory_path: path} do
      assert :ok = Memory.append("user prefers tabs")
      content = File.read!(path)
      assert content =~ "user prefers tabs"
      assert content =~ "[20"
    end

    test "appends to existing file", %{memory_path: path} do
      File.write!(path, "- existing entry\n")
      assert :ok = Memory.append("new entry")
      content = File.read!(path)
      assert content =~ "existing entry"
      assert content =~ "new entry"
    end
  end

  describe "for_prompt/0" do
    test "returns nil when no memory exists" do
      assert Memory.for_prompt() == nil
    end

    test "returns formatted prompt section with content", %{memory_path: path} do
      File.write!(path, "- user likes Elixir\n- use pattern matching\n")
      result = Memory.for_prompt()
      assert result =~ "User Memory"
      assert result =~ "user likes Elixir"
    end
  end

  describe "clear/0" do
    test "removes the memory file", %{memory_path: path} do
      File.write!(path, "content")
      assert :ok = Memory.clear()
      refute File.exists?(path)
    end

    test "succeeds when file doesn't exist" do
      assert :ok = Memory.clear()
    end
  end

  describe "summary/0" do
    test "shows path when no file exists" do
      result = Memory.summary()
      assert result =~ "No memory file"
    end

    test "shows stats when file exists", %{memory_path: path} do
      File.write!(path, "- entry one\n- entry two\n")
      result = Memory.summary()
      assert result =~ "Entries: 2"
      assert result =~ "entry one"
    end
  end
end
