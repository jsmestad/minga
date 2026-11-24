defmodule MingaAgent.Tools.SandboxPolicyTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.SandboxPolicy

  describe "construction" do
    test "requires workspace" do
      assert_raise ArgumentError, ~r/\[:workspace\]/, fn ->
        struct!(SandboxPolicy, [])
      end
    end

    test "sets sensible defaults" do
      policy = %SandboxPolicy{workspace: "/tmp/project"}

      assert policy.workspace == "/tmp/project"
      assert policy.toolchain_paths == []
      assert policy.allow_network == false
      assert policy.extra_ro_binds == []
      assert policy.extra_rw_binds == []
      assert is_list(policy.env_allowlist)
      assert "PATH" in policy.env_allowlist
      assert "HOME" in policy.env_allowlist
    end

    test "accepts custom toolchain paths" do
      policy = %SandboxPolicy{workspace: "/tmp/project", toolchain_paths: ["/opt/homebrew"]}
      assert policy.toolchain_paths == ["/opt/homebrew"]
    end

    test "accepts network allowance" do
      policy = %SandboxPolicy{workspace: "/tmp/project", allow_network: true}
      assert policy.allow_network == true
    end

    test "accepts custom environment allowlist" do
      policy = %SandboxPolicy{workspace: "/tmp/project", env_allowlist: ["PATH", "GOROOT"]}
      assert policy.env_allowlist == ["PATH", "GOROOT"]
    end

    test "accepts extra read-only and read-write binds" do
      policy = %SandboxPolicy{
        workspace: "/tmp/project",
        extra_ro_binds: [{"/usr/local/go", "/usr/local/go"}],
        extra_rw_binds: [{"/tmp/build", "/tmp/build"}]
      }

      assert policy.extra_ro_binds == [{"/usr/local/go", "/usr/local/go"}]
      assert policy.extra_rw_binds == [{"/tmp/build", "/tmp/build"}]
    end
  end

  describe "default_env_allowlist/0" do
    test "returns the expected default variables" do
      allowlist = SandboxPolicy.default_env_allowlist()
      assert is_list(allowlist)
      assert "PATH" in allowlist
      assert "HOME" in allowlist
      assert "TERM" in allowlist
      assert "SHELL" in allowlist
    end
  end
end
