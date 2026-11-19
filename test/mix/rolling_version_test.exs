defmodule Minga.RollingVersionTest do
  # Starts a separate Elixir VM, which shares the host Erlang child-process launcher.
  use ExUnit.Case, async: false
  @moduletag timeout: 30_000

  test "only prod accepts a rolling version based on the project version and embeds it in Minga" do
    # Mix.env and the version override are process-wide, so use an isolated VM.
    code = ~S'''
    import ExUnit.Assertions

    Mix.start()
    base = Mix.Project.in_project(:minga, ".", fn _ -> Mix.Project.config()[:version] end)
    assert base =~ ~r/\A[0-9]+\.[0-9]+\.[0-9]+\z/
    rolling = base <> "-dev.123"
    System.put_env("MINGA_ROLLING_VERSION", rolling)

    for env <- [:dev, :test] do
      Mix.env(env)
      Mix.Project.in_project(:minga, ".", fn _ -> assert Mix.Project.config()[:version] == base end)
    end

    Mix.env(:prod)
    Mix.Project.in_project(:minga, ".", fn project ->
      assert Mix.Project.config()[:version] == rolling
      Code.compile_file("lib/minga.ex")

      for invalid <- ["", base, "wrong", base <> "-dev.0", base <> "-dev.01",
                      base <> "-dev.-1", base <> "-dev.١", rolling <> "\n",
                      rolling <> "+local", "999.999.999-dev.123"] do
        System.put_env("MINGA_ROLLING_VERSION", invalid)

        assert_raise Mix.Error, ~r/MINGA_ROLLING_VERSION must be/, fn ->
          project.project()
        end
      end

      System.delete_env("MINGA_ROLLING_VERSION")
      assert apply(Minga, :version, []) == rolling
    end)
    '''

    {output, status} =
      System.cmd("elixir", ["-e", code],
        cd: Path.expand("../..", __DIR__),
        env: [{"MIX_ENV", "prod"}, {"MINGA_ROLLING_VERSION", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
