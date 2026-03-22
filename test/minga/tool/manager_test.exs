defmodule Minga.Tool.ManagerTest do
  use ExUnit.Case, async: false

  alias Minga.Events
  alias Minga.Tool.{Installation, Manager}
  alias Minga.Tool.Installer.Stub

  @moduletag timeout: 10_000

  setup do
    # Initialize the stub installer
    Stub.reset()

    # Subscribe to install events so we can await completion without sleeping
    subscribe_install_events()

    # Clean up any tools installed by previous tests.
    # The Manager is a singleton with a global ETS table.
    for inst <- Manager.all_installed() do
      Manager.uninstall(inst.name)
    end

    :ok
  end

  # Subscribe to install events so await_install/1 can receive them.
  # Must be called BEFORE Manager.install so we don't miss the event.
  defp subscribe_install_events do
    Events.subscribe(:tool_install_complete)
    Events.subscribe(:tool_install_failed)
  end

  # Waits for the Manager's async install task to finish by receiving
  # the completion or failure event. No sleeping, no polling.
  defp await_install(tool_name, timeout \\ 2000) do
    receive do
      {:minga_event, :tool_install_complete, %{name: ^tool_name}} -> :ok
      {:minga_event, :tool_install_failed, %{name: ^tool_name}} -> :ok
    after
      timeout -> flunk("Install of #{tool_name} timed out after #{timeout}ms")
    end
  end

  describe "installed?/1" do
    test "returns false for tools not installed" do
      refute Manager.installed?(:pyright)
    end
  end

  describe "all_installed/0" do
    test "returns empty list when nothing is installed" do
      assert Manager.all_installed() == []
    end
  end

  describe "install/1" do
    test "returns error for unknown tool" do
      assert {:error, :unknown_tool} = Manager.install(:nonexistent_xyz)
    end

    test "installs a known tool and records it" do
      Stub.set_install_result({:ok, "1.1.400"})

      assert :ok = Manager.install(:pyright)
      await_install(:pyright)

      # Verify installed
      assert Manager.installed?(:pyright)
      inst = Manager.get_installation(:pyright)
      assert %Installation{name: :pyright, version: "1.1.400", method: :npm} = inst
    end

    test "returns error when already installed" do
      Stub.set_install_result({:ok, "1.0.0"})
      assert :ok = Manager.install(:prettier)
      await_install(:prettier)

      assert {:error, :already_installed} = Manager.install(:prettier)
    end

    test "returns error when already installing" do
      Stub.set_install_delay(500)
      assert :ok = Manager.install(:black)
      assert {:error, :already_installing} = Manager.install(:black)
      await_install(:black)
    end

    test "handles install failure gracefully" do
      Stub.set_install_result({:error, "simulated failure"})

      assert :ok = Manager.install(:gopls)
      await_install(:gopls)

      # Should not be recorded as installed
      refute Manager.installed?(:gopls)
    end

    test "records install in stub history" do
      Stub.set_install_result({:ok, "1.0.0"})
      Manager.install(:stylua)
      await_install(:stylua)

      assert :stylua in Stub.installs()
    end
  end

  describe "uninstall/1" do
    test "returns error for unknown tool" do
      assert {:error, :unknown_tool} = Manager.uninstall(:nonexistent_xyz)
    end

    test "uninstalls an installed tool" do
      Stub.set_install_result({:ok, "1.0.0"})
      Manager.install(:zls)
      await_install(:zls)
      assert Manager.installed?(:zls)

      assert :ok = Manager.uninstall(:zls)
      refute Manager.installed?(:zls)
    end
  end

  describe "tool_status_list/0" do
    test "returns statuses for all known recipes" do
      statuses = Manager.tool_status_list()
      assert length(statuses) >= 12

      # All should have recipe and status
      for s <- statuses do
        assert %{recipe: %Minga.Tool.Recipe{}, status: status} = s
        assert status in [:installed, :installing, :not_installed, :update_available, :failed]
      end
    end

    test "shows installed tools as :installed" do
      Stub.set_install_result({:ok, "1.0.0"})
      Manager.install(:clangd)
      await_install(:clangd)

      statuses = Manager.tool_status_list()
      clangd = Enum.find(statuses, fn s -> s.recipe.name == :clangd end)
      assert clangd.status == :installed
      assert clangd.installed_version == "1.0.0"
    end
  end
end
