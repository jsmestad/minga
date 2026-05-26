defmodule Minga.CLITest do
  # Not async: CLI startup flag tests mutate Application env, which races with editor startup tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.CLI

  setup do
    if Process.whereis(Minga.EventBus) == nil do
      start_supervised!(Minga.Events.child_spec(name: Minga.EventBus))
    end

    :ok
  end

  describe "parse_args/1" do
    test "no arguments returns {:open, nil, default_flags}" do
      assert {:open, nil, %{view_mode: :auto, no_context: false, config_file: nil}} =
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
      assert {:open, "README.md", %{view_mode: :auto, no_context: false, config_file: nil}} =
               CLI.parse_args(["README.md"])
    end

    test "file argument with extra non-flag args takes the last file" do
      assert {:open, "other.txt", %{view_mode: :auto, no_context: false, config_file: nil}} =
               CLI.parse_args(["file.txt", "other.txt"])
    end

    test "--help takes precedence over file argument" do
      assert {:error, _} = CLI.parse_args(["--help", "file.txt"])
    end

    test "--editor flag sets view_mode" do
      assert {:open, nil, %{view_mode: :editor, no_context: false, config_file: nil}} =
               CLI.parse_args(["--editor"])
    end

    test "--editor flag with file" do
      assert {:open, "foo.ex", %{view_mode: :editor, no_context: false, config_file: nil}} =
               CLI.parse_args(["--editor", "foo.ex"])
    end

    test "--no-context flag sets no_context" do
      assert {:open, nil, %{view_mode: :auto, no_context: true, config_file: nil}} =
               CLI.parse_args(["--no-context"])
    end

    test "--no-context flag with file" do
      assert {:open, "foo.ex", %{view_mode: :auto, no_context: true, config_file: nil}} =
               CLI.parse_args(["--no-context", "foo.ex"])
    end

    test "--editor and --no-context together" do
      assert {:open, "foo.ex", %{view_mode: :editor, no_context: true, config_file: nil}} =
               CLI.parse_args(["--editor", "--no-context", "foo.ex"])
    end

    test "flags can appear after file argument" do
      assert {:open, "foo.ex", %{view_mode: :editor, no_context: false, config_file: nil}} =
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
      assert {:open, "foo.ex", %{view_mode: :editor, config_file: "/tmp/c.exs"}} =
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

    test "--safe enables safe mode" do
      assert {:open, nil, %{safe_mode: true}} = CLI.parse_args(["--safe"])
    end

    test "-Q enables safe mode" do
      assert {:open, nil, %{safe_mode: true}} = CLI.parse_args(["-Q"])
    end

    test "--safe flag appears in help output" do
      assert {:error, message} = CLI.parse_args(["--help"])
      assert message =~ "--safe"
      assert message =~ "-Q"
    end

    test "safe_args?/1 detects long and short safe mode flags" do
      assert CLI.safe_args?(["--safe"])
      assert CLI.safe_args?(["-Q"])
      refute CLI.safe_args?(["README.md"])
    end

    test "--debug-log sets expanded debug log path" do
      assert {:open, nil, %{debug_log: path}} =
               CLI.parse_args(["--debug-log", "~/minga-debug.log"])

      assert path == Path.expand("~/minga-debug.log")
    end

    test "-D sets expanded debug log path" do
      assert {:open, nil, %{debug_log: path}} = CLI.parse_args(["-D", "debug.log"])
      assert path == Path.expand("debug.log")
    end

    test "--debug-log without a following argument returns error" do
      assert {:error, message} = CLI.parse_args(["--debug-log"])
      assert message =~ "--debug-log requires a path argument"
    end

    test "--debug-log followed by another flag returns error" do
      assert {:error, message} = CLI.parse_args(["--debug-log", "--editor"])
      assert message =~ "--debug-log requires a path argument, not a flag"
    end

    test "-D followed by another flag returns error" do
      assert {:error, message} = CLI.parse_args(["-D", "--editor"])
      assert message =~ "-D requires a path argument, not a flag"
    end

    test "--debug-log with empty string returns error" do
      assert {:error, message} = CLI.parse_args(["--debug-log", ""])
      assert message =~ "--debug-log requires a non-empty path argument"
    end

    test "-D with empty string returns error" do
      assert {:error, message} = CLI.parse_args(["-D", ""])
      assert message =~ "-D requires a non-empty path argument"
    end

    test "-D without a following argument returns error" do
      assert {:error, message} = CLI.parse_args(["-D"])
      assert message =~ "-D requires a path argument"
    end

    test "--debug-log flag appears in help output" do
      assert {:error, message} = CLI.parse_args(["--help"])
      assert message =~ "--debug-log"
      assert message =~ "-D"
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

    test "usage text includes --editor, --no-context, --config, --debug-log, and --minimal" do
      assert {:error, message} = CLI.parse_args(["--help"])
      assert message =~ "--editor"
      assert message =~ "--no-context"
      assert message =~ "--config"
      assert message =~ "--debug-log"
      assert message =~ "--minimal"
    end

    test "usage text describes file and directory startup behavior" do
      assert {:error, message} = CLI.parse_args(["--help"])
      assert message =~ "minga README.md                    Open file for editing"

      assert message =~
               "minga .                            Start agentic view with project as context"

      assert message =~ "Keep agentic view and don't load the file as agent context"
    end
  end

  describe "startup_project_root_from_args/1" do
    test "detects directory targets and files inside marked projects" do
      root = tmp_dir("cli-project-root")
      File.write!(Path.join(root, "mix.exs"), "defmodule Example.MixProject do\nend\n")
      file = Path.join([root, "lib", "example.ex"])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule Example do\nend\n")

      assert CLI.startup_project_root_from_args([root]) == root
      assert CLI.startup_project_root_from_args([file]) == root
      assert CLI.startup_project_root_from_args(["--help"]) == nil
    end

    test "directory targets prefer the nearest marked project root over the literal directory" do
      root = tmp_dir("cli-nested-project-root")
      nested = Path.join([root, "apps", "web"])
      File.write!(Path.join(root, "mix.exs"), "defmodule Example.MixProject do\nend\n")
      File.mkdir_p!(nested)

      assert CLI.startup_project_root_from_args([nested]) == root
    end

    test "unmarked directory targets fall back to the literal directory" do
      root = tmp_dir("cli-unmarked-project-root")
      nested = Path.join(root, "notes")
      File.mkdir_p!(nested)

      assert CLI.startup_project_root_from_args([nested]) == nested
    end

    test "cwd inference returns only marked project roots" do
      root = tmp_dir("cli-cwd-project-root")
      nested = Path.join([root, "apps", "web"])
      File.write!(Path.join(root, "mix.exs"), "defmodule Example.MixProject do\nend\n")
      File.mkdir_p!(nested)

      assert canonical_path(CLI.cwd_startup_project_root(nested)) == canonical_path(root)

      unmarked = tmp_dir("cli-cwd-unmarked")
      assert CLI.cwd_startup_project_root(unmarked) == nil
    end

    test "argv inference logs unexpected failures instead of silently swallowing them" do
      log =
        capture_log(fn -> assert CLI.argv_startup_project_root(fn -> raise "boom" end) == nil end)

      assert log =~ "Could not infer startup project root from argv"
      assert log =~ "boom"
    end
  end

  describe "startup_flags/0" do
    test "returns default flags when no CLI flags were set" do
      Application.delete_env(:minga, :cli_startup_flags)
      assert %{view_mode: :auto, no_context: false, config_file: nil} = CLI.startup_flags()
    end

    test "merges sparse stored flags with defaults" do
      Application.put_env(:minga, :cli_startup_flags, %{config_file: "/tmp/custom.exs"})

      assert %{view_mode: :auto, no_context: false, config_file: "/tmp/custom.exs"} =
               CLI.startup_flags()
    after
      Application.delete_env(:minga, :cli_startup_flags)
    end
  end

  describe "main/1" do
    test "no arguments returns :ok without crashing" do
      assert :ok = CLI.main([])
    after
      Application.delete_env(:minga, :cli_startup_flags)
      Application.delete_env(:minga, :cli_startup_project_root)
    end

    test "file argument returns :ok even when editor isn't running" do
      assert :ok = CLI.main(["nonexistent_file.txt"])
    after
      Application.delete_env(:minga, :cli_startup_flags)
      Application.delete_env(:minga, :cli_startup_project_root)
    end

    test "directory argument stores agentic startup mode and startup project root" do
      Application.delete_env(:minga, :cli_startup_flags)
      Application.delete_env(:minga, :cli_startup_project_root)
      root = System.tmp_dir!()

      assert :ok = CLI.main([root])
      assert %{view_mode: :agentic, no_context: false, config_file: nil} = CLI.startup_flags()
      assert CLI.startup_project_root() == Path.expand(root)
    after
      Application.delete_env(:minga, :cli_startup_flags)
      Application.delete_env(:minga, :cli_startup_project_root)
    end

    test "main stores startup flags in application env" do
      Application.delete_env(:minga, :cli_startup_flags)
      CLI.main(["--editor", "some_file.ex"])
      assert %{view_mode: :editor, no_context: false, config_file: nil} = CLI.startup_flags()
    after
      Application.delete_env(:minga, :cli_startup_flags)
      Application.delete_env(:minga, :cli_startup_project_root)
    end

    test "main stores config_file flag from --config" do
      Application.delete_env(:minga, :cli_startup_flags)
      CLI.main(["--config", "/tmp/test_config.exs"])
      assert %{view_mode: :auto, config_file: "/tmp/test_config.exs"} = CLI.startup_flags()
    after
      Application.delete_env(:minga, :cli_startup_flags)
      Application.delete_env(:minga, :cli_startup_project_root)
    end

    test "main stores debug_log path in application env" do
      path =
        Path.join(System.tmp_dir!(), "minga_cli_debug_#{System.unique_integer([:positive])}.log")

      Application.delete_env(:minga, :cli_startup_flags)

      CLI.main(["--debug-log", path])

      assert %{debug_log: ^path} = CLI.startup_flags()
      assert Application.get_env(:minga, :debug_log_path) == path
    after
      if pid = Process.whereis(Minga.DebugLog) do
        assert :ok = Minga.DebugLog.stop(pid)
      end

      Application.delete_env(:minga, :cli_startup_flags)
      Application.delete_env(:minga, :debug_log_path)
    end
  end

  describe "apply_flag_implications/1" do
    test "minimal implies editor view" do
      {:open, _, flags} = CLI.parse_args(["--minimal", "COMMIT_EDITMSG"])
      result = CLI.apply_flag_implications(flags)
      assert result.view_mode == :editor
      assert result.minimal == true
    end

    test "editor view alone is preserved, does not set minimal" do
      {:open, _, flags} = CLI.parse_args(["--editor"])
      result = CLI.apply_flag_implications(flags)
      assert result.view_mode == :editor
      assert result.minimal == false
    end

    test "neither flag leaves view mode auto" do
      {:open, _, flags} = CLI.parse_args([])
      result = CLI.apply_flag_implications(flags)
      assert result.view_mode == :auto
      assert result.minimal == false
    end
  end

  describe "apply_flag_implications/2" do
    test "regular file resolves auto view to editor" do
      path =
        Path.join(System.tmp_dir!(), "minga_cli_file_#{System.unique_integer([:positive])}.ex")

      File.write!(path, "IO.puts(:ok)\n")
      on_exit(fn -> File.rm(path) end)

      {:open, _, flags} = CLI.parse_args([path])
      result = CLI.apply_flag_implications(flags, path)
      assert result.view_mode == :editor
    end

    test "directory resolves auto view to agentic" do
      {:open, _, flags} = CLI.parse_args([System.tmp_dir!()])
      result = CLI.apply_flag_implications(flags, System.tmp_dir!())
      assert result.view_mode == :agentic
    end

    test "nil leaves auto view unresolved" do
      {:open, _, flags} = CLI.parse_args([])
      result = CLI.apply_flag_implications(flags, nil)
      assert result.view_mode == :auto
    end

    test "no-context resolves auto view to agentic" do
      {:open, file, flags} = CLI.parse_args(["--no-context", "foo.ex"])
      result = CLI.apply_flag_implications(flags, file)
      assert result.view_mode == :agentic
      assert result.no_context == true
    end

    test "explicit editor view wins over no-context" do
      {:open, file, flags} = CLI.parse_args(["--editor", "--no-context", "foo.ex"])
      result = CLI.apply_flag_implications(flags, file)
      assert result.view_mode == :editor
      assert result.no_context == true
    end

    test "nonexistent file path resolves auto view to editor" do
      path =
        Path.join(System.tmp_dir!(), "minga_missing_#{System.unique_integer([:positive])}.ex")

      {:open, _, flags} = CLI.parse_args([path])
      result = CLI.apply_flag_implications(flags, path)
      assert result.view_mode == :editor
    end
  end

  defp canonical_path(path) do
    path
    |> Path.expand()
    |> String.replace_prefix("/private/var/", "/var/")
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "minga-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
