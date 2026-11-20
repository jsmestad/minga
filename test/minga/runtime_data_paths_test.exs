defmodule Minga.RuntimeDataPathsTest do
  # Each test starts a child BEAM through an OS process.
  use ExUnit.Case, async: false

  alias Minga.Test.ElixirSubprocess

  @moduletag :tmp_dir
  @moduletag timeout: 30_000
  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

  test "default state paths follow the runtime XDG data home", %{tmp_dir: tmp_dir} do
    code = """
    IO.puts(Minga.Session.session_file())
    IO.puts(Minga.Session.Swap.swap_dir())
    IO.puts(Minga.Session.EventRecorder.db_path())
    IO.puts(MingaAgent.EventLog.db_path())
    IO.puts(Minga.Extension.Git.extension_path(:example))
    IO.puts(Minga.Extension.Storage.data_dir(:example))

    runtime_config = Config.Reader.read!(hd(System.argv()))
    {:file, log_path} = get_in(runtime_config, [:logger, :default_handler, :config, :type])
    IO.puts(log_path)
    """

    {output, 0} =
      ElixirSubprocess.eval(code, [@runtime_config],
        env: [{"XDG_DATA_HOME", tmp_dir}, {"MINGA_PORT_MODE", "connected"}],
        stderr_to_stdout: true
      )

    assert String.split(output, "\n", trim: true) == [
             Path.join(tmp_dir, "minga/sessions/session.json"),
             Path.join(tmp_dir, "minga/swap"),
             Path.join(tmp_dir, "minga/events.db"),
             Path.join(tmp_dir, "minga/agent_events.db"),
             Path.join(tmp_dir, "minga/extensions/example"),
             Path.join(tmp_dir, "minga/extensions/example/data"),
             Path.join(tmp_dir, "minga/minga.log")
           ]
  end

  test "relative, empty, and unset XDG roots use the normal home defaults", %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    File.mkdir!(home)

    code = """
    [home, config_file] = System.argv()
    ^home = System.user_home!()

    for value <- ["relative-state", "", nil] do
      for name <- ~w(XDG_CONFIG_HOME XDG_DATA_HOME) do
        if is_nil(value), do: System.delete_env(name), else: System.put_env(name, value)
      end

      IO.puts(Minga.Language.Grammar.user_query_dir("example"))
      IO.puts(Minga.Extension.Storage.data_dir(:example))

      runtime_config = Config.Reader.read!(config_file)
      {:file, log_path} = get_in(runtime_config, [:logger, :default_handler, :config, :type])
      IO.puts(log_path)
    end
    """

    {output, status} =
      ElixirSubprocess.eval(code, [home, @runtime_config],
        cd: tmp_dir,
        env: [{"HOME", home}, {"MINGA_PORT_MODE", "connected"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    expected_paths = [
      Path.join(home, ".config/minga/queries/example"),
      Path.join(home, ".local/share/minga/extensions/example/data"),
      Path.join(home, ".local/share/minga/minga.log")
    ]

    assert String.split(output, "\n", trim: true) ==
             Enum.flat_map(1..3, fn _ -> expected_paths end)

    refute File.exists?(Path.join(tmp_dir, "relative-state"))
    refute File.exists?(Path.join(tmp_dir, "minga"))
  end
end
