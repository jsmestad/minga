defmodule Minga.Test.SendGuiActionTest do
  @moduledoc """
  `send_gui_action/2` returns a frame that was rendered after the editor handled the action (#4312).

  Each test builds, without timing, the mailbox order that used to make the helper return the screen from before the action: a render that reaches the editor at the wrong moment. The editor and the headless frontend are suspended while messages are queued in a known order, and resumed afterwards.
  """

  use Minga.Test.EditorCase, async: true

  @delete_first_line {:execute_command, "delete_line"}

  # Waits for a fact about another process's mailbox.
  # The helper under test is blocked inside a call at that moment, so it cannot report the fact itself.
  # This spins on the scheduler and does not sleep.
  defp spin_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the expected mailbox order was never reached")

      true ->
        :erlang.yield()
        spin_until(fun, deadline)
    end
  end

  defp queued(pid) do
    {:messages, messages} = Process.info(pid, :messages)

    Enum.flat_map(messages, fn
      {:"$gen_call", _from, :api_mode} -> [:barrier]
      {:"$gen_cast", :render} -> [:render]
      {:minga_input, {:gui_action, _action}} -> [:action]
      {:"$gen_call", _from, {:wait_for_frame, _pid, _ref, _seq}} -> [:waiter]
      {:"$gen_call", _from, {:send_render_commands, _commands, _sent_at}} -> [:frame]
      _other -> []
    end)
  end

  # Runs the helper in a task, because it blocks while the editor is suspended.
  # The frame it stored is read in that same process, and the buffer is read right after it returns.
  defp act_in_task(ctx) do
    Task.async(fn ->
      :ok = send_gui_action(ctx, @delete_first_line)
      %{screen: screen_text(ctx), buffer: buffer_content(ctx)}
    end)
  end

  defp assert_after_the_action(%{screen: screen, buffer: buffer}) do
    assert buffer == "second line"
    refute Enum.any?(screen, &(&1 =~ "first line"))
    assert Enum.any?(screen, &(&1 =~ "second line"))
  end

  setup do
    ctx = start_editor("first line\nsecond line")
    assert Enum.any?(screen_text(ctx), &(&1 =~ "first line"))
    %{ctx: ctx}
  end

  test "a render queued ahead of the action does not stand in for the action's frame", %{ctx: ctx} do
    :ok = :sys.suspend(ctx.editor)
    :ok = MingaEditor.render(ctx.editor)
    task = act_in_task(ctx)
    spin_until(fn -> queued(ctx.editor) == [:render, :action, :barrier] end)
    :ok = :sys.resume(ctx.editor)

    assert_after_the_action(Task.await(task))
  end

  test "a render that reaches the editor right behind the helper's call does not stand in for the action's frame",
       %{ctx: ctx} do
    # This is the order that was lost. The helper used to call the editor first and send the action afterwards.
    # A render that arrived between the two (here: right behind the call) came from before the action.
    # It was committed while the helper was already waiting for a frame, and it was taken for the action's.
    # The frontend is suspended so that the frame cannot be committed before the helper's next step is queued.
    :ok = :sys.suspend(ctx.editor)
    task = act_in_task(ctx)
    spin_until(fn -> :barrier in queued(ctx.editor) end)
    :ok = MingaEditor.render(ctx.editor)
    :ok = :sys.suspend(ctx.port)
    :ok = :sys.resume(ctx.editor)
    spin_until(fn -> :frame in queued(ctx.port) end)
    :ok = :sys.resume(ctx.port)

    assert_after_the_action(Task.await(task))
  end

  test "the frame waiter is registered only after every frame from before the action is committed",
       %{
         ctx: ctx
       } do
    # The frontend is suspended too, so the order in which it receives things can be read off its mailbox.
    :ok = :sys.suspend(ctx.editor)
    :ok = MingaEditor.render(ctx.editor)
    task = act_in_task(ctx)
    spin_until(fn -> queued(ctx.editor) == [:render, :action, :barrier] end)
    :ok = :sys.suspend(ctx.port)
    :ok = :sys.resume(ctx.editor)

    # The editor is now inside the call that commits the frame from before the action.
    # The helper is still waiting for its own call to the editor, so it has not asked for a frame yet.
    spin_until(fn -> :frame in queued(ctx.port) end)
    assert queued(ctx.port) == [:frame]
    :ok = :sys.resume(ctx.port)

    assert_after_the_action(Task.await(task))
  end

  test "an action that changes nothing on screen still returns, with the screen as it is", %{
    ctx: ctx
  } do
    :ok = send_gui_action(ctx, {:execute_command, "no_such_command_for_this_test"})

    assert Enum.any?(screen_text(ctx), &(&1 =~ "first line"))
    assert buffer_content(ctx) == "first line\nsecond line"
  end
end
