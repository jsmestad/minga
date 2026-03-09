defmodule Minga.CLITest do
  use ExUnit.Case, async: true

  alias Minga.CLI

  describe "parse_args/1" do
    test "no arguments returns {:open, nil, default_flags}" do
      assert {:open, nil, %{force_editor: false, no_context: false}} = CLI.parse_args([])
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

    test "single file argument returns {:open, path, flags}" do
      assert {:open, "README.md", %{force_editor: false, no_context: false}} =
               CLI.parse_args(["README.md"])
    end

    test "file argument with extra non-flag args takes the last file" do
      assert {:open, "other.txt", %{force_editor: false, no_context: false}} =
               CLI.parse_args(["file.txt", "other.txt"])
    end

    test "--help takes precedence over file argument" do
      assert {:error, _} = CLI.parse_args(["--help", "file.txt"])
    end

    test "--editor flag sets force_editor" do
      assert {:open, nil, %{force_editor: true, no_context: false}} =
               CLI.parse_args(["--editor"])
    end

    test "--editor flag with file" do
      assert {:open, "foo.ex", %{force_editor: true, no_context: false}} =
               CLI.parse_args(["--editor", "foo.ex"])
    end

    test "--no-context flag sets no_context" do
      assert {:open, nil, %{force_editor: false, no_context: true}} =
               CLI.parse_args(["--no-context"])
    end

    test "--no-context flag with file" do
      assert {:open, "foo.ex", %{force_editor: false, no_context: true}} =
               CLI.parse_args(["--no-context", "foo.ex"])
    end

    test "--editor and --no-context together" do
      assert {:open, "foo.ex", %{force_editor: true, no_context: true}} =
               CLI.parse_args(["--editor", "--no-context", "foo.ex"])
    end

    test "flags can appear after file argument" do
      assert {:open, "foo.ex", %{force_editor: true, no_context: false}} =
               CLI.parse_args(["foo.ex", "--editor"])
    end

    test "unknown flag returns error" do
      assert {:error, message} = CLI.parse_args(["--unknown"])
      assert message =~ "unknown flag: --unknown"
    end

    test "usage text includes --editor and --no-context" do
      assert {:error, message} = CLI.parse_args(["--help"])
      assert message =~ "--editor"
      assert message =~ "--no-context"
    end
  end

  describe "startup_flags/0" do
    test "returns default flags when no CLI flags were set" do
      # Clear any flags from other tests
      Application.delete_env(:minga, :cli_startup_flags)
      assert %{force_editor: false, no_context: false} = CLI.startup_flags()
    end
  end

  describe "main/1" do
    test "no arguments returns :ok without crashing" do
      assert :ok = CLI.main([])
    end

    test "file argument returns :ok even when editor isn't running" do
      assert :ok = CLI.main(["nonexistent_file.txt"])
    end

    test "main stores startup flags in application env" do
      Application.delete_env(:minga, :cli_startup_flags)
      CLI.main(["--editor", "some_file.ex"])
      assert %{force_editor: true, no_context: false} = CLI.startup_flags()
    after
      Application.delete_env(:minga, :cli_startup_flags)
    end
  end
end
