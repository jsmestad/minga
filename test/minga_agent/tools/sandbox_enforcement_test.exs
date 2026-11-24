defmodule MingaAgent.Tools.SandboxEnforcementTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.SandboxBackend.Bubblewrap
  alias MingaAgent.Tools.SandboxBackend.Resolver
  alias MingaAgent.Tools.SandboxBackend.SandboxExec
  alias MingaAgent.Tools.SandboxPolicy

  describe "Resolver.select/0" do
    test "returns a backend module on the current platform" do
      case :os.type() do
        {:unix, :darwin} ->
          # sandbox-exec is built into macOS
          assert {:ok, SandboxExec} = Resolver.select()

        {:unix, :linux} ->
          # bwrap may or may not be installed
          case Resolver.select() do
            {:ok, Bubblewrap} -> :ok
            {:error, :backend_unavailable, msg} -> assert is_binary(msg)
          end

        _other ->
          assert {:error, :unsupported_platform, _msg} = Resolver.select()
      end
    end
  end

  describe "Resolver.wrap/2" do
    test "wraps a command on supported platforms" do
      policy = %SandboxPolicy{workspace: "/tmp/test-workspace"}

      case Resolver.wrap(policy, "echo hello") do
        {:ok, wrapped} ->
          assert is_binary(wrapped)
          assert wrapped =~ "echo hello"

        {:error, {reason, _msg}} when reason in [:unsupported_platform, :backend_unavailable] ->
          :ok
      end
    end

    test "returns an error with actionable message when backend is unavailable" do
      # This test verifies the error shape, not the actual platform availability.
      # On macOS, sandbox-exec is always present so this exercises the success path.
      # On other platforms, it exercises the error path.
      policy = %SandboxPolicy{workspace: "/tmp/test-workspace"}
      result = Resolver.wrap(policy, "echo hello")

      case result do
        {:ok, _wrapped} ->
          :ok

        {:error, {reason, message}} ->
          assert reason in [:unsupported_platform, :backend_unavailable]
          assert is_binary(message)
      end
    end
  end

  describe "fail-closed enforcement" do
    test "sandbox-exec backend is always available on macOS" do
      if match?({:unix, :darwin}, :os.type()) do
        assert SandboxExec.available?()
      end
    end

    test "bubblewrap available? returns boolean" do
      result = Bubblewrap.available?()
      assert is_boolean(result)
    end
  end

  describe "command wrapping preserves the original command" do
    test "bwrap wraps without mangling the command" do
      policy = %SandboxPolicy{workspace: "/home/user/project"}
      {:ok, wrapped} = Bubblewrap.wrap_command(policy, "gcc -o hello hello.c && ./hello")

      # The original command should appear inside single quotes at the end
      assert wrapped =~ "gcc -o hello hello.c && ./hello"
      assert wrapped =~ "-- /bin/sh -c"
    end

    test "sandbox-exec wraps without mangling the command" do
      policy = %SandboxPolicy{workspace: "/Users/dev/project"}
      {:ok, wrapped} = SandboxExec.wrap_command(policy, "gcc -o hello hello.c && ./hello")

      assert wrapped =~ "gcc -o hello hello.c && ./hello"
      assert wrapped =~ "/bin/sh -c"
    end
  end
end
