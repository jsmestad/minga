defmodule MingaEditor.FrontendForegroundTest do
  @moduledoc """
  The editor keeps whether its frontend is in the foreground and tells the rest of Minga once per change.

  The fact is frontend-neutral: the terminal reports its window focus, macOS its active state. A reader below the editor subscribes to `:frontend_foreground_changed`.
  """
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Events
  alias Minga.Events.FrontendForegroundChangedEvent
  alias MingaEditor.Frontend.TerminalReport
  alias MingaEditor.State.Frontend

  defp report(ctx, status) do
    send(ctx.editor, {:minga_input, {:frontend_foreground, status}})
    Frontend.foreground(editor_state(ctx).frontend)
  end

  test "a report is kept and announced once; the same report again announces nothing" do
    ctx = start_editor("hello")
    Events.subscribe(:frontend_foreground_changed, registry: ctx.events_registry)

    assert Frontend.foreground(editor_state(ctx).frontend) == :unknown

    assert report(ctx, :background) == :background

    assert_receive {:minga_event, :frontend_foreground_changed,
                    %FrontendForegroundChangedEvent{status: :background}}

    assert report(ctx, :background) == :background
    refute_receive {:minga_event, :frontend_foreground_changed, _event}, 50

    assert report(ctx, :foreground) == :foreground

    assert_receive {:minga_event, :frontend_foreground_changed,
                    %FrontendForegroundChangedEvent{status: :foreground}}
  end

  test "a new frontend connection makes the foreground unknown again, and says so" do
    ctx = start_editor("hello")
    Events.subscribe(:frontend_foreground_changed, registry: ctx.events_registry)

    assert report(ctx, :background) == :background

    assert_receive {:minga_event, :frontend_foreground_changed,
                    %FrontendForegroundChangedEvent{status: :background}}

    send(
      ctx.editor,
      {:minga_input, {:terminal_report, TerminalReport.new(true_color: :detected)}}
    )

    send(ctx.editor, {:minga_input, {:ready, 80, 24}})

    frontend = editor_state(ctx).frontend
    assert Frontend.foreground(frontend) == :unknown
    assert Frontend.terminal_report(frontend) == nil

    assert_receive {:minga_event, :frontend_foreground_changed,
                    %FrontendForegroundChangedEvent{status: :unknown}}

    # A connection that never said where it is does not announce "unknown" again.
    send(ctx.editor, {:minga_input, {:ready, 80, 24}})
    assert Frontend.foreground(editor_state(ctx).frontend) == :unknown
    refute_receive {:minga_event, :frontend_foreground_changed, _event}, 50
  end

  test "the terminal frontend's report is kept whole and replaced by the next one" do
    ctx = start_editor("hello")

    send(ctx.editor, {:minga_input, {:terminal_report, TerminalReport.new(true_color: :pending)}})

    assert Frontend.terminal_report(editor_state(ctx).frontend) ==
             TerminalReport.new(true_color: :pending)

    send(
      ctx.editor,
      {:minga_input, {:terminal_report, TerminalReport.new(true_color: :detected)}}
    )

    assert Frontend.terminal_report(editor_state(ctx).frontend) ==
             TerminalReport.new(true_color: :detected)
  end
end
