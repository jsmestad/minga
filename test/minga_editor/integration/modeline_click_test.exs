defmodule MingaEditor.Integration.ModelineClickTest do
  @moduledoc """
  A modeline segment's click does what its key does: the frontend sends the segment's target as a GUI `execute_command`, and the running editor handles it as the key would.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.EditSource
  alias Minga.Frontend.Adapter.GUI.StatusBarEncoder
  alias Minga.Test.EditorCase
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Session

  test "clicking the file segment opens the switcher, as SPC , does" do
    session = Session.start() |> Session.open_file()

    file =
      session |> Session.model() |> Model.modeline_segments() |> Enum.find(&(&1.id == :filename))

    assert %{target: :buffer_list, key: "SPC ,"} = file
    refute session |> Session.model() |> Model.open?(:picker)

    clicked =
      session
      |> Session.click({:gui_action, {:execute_command, Atom.to_string(file.target)}})
      |> Session.model()

    pressed = Session.start() |> Session.open_file() |> Session.press("SPC ,") |> Session.model()

    assert Model.open?(clicked, :picker)
    assert clicked.picker_title == pressed.picker_title
  end

  test "the change segment jumps to the next review head and never retargets a stale click" do
    session =
      Session.start(
        content: "abc\nseparator\ndef",
        review_edits: [
          {{0, 0}, 3, "ABC", EditSource.minga("task", "first")},
          {{2, 0}, 3, "DEF", EditSource.minga("task", "second")}
        ]
      )
      |> Session.press("gg")

    buffer = EditorCase.active_window_buffer(session.ctx)

    assert %{text: "change 1/2", key: "]h"} = change_segment(session)
    target = encoded_review_target(session)
    click = {:gui_action, {:execute_command, target}}

    session = Session.click(session, click)
    assert Buffer.cursor(buffer) == {2, 0}
    assert %{text: "change 2/2"} = change_segment(session)

    keep_and_wait(session, buffer, "gg:Minga keep<CR>")
    refute change_segment(session)
    Session.click(session, click)
    assert Buffer.cursor(buffer) == {0, 0}
  end

  test "editing between pending regions leaves the modeline inactive until reaching a region" do
    session =
      Session.start(
        content: "abc\nseparator\ndef",
        review_edits: [
          {{0, 0}, 3, "ABC", EditSource.minga("task", "first")},
          {{2, 0}, 3, "DEF", EditSource.minga("task", "second")}
        ]
      )
      |> Session.press("gg")

    assert %{text: "change 1/2"} = change_segment(session)
    EditorCase.send_keys_sync(session.ctx, "j0i!<Esc>")
    buffer = EditorCase.active_window_buffer(session.ctx)
    assert Buffer.content(buffer) == "ABC\n!separator\nDEF"
    refute change_segment(session)
    session = Session.press(session, "G0")
    assert Buffer.cursor(buffer) == {2, 0}
    assert %{text: "change 2/2"} = change_segment(session)
  end

  test "a human insertion inside the ribbon does not add a head or become a review target" do
    session =
      Session.start(
        content: "abc\nseparator\ndef",
        review_edits: [
          {{0, 0}, 3, "ABC", EditSource.minga("task", "first")},
          {{2, 0}, 3, "DEF", EditSource.minga("task", "second")}
        ]
      )
      |> Session.press("gg")

    assert %{text: "change 1/2"} = change_segment(session)
    EditorCase.send_keys_sync(session.ctx, "li!<Esc>0")
    assert %{text: "change 1/2"} = change_segment(session)

    session = Session.press(session, "l")
    refute change_segment(session)
    session = Session.press(session, "l")
    assert %{text: "change 1/2"} = change_segment(session)

    buffer = EditorCase.active_window_buffer(session.ctx)
    keep_and_wait(session, buffer, ":Minga keep<CR>G0")
    assert %{text: "change 1/1"} = change_segment(session)
  end

  defp keep_and_wait(session, buffer, keys) do
    Minga.Events.subscribe(:buffer_review_changed, registry: session.ctx.events_registry)
    EditorCase.send_keys_sync(session.ctx, keys)

    assert_receive {:minga_event, :buffer_review_changed,
                    %Minga.Events.BufferEvent{buffer: ^buffer}}
  end

  defp change_segment(session) do
    session |> Session.model() |> Model.modeline_segments() |> Enum.find(&(&1.id == :change))
  end

  defp encoded_review_target(session) do
    model = Session.model(session)
    packet = StatusBarEncoder.encode_command(model.ui.status_bar)
    [target] = Regex.run(~r/next_minga_change_at:\d+:<\d+\.\d+\.\d+>:\d+:\d+:\d+/, packet)
    target
  end
end
