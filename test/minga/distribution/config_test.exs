defmodule Minga.Distribution.ConfigTest do
  use ExUnit.Case, async: true

  alias Minga.Distribution.Config

  test "load/1 returns [] when file is missing" do
    path = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.exs")
    assert Config.load(path) == []
  end

  test "load/1 accepts valid server entries" do
    path =
      temp_file("servers.exs", """
      [
        %{name: "home", node: :\"minga_server@home.test\", cookie: :abcdefghijklmnopqrstuvwxyz123456}
      ]
      """)

    assert [
             %{
               name: "home",
               node: :"minga_server@home.test",
               cookie: :abcdefghijklmnopqrstuvwxyz123456
             }
           ] = Config.load(path)
  end

  test "load/1 rejects malformed entries" do
    path = temp_file("bad_servers.exs", "[%{name: :bad, node: :node, cookie: :cookie}]")
    assert Config.load(path) == []
  end

  test "load/1 rejects weak cookies" do
    path = temp_file("weak_servers.exs", ~s([%{name: "home", node: :node, cookie: :short}]))
    assert Config.load(path) == []
  end

  @spec temp_file(String.t(), String.t()) :: String.t()
  defp temp_file(name, content) do
    dir = Path.join(System.tmp_dir!(), "minga-config-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end
end
