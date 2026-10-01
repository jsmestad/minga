defmodule MingaAgent.Tools.OutputLimitTest do
  # Spawns OS processes through Port command collection.
  use ExUnit.Case, async: false

  @moduletag :heavy

  alias MingaAgent.Tools.OutputLimit
  alias MingaAgent.Tools.OutputLimit.Result

  @moduletag :tmp_dir

  describe "collect_command/3" do
    test "keeps an incomplete UTF-8 prefix valid when the cap splits a codepoint" do
      assert %Result{
               output: output,
               status: :terminated,
               capture: {:incomplete, :capture_byte_limit}
             } =
               OutputLimit.collect_command(
                 "/bin/sh",
                 ["-c", "printf '\\342'; printf '\\202\\254'"],
                 max_bytes: 1,
                 timeout_ms: 1_000
               )

      assert String.valid?(output)
    end

    test "terminates the producer and reports an incomplete capture at the byte allowance" do
      assert %Result{
               output: "abc",
               status: :terminated,
               capture: {:incomplete, :capture_byte_limit}
             } =
               OutputLimit.collect_command("/bin/sh", ["-c", "printf 'abcdef'; exit 42"],
                 max_bytes: 3,
                 timeout_ms: 1_000
               )
    end

    test "returns timeout and incomplete status for a producer that does not exit" do
      assert %Result{
               output: output,
               status: :timeout,
               capture: {:incomplete, :timeout}
             } =
               OutputLimit.collect_command("/bin/sh", ["-c", "exec sleep 60"],
                 max_bytes: 16,
                 timeout_ms: 20
               )

      assert output == ""
    end

    test "timeout and byte exhaustion kill a producer that ignores closed output", %{
      tmp_dir: root
    } do
      for {status, reason, opts} <- [
            {:timeout, :timeout, [max_bytes: 64, timeout_ms: 250]},
            {:terminated, :capture_byte_limit, [max_bytes: 3, timeout_ms: 5_000]}
          ] do
        pid_file = Path.join(root, Atom.to_string(reason))
        command = "printf '%s' \"$$\" > \"$1\"; printf abcdef; while :; do :; done"

        result =
          OutputLimit.collect_command(
            "/bin/sh",
            ["-c", command, "bounded-producer", pid_file],
            opts
          )

        assert %Result{status: ^status, capture: {:incomplete, ^reason}} = result
        pid = File.read!(pid_file)

        unless await_os_pid_dead(pid, 1_000) do
          System.cmd("/bin/kill", ["-KILL", pid], stderr_to_stdout: true)
          flunk("#{reason} left producer #{pid} running")
        end
      end
    end
  end

  defp await_os_pid_dead(pid, remaining) when remaining > 0 do
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, status} when status != 0 ->
        true

      {_output, 0} ->
        receive do
        after
          5 -> await_os_pid_dead(pid, remaining - 5)
        end
    end
  end

  defp await_os_pid_dead(_pid, 0), do: false
end
