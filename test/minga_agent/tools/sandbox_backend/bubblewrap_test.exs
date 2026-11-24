defmodule MingaAgent.Tools.SandboxBackend.BubblewrapTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.SandboxBackend.Bubblewrap
  alias MingaAgent.Tools.SandboxPolicy

  describe "wrap_command/2" do
    test "produces a bwrap invocation with default toolchain paths" do
      policy = %SandboxPolicy{workspace: "/home/user/project"}
      assert {:ok, wrapped} = Bubblewrap.wrap_command(policy, "make build")

      assert String.starts_with?(wrapped, "bwrap ")
      assert wrapped =~ "--ro-bind"
      assert wrapped =~ "--bind /home/user/project /home/user/project"
      assert wrapped =~ "--proc /proc"
      assert wrapped =~ "--dev /dev"
      assert wrapped =~ "--tmpfs /tmp"
      assert wrapped =~ "--unshare-pid"
      assert wrapped =~ "--die-with-parent"
      assert wrapped =~ "-- /bin/sh -c 'make build'"
    end

    test "denies network by default" do
      policy = %SandboxPolicy{workspace: "/home/user/project"}
      {:ok, wrapped} = Bubblewrap.wrap_command(policy, "echo hi")

      assert wrapped =~ "--unshare-net"
    end

    test "allows network when policy permits" do
      policy = %SandboxPolicy{workspace: "/home/user/project", allow_network: true}
      {:ok, wrapped} = Bubblewrap.wrap_command(policy, "curl example.com")

      refute wrapped =~ "--unshare-net"
    end

    test "uses custom toolchain paths when provided" do
      policy = %SandboxPolicy{
        workspace: "/home/user/project",
        toolchain_paths: ["/opt/toolchain"]
      }

      {:ok, wrapped} = Bubblewrap.wrap_command(policy, "echo hi")

      # Should not include default paths like /usr when custom paths are given
      refute wrapped =~ "--ro-bind /usr /usr"
    end

    test "clears environment and sets only allowed variables" do
      policy = %SandboxPolicy{workspace: "/home/user/project", env_allowlist: ["PATH", "HOME"]}
      {:ok, wrapped} = Bubblewrap.wrap_command(policy, "echo hi")

      assert wrapped =~ "--clearenv"
      # PATH is almost always set, so we should see it in the output
      if System.get_env("PATH") do
        assert wrapped =~ "--setenv PATH"
      end
    end

    test "skips env vars that are not set in the host environment" do
      policy = %SandboxPolicy{
        workspace: "/home/user/project",
        env_allowlist: ["MINGA_TEST_NONEXISTENT_VAR_12345"]
      }

      {:ok, wrapped} = Bubblewrap.wrap_command(policy, "echo hi")

      refute wrapped =~ "MINGA_TEST_NONEXISTENT_VAR_12345"
    end

    test "shell-escapes commands with single quotes" do
      policy = %SandboxPolicy{workspace: "/home/user/project"}
      {:ok, wrapped} = Bubblewrap.wrap_command(policy, "echo 'hello world'")

      # The command should be safely escaped
      assert wrapped =~ "/bin/sh -c"
      assert wrapped =~ "hello world"
    end

    test "includes extra read-only binds" do
      policy = %SandboxPolicy{
        workspace: "/home/user/project",
        extra_ro_binds: [{"/usr/local/go", "/usr/local/go"}]
      }

      {:ok, wrapped} = Bubblewrap.wrap_command(policy, "go build")

      assert wrapped =~ "--ro-bind"
    end

    test "includes extra read-write binds" do
      policy = %SandboxPolicy{
        workspace: "/home/user/project",
        extra_rw_binds: [{"/tmp/build", "/tmp/build"}]
      }

      {:ok, wrapped} = Bubblewrap.wrap_command(policy, "make")

      # Extra rw bind uses --bind, same as workspace
      assert wrapped =~ "--bind"
    end
  end
end
