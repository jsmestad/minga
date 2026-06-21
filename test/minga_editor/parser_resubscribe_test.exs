defmodule MingaEditor.ParserResubscribeTest do
  @moduledoc """
  Parser crash recovery for per-session editors (#2424).

  The parser (`Minga.Parser.Manager`) is a node-shared `one_for_one` sibling of
  each editor, not a supervised ancestor. A parser crash therefore does *not*
  restart the editor, and the restarted parser boots with an empty subscriber
  list. Each editor monitors the parser and re-subscribes on its `:DOWN`, so
  highlighting survives a parser restart instead of silently dying.
  """

  # async: false: starts globally-named parser managers and uses the shared
  # MingaEditor.Extension.Sidebar table seam.
  use ExUnit.Case, async: false

  alias Minga.Parser.Manager
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Startup

  defp unique_name(prefix),
    do: Module.concat(__MODULE__, "#{prefix}#{System.unique_integer([:positive])}")

  defp start_parser(name) do
    start_supervised!(%{
      id: name,
      start: {Manager, :start_link, [[name: name]]},
      restart: :temporary
    })

    name
  end

  defp private_sidebar_registry do
    table = unique_name("Sidebar")
    start_supervised!({Sidebar, name: table, notify: false})
    table
  end

  defp subscribed?(parser_name, pid) do
    %{subscribers: subscribers} = :sys.get_state(parser_name)
    pid in subscribers
  catch
    :exit, _ -> false
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end

  describe "Startup.subscribe_to_parser/1" do
    test "subscribes the caller and returns a monitor ref for the parser" do
      parser = start_parser(unique_name("Parser"))

      ref = Startup.subscribe_to_parser(parser)

      assert is_reference(ref)
      assert subscribed?(parser, self())
    end

    test "returns nil when the parser is not running (nothing to monitor)" do
      # A name that no process holds resolves to nil; there is nothing to
      # subscribe to or monitor, so the caller learns to retry.
      assert Startup.subscribe_to_parser(unique_name("Absent")) == nil
    end
  end

  describe "Startup.resubscribe_to_parser/1" do
    test "re-subscribes to a parser restarted under the same name" do
      name = unique_name("Parser")
      parser1 = start_parser(name)
      ref1 = Startup.subscribe_to_parser(name)
      assert is_reference(ref1)
      assert subscribed?(name, self())

      # Kill the parser and stand a fresh one up under the same name. The new
      # parser boots with an empty subscriber list.
      pid1 = GenServer.whereis(name)
      Process.exit(pid1, :kill)
      assert eventually(fn -> GenServer.whereis(name) == nil end)

      parser2 = start_parser(name)
      refute subscribed?(name, self())

      ref2 = Startup.resubscribe_to_parser(name)

      assert is_reference(ref2)
      assert ref2 != ref1
      assert subscribed?(name, self())
      assert parser1 == parser2
    end
  end

  describe "editor re-subscribes after a parser restart" do
    test "a headless editor re-subscribes when its monitored parser dies and restarts" do
      parser_name = unique_name("EditorParser")
      start_parser(parser_name)

      editor =
        start_supervised!(
          {MingaEditor,
           [
             name: unique_name("Editor"),
             backend: :headless,
             port_manager: nil,
             parser_manager: parser_name,
             options_server: nil,
             sidebar_registry: private_sidebar_registry(),
             view_mode: :editor,
             width: 80,
             height: 24
           ]}
        )

      # The editor subscribed to the parser at init.
      assert eventually(fn -> subscribed?(parser_name, editor) end)

      # Kill the parser, then restart it under the same name. The editor's
      # monitor fires; its :DOWN handler re-resolves and re-subscribes (retrying
      # with backoff until the parser is back).
      old_pid = GenServer.whereis(parser_name)
      Process.exit(old_pid, :kill)
      assert eventually(fn -> GenServer.whereis(parser_name) == nil end)

      start_parser(parser_name)

      # The freshly-started parser starts with no subscribers; the editor must
      # re-add itself.
      assert eventually(fn -> subscribed?(parser_name, editor) end)
    end
  end
end
