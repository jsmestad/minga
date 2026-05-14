defmodule Minga.CLITest do
  use ExUnit.Case, async: true

  alias Minga.CLI

  describe "parse_args/1" do
    test "no arguments returns {:open, nil, default_flags}" do
      assert {:open, nil, %{force_editor: false, no_context: false, config_file: nil}} =
               CLI.parse_args([])
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
      assert {:open, "README.md", %{force_editor: false, no_context: false, config_file: nil}} =
               CLI.parse_args(["README.md"])
    end

    test "file argument with extra non-flag args takes the last file" do
      assert {:open, "other.txt", %{force_editor: false, no_context: false, config_file: nil}} =
               CLI.parse_args(["file.txt", "other.txt"])
    end

    test "--help takes precedence over file argument" do
      assert {:error, _} = CLI.parse_args(["--help", "file.txt"])
    end

    test "--editor flag sets force_editor" do
      assert {:open, nil, %{force_editor: true, no_context: false, config_file: nil}} =
               CLI.parse_args(["--editor"])
    end

    test "--editor flag with file" do
      assert {:open, "foo.ex", %{force_editor: true, no_context: false, config_file: nil}} =
               CLI.parse_args(["--editor", "foo.ex"])
    end

    test "--no-context flag sets no_context" do
      assert {:open, nil, %{force_editor: false, no_context: true, config_file: nil}} =
               CLI.parse_args(["--no-context"])
    end

    test "--no-context flag with file" do
      assert {:open, "foo.ex", %{force_editor: false, no_context: true, config_file: nil}} =
               CLI.parse_args(["--no-context", "foo.ex"])
    end

    test "--editor and --no-context together" do
      assert {:open, "foo.ex", %{force_editor: true, no_context: true, config_file: nil}} =
               CLI.parse_args(["--editor", "--no-context", "foo.ex"])
    end

    test "flags can appear after file argument" do
      assert {:open, "foo.ex", %{force_editor: true, no_context: false, config_file: nil}} =
               CLI.parse_args(["foo.ex", "--editor"])
    end

    test "--config sets config_file with expanded path" do
      assert {:open, nil, %{config_file: path}} = CLI.parse_args(["--config", "/tmp/custom.exs"])
      assert path == "/tmp/custom.exs"
    end

    test "--config expands relative paths" do
      assert {:open, nil, %{config_file: path}} = CLI.parse_args(["--config", "~/my.exs"])
      assert path == Path.expand("~/my.exs")
      refute path =~ "~"
    end

    test "--config with file argument" do
      assert {:open, "foo.ex", %{config_file: "/tmp/custom.exs"}} =
               CLI.parse_args(["--config", "/tmp/custom.exs", "foo.ex"])
    end

    test "--config combined with --editor" do
      assert {:open, "foo.ex", %{force_editor: true, config_file: "/tmp/c.exs"}} =
               CLI.parse_args(["--config", "/tmp/c.exs", "--editor", "foo.ex"])
    end

    test "--config without a following argument returns error" do
      assert {:error, message} = CLI.parse_args(["--config"])
      assert message =~ "--config requires a path argument"
    end

    test "--config followed by another flag returns error" do
      assert {:error, message} = CLI.parse_args(["--config", "--editor"])
      assert message =~ "--config requires a path argument, not a flag"
    end

    test "--config with empty string returns error" do
      assert {:error, message} = CLI.parse_args(["--config", ""])
      assert message =~ "--config requires a non-empty path argument"
    end

    test "--config flag appears in help output" do
      assert {:error, message} = CLI.parse_args(["--help"])
      assert message =~ "--config"
    end

    test "--headless sets headless flag" do
      assert {:open, nil, %{headless: true}} = CLI.parse_args(["--headless"])
    end

    test "--minimal sets minimal flag" do
      assert {:open, nil, %{minimal: true}} = CLI.parse_args(["--minimal"])
    end

    test "--minimal combined with file argument" do
      assert {:open, "COMMIT_EDITMSG", %{minimal: true}} =
               CLI.parse_args(["--minimal", "COMMIT_EDITMSG"])
    end

    test "--name, --cookie, --host, and --port set distribution flags" do
      cookie = "abcdefghijklmnopqrstuvwxyz123456"

      assert {:open, nil,
              %{
                node_name: "minga@host",
                cookie: ^cookie,
                gateway_host: "127.0.0.1",
                gateway_port: 4900
              }} =
               CLI.parse_args([
                 "--headless",
                 "--name",
                 "minga@host",
                 "--cookie",
                 cookie,
                 "--host",
                 "127.0.0.1",
                 "--port",
                 "4900"
               ])
    end

    test "--cookie-file sets expanded cookie file path" do
      assert {:open, nil, %{cookie_file: path}} =
               CLI.parse_args(["--cookie-file", "~/minga.cookie"])

      assert path == Path.expand("~/minga.cookie")
    end

    test "--sname sets short name mode" do
      assert {:open, nil, %{node_name: "minga", short_name: true}} =
               CLI.parse_args(["--sname", "minga"])
    end

    test "--port validates numeric range" do
      assert {:error, message} = CLI.parse_args(["--port", "70000"])
      assert message =~ "--port requires a TCP port"
    end

    test "--host rejects hostnames and malformed IP addresses" do
      assert {:error, message} = CLI.parse_args(["--host", "example.com"])
      assert message =~ "--host requires a valid IP address"
    end

    test "unknown flag returns error" do
      assert {:error, message} = CLI.parse_args(["--unknown"])
      assert message =~ "unknown flag: --unknown"
    end

    test "usage text includes --editor, --no-context, --config, and --minimal" do
      assert {:error, message} = CLI.parse_args(["--help"])
      assert message =~ "--editor"
      assert message =~ "--no-context"
      assert message =~ "--config"
      assert message =~ "--minimal"
    end
  end

  describe "startup_flags/0" do
    test "returns default flags when no CLI flags were set" do
      # Clear any flags from other tests
      Application.delete_env(:minga, :cli_startup_flags)
      assert %{force_editor: false, no_context: false, config_file: nil} = CLI.startup_flags()
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
      assert %{force_editor: true, no_context: false, config_file: nil} = CLI.startup_flags()
    after
      Application.delete_env(:minga, :cli_startup_flags)
    end

    test "main stores config_file flag from --config" do
      Application.delete_env(:minga, :cli_startup_flags)
      CLI.main(["--config", "/tmp/test_config.exs"])
      assert %{config_file: "/tmp/test_config.exs"} = CLI.startup_flags()
    after
      Application.delete_env(:minga, :cli_startup_flags)
    end
  end

  describe "apply_flag_implications/1" do
    test "minimal implies force_editor" do
      {:open, _, flags} = CLI.parse_args(["--minimal", "COMMIT_EDITMSG"])
      result = CLI.apply_flag_implications(flags)
      assert result.force_editor == true
      assert result.minimal == true
    end

    test "force_editor alone is preserved, does not set minimal" do
      {:open, _, flags} = CLI.parse_args(["--editor"])
      result = CLI.apply_flag_implications(flags)
      assert result.force_editor == true
      assert result.minimal == false
    end

    test "neither flag leaves both false" do
      {:open, _, flags} = CLI.parse_args([])
      result = CLI.apply_flag_implications(flags)
      assert result.force_editor == false
      assert result.minimal == false
    end
  end
end
