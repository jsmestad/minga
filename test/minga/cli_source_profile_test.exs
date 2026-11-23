defmodule Minga.CLISourceProfileTest do
  use ExUnit.Case, async: true

  alias Minga.CLI

  @profile "/work/.minga-dev/profile"

  defp launcher_env(overrides \\ %{}) do
    Map.merge(
      %{
        "MINGA_DEV_PROFILE" => @profile,
        "HOME" => Path.join(@profile, "home"),
        "XDG_CONFIG_HOME" => Path.join(@profile, "config"),
        "XDG_DATA_HOME" => Path.join(@profile, "data"),
        "XDG_CACHE_HOME" => Path.join(@profile, "cache"),
        "XDG_STATE_HOME" => Path.join(@profile, "state"),
        "TMPDIR" => Path.join(@profile, "tmp")
      },
      overrides
    )
  end

  describe "source_profile_env?/1" do
    test "accepts the isolated environment a source launcher prepares" do
      assert CLI.source_profile_env?(launcher_env())
    end

    test "accepts the real HOME only when the launcher opted into it" do
      real_home = %{"HOME" => "/Users/someone"}

      assert CLI.source_profile_env?(launcher_env(Map.put(real_home, "MINGA_DEV_REAL_HOME", "1")))
      refute CLI.source_profile_env?(launcher_env(real_home))

      refute CLI.source_profile_env?(
               launcher_env(Map.put(real_home, "MINGA_DEV_REAL_HOME", "true"))
             )

      refute CLI.source_profile_env?(
               launcher_env(%{"MINGA_DEV_REAL_HOME" => "1", "HOME" => "relative"})
             )
    end

    test "rejects an environment whose Minga roots leave the profile, even with the real HOME opt-in" do
      for key <- [
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "XDG_CACHE_HOME",
            "XDG_STATE_HOME",
            "TMPDIR"
          ],
          opt_in <- [%{}, %{"MINGA_DEV_REAL_HOME" => "1", "HOME" => "/Users/someone"}] do
        refute CLI.source_profile_env?(
                 launcher_env(Map.put(opt_in, key, "/Users/someone/.config"))
               ),
               "accepted #{key} outside the profile with #{inspect(opt_in)}"

        refute CLI.source_profile_env?(launcher_env(opt_in) |> Map.delete(key)),
               "accepted a missing #{key} with #{inspect(opt_in)}"
      end
    end

    test "rejects an environment without an absolute development profile" do
      refute CLI.source_profile_env?(Map.delete(launcher_env(), "MINGA_DEV_PROFILE"))
      refute CLI.source_profile_env?(%{})
    end
  end
end
