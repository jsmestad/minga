defmodule Minga.Test.ConsoleGuardTest do
  use ExUnit.Case, async: true

  alias Minga.Test.ConsoleGuard

  describe "violations/2" do
    test "an unchanged console has no violations" do
      console = %{standard_error: self(), logger_handlers: [:default]}

      assert ConsoleGuard.violations(console, console) == []
    end

    test "each kind of change is reported in words a reader can act on" do
      original = self()
      other = spawn(fn -> :ok end)
      before = %{standard_error: original, logger_handlers: [:default, :minga_messages]}

      cases = [
        {%{before | standard_error: nil}, "is not registered now"},
        {%{before | standard_error: other}, "is #{inspect(other)} now"},
        {%{before | logger_handlers: [:minga_messages]},
         "removed and not added back: [:default]"},
        {%{before | logger_handlers: [:default, :minga_file, :minga_messages]},
         "added and not removed: [:minga_file]"}
      ]

      for {now, expected} <- cases do
        assert [line] = ConsoleGuard.violations(before, now)
        assert line =~ expected
      end
    end

    test "a console that lost its device and swapped a handler reports all three changes" do
      before = %{standard_error: self(), logger_handlers: [:default]}
      now = %{standard_error: nil, logger_handlers: [:minga_file]}

      assert [_device, _removed, _added] = ConsoleGuard.violations(before, now)
    end
  end

  test "snapshot/0 reads the registered device and the logger handlers" do
    assert %{standard_error: device, logger_handlers: handlers} = ConsoleGuard.snapshot()
    assert device == Process.whereis(:standard_error)
    assert is_list(handlers)
  end
end
