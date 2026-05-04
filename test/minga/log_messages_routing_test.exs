defmodule Minga.LogMessagesRoutingTest do
  # async: false because Logger.configure/1 mutates global state.
  use ExUnit.Case, async: false

  alias Minga.Config.Options
  alias Minga.Events
  alias Minga.Events.LogMessageEvent

  setup do
    {:ok, _opts} = Options.start_link(name: :"opts_#{System.unique_integer()}")

    on_exit(fn -> Options.reset() end)

    :ok
  end

  describe "Messages routing" do
    test "broadcasts :log_message when the OTP Logger level would suppress the entry" do
      Options.set(:log_level, :info)
      Options.set(:log_level_editor, :default)

      Events.subscribe(:log_message)

      previous_level = Logger.level()
      Logger.configure(level: :warning)

      on_exit(fn ->
        Logger.configure(level: previous_level)
        Events.unsubscribe(:log_message)
      end)

      Minga.Log.info(:editor, "Grammar org registered successfully")

      assert_receive {:minga_event, :log_message, %LogMessageEvent{text: text, level: :info}},
                     500

      assert text =~ "Grammar org registered successfully"
      assert text =~ "[editor/info]"
    end
  end
end
