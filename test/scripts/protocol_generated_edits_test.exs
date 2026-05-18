# This module shells out to git in temporary repositories.
defmodule Minga.ProtocolGeneratedEditsScriptTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/check_protocol_generated_edits", __DIR__)
  @git_env [
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_AUTHOR_NAME", "Test User"},
    {"GIT_AUTHOR_EMAIL", "test@example.com"},
    {"GIT_COMMITTER_NAME", "Test User"},
    {"GIT_COMMITTER_EMAIL", "test@example.com"}
  ]

  test "passes when generated source files are only deleted" do
    with_git_repo(fn dir ->
      write!(
        dir,
        "macos/.generated/protocol/ProtocolOpcodes.generated.swift",
        "let OP_KEY_PRESS: UInt8 = 0x01\n"
      )

      commit_all!(dir, "baseline")
      File.rm!(Path.join(dir, "macos/.generated/protocol/ProtocolOpcodes.generated.swift"))
      commit_all!(dir, "remove generated source")

      assert {"", 0} = System.cmd(@script, ["HEAD~1"], cd: dir, stderr_to_stdout: true)
    end)
  end

  test "fails when generated source files are added back" do
    with_git_repo(fn dir ->
      commit_all!(dir, "baseline")
      write!(dir, "zig/src/protocol_opcodes.zig", "pub const OP_KEY_PRESS: u8 = 0x01;\n")
      commit_all!(dir, "add generated source")

      {output, code} = System.cmd(@script, ["HEAD~1"], cd: dir, stderr_to_stdout: true)

      assert code == 1
      assert output =~ "Generated protocol artifacts must not be committed as source"
      assert output =~ "zig/src/protocol_opcodes.zig"
      assert output =~ "mix protocol.gen"
    end)
  end

  test "fails when ignored generated artifact paths are force-added" do
    with_git_repo(fn dir ->
      commit_all!(dir, "baseline")

      write!(
        dir,
        "macos/.generated/protocol/ProtocolOpcodes.generated.swift",
        "let OP_KEY_PRESS: UInt8 = 0x01\n"
      )

      write!(
        dir,
        "zig/src/generated/protocol_opcodes.zig",
        "pub const OP_KEY_PRESS: u8 = 0x01;\n"
      )

      commit_all!(dir, "force add ignored generated artifacts")

      {output, code} = System.cmd(@script, ["HEAD~1"], cd: dir, stderr_to_stdout: true)

      assert code == 1
      assert output =~ "macos/.generated/protocol/ProtocolOpcodes.generated.swift"
      assert output =~ "zig/src/generated/protocol_opcodes.zig"
    end)
  end

  test "passes for schema and generator edits" do
    with_git_repo(fn dir ->
      commit_all!(dir, "baseline")
      write!(dir, "docs/protocol_schema.toml", "version = \"1.0.1\"\n")
      write!(dir, "mix/tasks/protocol.gen.ex", "defmodule Mix.Tasks.Protocol.Gen do\nend\n")
      commit_all!(dir, "edit generator inputs")

      assert {"", 0} = System.cmd(@script, ["HEAD~1"], cd: dir, stderr_to_stdout: true)
    end)
  end

  @spec with_git_repo((Path.t() -> any())) :: any()
  defp with_git_repo(fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "protocol-generated-edits-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    try do
      git!(dir, ["init", "-b", "main"])
      git!(dir, ["config", "user.email", "test@example.com"])
      git!(dir, ["config", "user.name", "Test User"])
      git!(dir, ["config", "core.hooksPath", "/dev/null"])
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  @spec write!(Path.t(), Path.t(), String.t()) :: :ok
  defp write!(dir, rel_path, content) do
    path = Path.join(dir, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  @spec commit_all!(Path.t(), String.t()) :: :ok
  defp commit_all!(dir, message) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--allow-empty", "-m", message])
  end

  @spec git!(Path.t(), [String.t()]) :: :ok
  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: @git_env) do
      {_output, 0} -> :ok
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{output}")
    end
  end
end
