defmodule Minga.ProtocolGeneratedEditsScriptTest do
  # Spawns git in temporary repositories to exercise the CI guard script.
  use ExUnit.Case, async: false

  @repo_root File.cwd!()
  @script Path.join(@repo_root, "scripts/check_protocol_generated_edits")

  test "fails when a standalone generated file changes without the schema" do
    with_git_fixture(fn dir ->
      write!(
        dir,
        "macos/Sources/Protocol/ProtocolOpcodes.generated.swift",
        "let OP_KEY_PRESS: UInt8 = 0x02\n"
      )

      git!(dir, ["add", "."])
      git!(dir, ["commit", "-m", "edit generated swift"])

      assert {output, 1} = run_guard(dir)

      assert output =~
               "Generated protocol outputs changed without docs/protocol_schema.toml changing"

      assert output =~ "macos/Sources/Protocol/ProtocolOpcodes.generated.swift"
    end)
  end

  test "passes when a generated file and schema change together" do
    with_git_fixture(fn dir ->
      write!(dir, "docs/protocol_schema.toml", "version = \"1.0.1\"\n")

      write!(
        dir,
        "macos/Sources/Protocol/ProtocolOpcodes.generated.swift",
        "let OP_KEY_PRESS: UInt8 = 0x02\n"
      )

      git!(dir, ["add", "."])
      git!(dir, ["commit", "-m", "edit schema and generated swift"])

      assert {_, 0} = run_guard(dir)
    end)
  end

  test "passes when a mixed protocol file changes outside its generated block" do
    with_git_fixture(fn dir ->
      path = Path.join(dir, "lib/minga_editor/frontend/protocol.ex")
      File.write!(path, File.read!(path) <> "\ndef encode_extra, do: :ok\n")
      git!(dir, ["add", "."])
      git!(dir, ["commit", "-m", "edit protocol code outside generated block"])

      assert {_, 0} = run_guard(dir)
    end)
  end

  test "fails when a mixed protocol file generated block changes without the schema" do
    with_git_fixture(fn dir ->
      path = Path.join(dir, "lib/minga_editor/frontend/protocol.ex")
      source = File.read!(path)
      File.write!(path, String.replace(source, "@op_key_press 0x01", "@op_key_press 0x02"))
      git!(dir, ["add", "."])
      git!(dir, ["commit", "-m", "edit generated elixir block"])

      assert {output, 1} = run_guard(dir)
      assert output =~ "lib/minga_editor/frontend/protocol.ex"
    end)
  end

  @spec with_git_fixture((Path.t() -> any())) :: any()
  defp with_git_fixture(fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "protocol-generated-edits-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    try do
      write_base_files(dir)
      git!(dir, ["init", "-b", "main"])
      git!(dir, ["config", "user.email", "test@example.com"])
      git!(dir, ["config", "user.name", "Protocol Guard Test"])
      git!(dir, ["add", "."])
      git!(dir, ["commit", "-m", "base"])
      git!(dir, ["checkout", "-b", "feature"])
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  @spec write_base_files(Path.t()) :: :ok
  defp write_base_files(dir) do
    write!(dir, "docs/protocol_schema.toml", "version = \"1.0.0\"\n")

    write!(
      dir,
      "macos/Sources/Protocol/ProtocolOpcodes.generated.swift",
      "let OP_KEY_PRESS: UInt8 = 0x01\n"
    )

    write!(dir, "zig/src/protocol_opcodes.zig", "pub const OP_KEY_PRESS: u8 = 0x01;\n")
    write!(dir, "zig/src/protocol_schema_test.zig", "test \"schema\" {}\n")

    write!(dir, "lib/minga_editor/frontend/protocol.ex", """
    defmodule MingaEditor.Frontend.Protocol do
      # --- BEGIN GENERATED (mix protocol.gen) ---
      @op_key_press 0x01
      # --- END GENERATED ---

      def decode, do: :ok
    end
    """)

    :ok
  end

  @spec write!(Path.t(), Path.t(), String.t()) :: :ok
  defp write!(dir, rel_path, content) do
    path = Path.join(dir, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  @spec run_guard(Path.t()) :: {String.t(), non_neg_integer()}
  defp run_guard(dir) do
    System.cmd("python3", [@script, "main"], cd: dir, stderr_to_stdout: true)
  end

  @spec git!(Path.t(), [String.t()]) :: String.t()
  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end
end
