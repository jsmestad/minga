defmodule MingaEditor.Test.SidebarActionProbe do
  @moduledoc false

  @spec handle(MingaEditor.State.t(), String.t(), map()) :: MingaEditor.State.t()
  def handle(state, action, context) do
    send(context.test_pid, {
      :sidebar_action_called,
      action,
      context,
      Minga.Extension.InvocationContext.current_source()
    })

    state
  end

  @spec publish_notice(MingaEditor.State.t(), String.t(), map()) :: MingaEditor.State.t()
  def publish_notice(state, action, context) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "#{action}:#{context.kind}")
  end

  @spec invalid(MingaEditor.State.t(), String.t(), map()) :: :invalid_sidebar_state
  def invalid(_state, _action, _context), do: :invalid_sidebar_state

  @spec raise_error(MingaEditor.State.t(), String.t(), map()) :: no_return()
  def raise_error(_state, _action, _context), do: raise("sidebar callback failed")
end
