defmodule Minga.LogMessagesRoutingTest do
  # async: false because Logger.configure/1 mutates global state
  use ExUnit.Case, async: false

  alias Minga.Config.Options

  setup do
    {:ok, _opts} = Options.start_link(name: :"opts_#{System.unique_integer()}")

    on_exit(fn -> Options.reset() end)

    :ok
  end

  describe "Messages routing" do
    test "routes to *Messages* when OTP Logger level suppresses the message" do
      Options.set(:log_level, :info)
      Options.set(:log_level_editor, :default)

      # Register a fake Editor process so Process.whereis(MingaEditor) finds it.
      test_pid = self()

      fake_editor =
        spawn(fn ->
          Process.register(self(), MingaEditor)
          send(test_pid, :registered)

          # Receive the cast from log_to_messages
          receive do
            {:"$gen_cast", {:log_to_messages, text}} ->
              send(test_pid, {:got_message, text})
          after
            1000 -> :timeout
          end
        end)

      assert_receive :registered

      # Set OTP Logger to :warning so :info is suppressed at Logger level
      # but Minga.Log's subsystem level still permits it.
      previous_level = Logger.level()
      Logger.configure(level: :warning)

      on_exit(fn ->
        Logger.configure(level: previous_level)
        Process.exit(fake_editor, :kill)
      end)

      Minga.Log.info(:editor, "Grammar org registered successfully")

      assert_receive {:got_message, text}
      assert text =~ "Grammar org registered successfully"
      assert text =~ "[editor/info]"
    end
  end
end
