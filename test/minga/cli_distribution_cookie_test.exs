defmodule Minga.CLIDistributionCookieTest do
  # Mutates the process-wide Erlang distribution state and MINGA_COOKIE environment variable.
  use ExUnit.Case, async: false

  alias Minga.CLI

  setup do
    original_env = System.get_env("MINGA_COOKIE")
    original_release_cookie = System.get_env("RELEASE_COOKIE")
    original_random_marker = System.get_env("MINGA_RANDOM_RELEASE_COOKIE")

    on_exit(fn ->
      restore_env("MINGA_COOKIE", original_env)
      restore_env("RELEASE_COOKIE", original_release_cookie)
      restore_env("MINGA_RANDOM_RELEASE_COOKIE", original_random_marker)
      if Node.alive?(), do: Node.stop()
    end)

    :ok
  end

  test "distribution startup fails closed when no explicit cookie exists" do
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    System.delete_env("MINGA_COOKIE")
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    System.delete_env("RELEASE_COOKIE")
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    System.delete_env("MINGA_RANDOM_RELEASE_COOKIE")
    assert {:error, message} = CLI.distribution_cookie(%{})
    assert message =~ "requires an explicit strong MINGA_COOKIE"
  end

  test "non-distributed launch rejects an unexpectedly distributed VM" do
    assert {:error, :unexpected_distribution} =
             Minga.Application.ensure_expected_distribution_state(true, "0")

    assert :ok = Minga.Application.ensure_expected_distribution_state(false, "0")
    assert :ok = Minga.Application.ensure_expected_distribution_state(true, "1")
  end

  test "a generated fallback cookie is not accepted as explicit distribution intent" do
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    System.delete_env("MINGA_COOKIE")
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    System.put_env("RELEASE_COOKIE", "abcdefghijklmnopqrstuvwxyz123456")
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    System.put_env("MINGA_RANDOM_RELEASE_COOKIE", "1")

    assert {:error, _message} = CLI.distribution_cookie(%{})
  end

  test "weak cookies fail before the node starter runs" do
    assert {:error, message} =
             CLI.start_node_with_cookie(:unused@localhost, :longnames, "weak", fn _name, _mode ->
               flunk("node starter must not run before cookie validation")
             end)

    assert message =~ "at least 32 bytes"
  end

  test "a validated strong cookie is installed before the node starter runs" do
    cookie = "abcdefghijklmnopqrstuvwxyz123456"
    parent = self()

    preflight = fn cookie_atom ->
      send(parent, {:cookie_installed, cookie_atom})
      :ok
    end

    starter = fn _name, _mode ->
      assert_received {:cookie_installed, :abcdefghijklmnopqrstuvwxyz123456}
      :ok
    end

    assert :ok =
             CLI.start_node_with_cookie(
               :unused@localhost,
               :longnames,
               cookie,
               starter,
               preflight
             )
  end

  test "a strong cookie that was not installed at VM startup fails before distribution starts" do
    starter = fn _name, _mode -> flunk("node starter must not run with an uninstalled cookie") end

    assert {:error, message} =
             CLI.start_node_with_cookie(
               :unused@localhost,
               :longnames,
               "abcdefghijklmnopqrstuvwxyz123456",
               starter
             )

    assert message in [
             "Erlang distribution cookie was not installed before VM startup; set RELEASE_COOKIE or start the VM with -setcookie",
             "Erlang distribution cookie does not match the cookie installed at VM startup"
           ]
  end

  # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
  defp restore_env(name, nil), do: System.delete_env(name)

  # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
  defp restore_env(name, value), do: System.put_env(name, value)
end
