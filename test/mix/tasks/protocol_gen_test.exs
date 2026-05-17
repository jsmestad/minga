# This module changes the working directory to exercise a Mix task that resolves repo-local paths.
defmodule Mix.Tasks.Protocol.GenTest do
  # Changes the process working directory while exercising the repo-local Mix task.
  use ExUnit.Case, async: false

  @repo_root File.cwd!()
  @fixture_paths [
    "docs/protocol_schema.toml"
  ]
  @generated_paths [
    ".generated/protocol/elixir/lib/minga/protocol/opcodes.ex",
    ".generated/protocol/swift/ProtocolOpcodes.generated.swift",
    "zig/src/generated/protocol_opcodes.zig",
    "zig/src/generated/protocol_schema_test.zig"
  ]

  test "generates protocol artifacts into ignored build locations" do
    with_fixture_dir(fn dir ->
      File.cd!(dir, fn ->
        assert :ok = Mix.Tasks.Protocol.Gen.run([])
      end)

      for rel_path <- @generated_paths do
        path = Path.join(dir, rel_path)
        assert File.exists?(path), "expected #{rel_path} to be generated"
        assert File.read!(path) =~ "Generated from `docs/protocol_schema.toml`"
      end
    end)
  end

  test "--check passes against generated artifacts" do
    with_fixture_dir(fn dir ->
      File.cd!(dir, fn ->
        assert :ok = Mix.Tasks.Protocol.Gen.run([])
        assert :ok = Mix.Tasks.Protocol.Gen.run(["--check"])
      end)
    end)
  end

  test "--check fails when a generated artifact drifts" do
    with_fixture_dir(fn dir ->
      File.cd!(dir, fn ->
        assert :ok = Mix.Tasks.Protocol.Gen.run([])
      end)

      Path.join([dir, ".generated/protocol/swift/ProtocolOpcodes.generated.swift"])
      |> File.write!("let OP_KEY_PRESS: UInt8 = 0x02\n")

      File.cd!(dir, fn ->
        assert_raise Mix.Error, ~r/Generated protocol artifacts are out of date/, fn ->
          Mix.Tasks.Protocol.Gen.run(["--check"])
        end
      end)
    end)
  end

  test "--check fails when generated artifacts are missing" do
    with_fixture_dir(fn dir ->
      File.cd!(dir, fn ->
        assert_raise Mix.Error, ~r/Run `mix protocol.gen`/, fn ->
          Mix.Tasks.Protocol.Gen.run(["--check"])
        end
      end)
    end)
  end

  test "rejects duplicate opcode values" do
    with_fixture_dir(fn dir ->
      mutate_schema(dir, fn schema ->
        String.replace(
          schema,
          "name = \"resize\"\nvalue = 0x02",
          "name = \"resize\"\nvalue = 0x01",
          global: false
        )
      end)

      File.cd!(dir, fn ->
        assert_raise Mix.Error, ~r/Duplicate opcode values/, fn ->
          Mix.Tasks.Protocol.Gen.run([])
        end
      end)
    end)
  end

  test "rejects duplicate gui action values" do
    with_fixture_dir(fn dir ->
      mutate_schema(dir, fn schema ->
        String.replace(
          schema,
          "name = \"git_open_diff\"\nvalue = 0x42",
          "name = \"git_open_diff\"\nvalue = 0x1E",
          global: false
        )
      end)

      File.cd!(dir, fn ->
        assert_raise Mix.Error, ~r/Duplicate GUI action values/, fn ->
          Mix.Tasks.Protocol.Gen.run([])
        end
      end)
    end)
  end

  test "rejects invalid opcode categories" do
    with_fixture_dir(fn dir ->
      mutate_schema(dir, fn schema ->
        String.replace(schema, "category = \"render\"", "category = \"rendering\"", global: false)
      end)

      File.cd!(dir, fn ->
        assert_raise Mix.Error, ~r/Invalid opcode categories/, fn ->
          Mix.Tasks.Protocol.Gen.run([])
        end
      end)
    end)
  end

  test "rejects invalid opcode directions" do
    with_fixture_dir(fn dir ->
      mutate_schema(dir, fn schema ->
        String.replace(schema, "direction = \"beam_to_frontend\"", "direction = \"sideways\"",
          global: false
        )
      end)

      File.cd!(dir, fn ->
        assert_raise Mix.Error, ~r/Invalid opcode directions/, fn ->
          Mix.Tasks.Protocol.Gen.run([])
        end
      end)
    end)
  end

  test "rejects invalid gui_action canonical references" do
    with_fixture_dir(fn dir ->
      mutate_schema(dir, fn schema ->
        String.replace(schema, "canonical = \"git_commit\"", "canonical = \"missing_action\"",
          global: false
        )
      end)

      File.cd!(dir, fn ->
        assert_raise Mix.Error, ~r/Invalid gui_action canonical references/, fn ->
          Mix.Tasks.Protocol.Gen.run([])
        end
      end)
    end)
  end

  @spec with_fixture_dir((Path.t() -> any())) :: any()
  defp with_fixture_dir(fun) do
    dir = Path.join(System.tmp_dir!(), "protocol-gen-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    copy_fixtures(dir)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  @spec copy_fixtures(Path.t()) :: :ok
  defp copy_fixtures(dir) do
    Enum.each(@fixture_paths, fn rel_path ->
      source = Path.join(@repo_root, rel_path)
      destination = Path.join(dir, rel_path)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
    end)

    :ok
  end

  @spec mutate_schema(Path.t(), (String.t() -> String.t())) :: :ok
  defp mutate_schema(dir, fun) do
    path = Path.join(dir, "docs/protocol_schema.toml")
    path |> File.read!() |> fun.() |> then(&File.write!(path, &1))
    :ok
  end
end
