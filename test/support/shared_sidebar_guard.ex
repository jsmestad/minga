defmodule Minga.Test.SharedSidebarGuard do
  @moduledoc """
  Fails a test run that leaves a focused sidebar open in the sidebar table every editor shares by default.

  An `%MingaEditor.State{}` built by hand reads `MingaEditor.Extension.Sidebar.default_table/0` unless the test gives it a table of its own. A test that opens a sidebar through such a state, the BEAM Observatory for one, leaves a visible and focused sidebar there. The generic sidebar input handler then takes the keys of every later test that also reads the shared table, and that test fails far from the cause (#4271).

  `install/0` remembers which left sidebars are on screen with focus when the suite starts and compares when it ends. Those are the ones that take keys. One that was opened and not closed fails the run with a message that says what to look for.

  The fix for a named leak is a private table: start `{MingaEditor.Extension.Sidebar, name: table, notify: false}` under the test and build the state with `MingaEditor.State.ExtensionSurfaces.new(sidebar_registry: table)`.
  """

  alias MingaEditor.Extension.Sidebar

  @doc "Remembers the focused sidebars of the shared table now and checks them when the suite ends."
  @spec install() :: :ok
  def install do
    before = open_ids(Sidebar.default_table())
    ExUnit.after_suite(fn _result -> check(before) end)
  end

  @doc "The ids of the left sidebars a table shows on screen with focus: the ones that take keys."
  @spec open_ids(Sidebar.table()) :: [String.t()]
  def open_ids(table) do
    table
    |> Sidebar.visible()
    |> Enum.filter(&(&1.placement == :left and &1.focused?))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  @doc "The sidebars that are open now and were not open before. An empty list means the table was left as found."
  @spec left_open([String.t()], [String.t()]) :: [String.t()]
  def left_open(before, now), do: now -- before

  @spec check([String.t()]) :: :ok
  defp check(before) do
    case left_open(before, open_ids(Sidebar.default_table())) do
      [] ->
        :ok

      ids ->
        IO.puts(:stdio, report(ids))
        System.at_exit(fn _status -> exit({:shutdown, 1}) end)
        :ok
    end
  end

  @spec report([String.t()]) :: String.t()
  defp report(ids) do
    """

    ERROR! A test left a focused sidebar open in the sidebar table that editors share by default. This run fails.

      * Still on screen with focus: #{inspect(ids)}.

    A later test that builds an editor state by hand reads the same table, and a focused sidebar there takes its keys (#4271).
    Look for a test that opens this sidebar through a state built with `%MingaEditor.State{}` and no sidebar table of its own.
    Give that state a private table: `MingaEditor.State.ExtensionSurfaces.new(sidebar_registry: table)`.
    """
  end
end
