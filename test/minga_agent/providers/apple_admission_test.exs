defmodule MingaAgent.Providers.AppleAdmissionTest do
  # Opens a real OS Port to observe command bytes.
  use ExUnit.Case, async: false

  alias MingaAgent.Providers.Apple.Admission

  test "cancellation while Session authorization is pending never writes admit" do
    caller = self()

    {port_owner, monitor} =
      spawn_monitor(fn ->
        port =
          Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, {:line, 64}])

        owner = Process.monitor(caller)
        consumer = Process.monitor(caller)
        deadline = System.monotonic_time(:millisecond) + 5_000

        authorize = fn ->
          send(caller, {:assessing, self()})

          receive do
            :authorized -> :ok
          end
        end

        result = Admission.release(port, authorize, owner, consumer, deadline)
        send(caller, {:release, result})
        true = Port.command(port, "barrier\n")

        receive do
          {^port, {:data, {:eol, line}}} -> send(caller, {:first_port_line, line})
        end

        Port.close(port)
      end)

    on_exit(fn -> Process.exit(port_owner, :kill) end)
    assert_receive {:assessing, authorization}, 1_000
    send(port_owner, :cancel)
    send(authorization, :authorized)

    assert_receive {:release, :canceled}, 1_000
    assert_receive {:first_port_line, "barrier"}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^port_owner, :normal}, 1_000
  end
end
