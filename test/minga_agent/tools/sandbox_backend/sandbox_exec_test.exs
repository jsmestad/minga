defmodule MingaAgent.Tools.SandboxBackend.SandboxExecTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.SandboxBackend.SandboxExec
  alias MingaAgent.Tools.SandboxPolicy

  describe "wrap_command/2" do
    test "produces a sandbox-exec invocation with inline profile" do
      policy = %SandboxPolicy{workspace: "/Users/dev/project"}
      assert {:ok, wrapped} = SandboxExec.wrap_command(policy, "make build")

      assert wrapped =~ "/usr/bin/sandbox-exec"
      assert wrapped =~ "-p"
      assert wrapped =~ "/bin/sh -c"
      assert wrapped =~ "make build"
    end

    test "denies network by default" do
      policy = %SandboxPolicy{workspace: "/Users/dev/project"}
      {:ok, wrapped} = SandboxExec.wrap_command(policy, "echo hi")

      assert wrapped =~ "deny network"
    end

    test "omits network denial when policy allows network" do
      policy = %SandboxPolicy{workspace: "/Users/dev/project", allow_network: true}
      {:ok, wrapped} = SandboxExec.wrap_command(policy, "curl example.com")

      refute wrapped =~ "deny network"
    end
  end

  describe "build_profile/1" do
    test "generates allow-default SBPL with private path denial" do
      policy = %SandboxPolicy{workspace: "/Users/dev/project"}
      profile = SandboxExec.build_profile(policy)

      assert profile =~ "(version 1)"
      assert profile =~ "(allow default)"

      assert profile =~
               ~s|(deny file-read* file-write* (subpath "/Users") (subpath "/private/var") (subpath "/var"))|
    end

    test "allows workspace path for read and write" do
      policy = %SandboxPolicy{workspace: "/Users/dev/project"}
      profile = SandboxExec.build_profile(policy)

      assert profile =~ "(allow file-read* file-write*"
      assert profile =~ "/Users/dev/project"
    end

    test "uses canonical paths for workspace" do
      # /tmp is a symlink to /private/tmp on macOS
      policy = %SandboxPolicy{workspace: "/tmp/test-project"}
      profile = SandboxExec.build_profile(policy)

      # On macOS, /tmp resolves to /private/tmp
      if File.exists?("/private/tmp") do
        assert profile =~ "/private/tmp/test-project"
      end
    end

    test "denies network when allow_network is false" do
      policy = %SandboxPolicy{workspace: "/Users/dev/project"}
      profile = SandboxExec.build_profile(policy)

      assert profile =~ "(deny network*)"
    end

    test "omits network denial when allow_network is true" do
      policy = %SandboxPolicy{workspace: "/Users/dev/project", allow_network: true}
      profile = SandboxExec.build_profile(policy)

      refute profile =~ "network"
    end

    test "includes extra read-only binds" do
      policy = %SandboxPolicy{
        workspace: "/Users/dev/project",
        extra_ro_binds: [{"/usr/local/go", "/usr/local/go"}]
      }

      profile = SandboxExec.build_profile(policy)

      assert profile =~ "(allow file-read*"
      assert profile =~ "/usr/local/go"
    end

    test "includes extra read-write binds" do
      policy = %SandboxPolicy{
        workspace: "/Users/dev/project",
        extra_rw_binds: [{"/tmp/build-cache", "/tmp/build-cache"}]
      }

      profile = SandboxExec.build_profile(policy)

      assert profile =~ "(allow file-read* file-write*"
    end
  end
end
