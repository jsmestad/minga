defmodule Minga.Test.ConsoleGuard do
  @moduledoc """
  Fails a test run that leaves the VM's console changed.

  Mix and the compiler write warnings and errors straight to the process registered as `:standard_error`. A test that replaces or unregisters that name and does not put it back does not fail by itself. The next such write, often minutes later and in another module, raises "the device does not exist" inside Mix and the VM dies with `Runtime terminating during boot` instead of a test result (#4289). A logger handler that a test adds or removes for good changes where every later test's log output goes.

  `install/0` remembers the console when the suite starts and compares it when the suite ends. A change fails the run with a message that says what to look for. It restores `:standard_error` first, so the failure itself can be printed.

  `capture_io(:stderr, ...)` puts the device back when it returns, so a sync test that uses it passes this check.
  """

  @typedoc "The parts of the VM's console that tests must leave as they found them."
  @type snapshot :: %{standard_error: pid() | nil, logger_handlers: [:logger.handler_id()]}

  @doc "Remembers the console now and checks it when the suite ends."
  @spec install() :: :ok
  def install do
    before = snapshot()
    ExUnit.after_suite(fn _result -> check(before) end)
  end

  @doc "Reads the current console."
  @spec snapshot() :: snapshot()
  def snapshot do
    %{
      standard_error: Process.whereis(:standard_error),
      logger_handlers: Enum.sort(:logger.get_handler_ids())
    }
  end

  @doc "Says what changed between two snapshots, one line per change. An empty list means nothing changed."
  @spec violations(snapshot(), snapshot()) :: [String.t()]
  def violations(before, now) do
    Enum.reject(
      [
        standard_error_change(before, now),
        removed_handlers(before, now),
        added_handlers(before, now)
      ],
      &is_nil/1
    )
  end

  @spec check(snapshot()) :: :ok
  defp check(before) do
    case violations(before, snapshot()) do
      [] ->
        :ok

      changes ->
        restore_standard_error(before)
        IO.puts(:stdio, report(changes))
        System.at_exit(fn _status -> exit({:shutdown, 1}) end)
        :ok
    end
  end

  @spec standard_error_change(snapshot(), snapshot()) :: String.t() | nil
  defp standard_error_change(%{standard_error: same}, %{standard_error: same}), do: nil

  defp standard_error_change(%{standard_error: before}, %{standard_error: nil}),
    do: ":standard_error was #{inspect(before)} when the suite started and is not registered now."

  defp standard_error_change(%{standard_error: before}, %{standard_error: now}),
    do:
      ":standard_error was #{inspect(before)} when the suite started and is #{inspect(now)} now."

  @spec removed_handlers(snapshot(), snapshot()) :: String.t() | nil
  defp removed_handlers(%{logger_handlers: before}, %{logger_handlers: now}) do
    case before -- now do
      [] -> nil
      removed -> "Logger handlers removed and not added back: #{inspect(removed)}."
    end
  end

  @spec added_handlers(snapshot(), snapshot()) :: String.t() | nil
  defp added_handlers(%{logger_handlers: before}, %{logger_handlers: now}) do
    case now -- before do
      [] -> nil
      added -> "Logger handlers added and not removed: #{inspect(added)}."
    end
  end

  # Mix prints its own closing lines to this device. Put it back before anything else is written.
  @spec restore_standard_error(snapshot()) :: :ok
  defp restore_standard_error(%{standard_error: original}) when is_pid(original) do
    case Process.whereis(:standard_error) do
      ^original ->
        :ok

      nil ->
        register_standard_error(original)

      _other ->
        Process.unregister(:standard_error)
        register_standard_error(original)
    end
  end

  defp restore_standard_error(%{standard_error: nil}), do: :ok

  @spec register_standard_error(pid()) :: :ok
  defp register_standard_error(original) do
    if Process.alive?(original), do: Process.register(original, :standard_error)
    :ok
  end

  @spec report([String.t()]) :: String.t()
  defp report(changes) do
    """

    ERROR! A test left the VM's console changed. This run fails.

    #{Enum.map_join(changes, "\n", &("  * " <> &1))}

    A later write to :standard_error by Mix or the compiler would have ended the run with "Runtime terminating during boot" and no test result.
    Look for a test that starts an editor without `redirect_console: false`, calls `Minga.LoggerHandler.install/0`, or replaces `:standard_error` without restoring it.
    `:standard_error` has been put back for the rest of this run.
    """
  end
end
