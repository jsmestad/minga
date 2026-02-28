defmodule Minga.CLITest do
  use ExUnit.Case, async: true

  alias Minga.CLI

  describe "parse_args/1" do
    test "no arguments returns :no_file" do
      assert CLI.parse_args([]) == :no_file
    end

    test "--help returns error with usage text" do
      assert {:error, message} = CLI.parse_args(["--help"])
      assert message =~ "Usage: minga"
      assert message =~ "--help"
      assert message =~ "--version"
    end

    test "-h returns error with usage text" do
      assert {:error, message} = CLI.parse_args(["-h"])
      assert message =~ "Usage: minga"
    end

    test "--version returns error with version string" do
      assert {:error, message} = CLI.parse_args(["--version"])
      assert message =~ "minga"
      assert message =~ Minga.version()
    end

    test "-v returns error with version string" do
      assert {:error, message} = CLI.parse_args(["-v"])
      assert message =~ "minga"
    end

    test "single file argument returns {:file, path}" do
      assert CLI.parse_args(["README.md"]) == {:file, "README.md"}
    end

    test "file argument with extra args takes the first" do
      assert CLI.parse_args(["file.txt", "--extra"]) == {:file, "file.txt"}
    end

    test "--help takes precedence over file argument" do
      assert {:error, _} = CLI.parse_args(["--help", "file.txt"])
    end
  end

  describe "main/1" do
    test "no arguments returns :ok without crashing" do
      assert :ok = CLI.main([])
    end

    test "file argument returns :ok even when editor isn't running" do
      assert :ok = CLI.main(["nonexistent_file.txt"])
    end
  end
end
