defmodule Minga.Storyboard.MingaStateTest do
  @moduledoc """
  The modeline speaks Minga's state in the real editor: a session that starts with Minga working shows it in words, in the state's colour role, and keeps it there while which-key is open.
  """

  use ExUnit.Case, async: true

  import Minga.Test.Storyboard.Assertions

  alias Minga.Buffer.EditSource
  alias Minga.Test.EditorCase
  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Session
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  @moduletag :storyboard

  test "Minga working reads as working in the minga role, at rest and under which-key" do
    session = Session.start(minga: :thinking) |> Session.open_file()

    session |> Session.model() |> assert_state(:modeline, :working)

    session
    |> Session.press("SPC a (pause)")
    |> Session.model()
    |> assert_which_key("SPC a")
    |> assert_state(:modeline, :working)
  end

  test "a status that needs you shows needs-you and Minga's state from the same value" do
    model = Session.start(minga: :approval_waiting) |> Session.open_file() |> Session.model()

    model
    |> assert_state(:modeline, :needs_you)
    |> assert_spoken_once(:modeline, :needs_you)
    |> assert_modeline_order([:mode, :needs_you, :file, :minga, :filetype, :position])

    minga = model |> Model.modeline_segments() |> Enum.find(&(&1.id == :minga))
    assert {minga.text, minga.state} == {"Minga", :needs_you}
  end

  test "Reject all names the task and choices through both reach paths" do
    entry = Registry.fetch!("minga.reject_all.confirm")
    keyboard = Registry.drive(entry)
    model = Session.model(keyboard)

    for check <- entry.checks do
      assert Check.run(check, model) == :ok, check.name
    end

    refute :minibuffer in (keyboard |> Session.press("esc") |> Session.model()).surfaces
    Session.stop(keyboard)

    click = Enum.reduce(entry.click_reach, Session.start(entry.start), &Session.click(&2, &1))
    assert Registry.classify(Session.model(click)) == entry.id
  end

  test "blocked undo offers exact review keys in the shared modeline" do
    blocked =
      Session.start(
        content: "base\n",
        review_edits: [
          {{0, 0}, 4, "local", EditSource.user()},
          {{0, 0}, 5, "proof", EditSource.minga("fixture-task", "blocking-step")}
        ]
      )
      |> Session.press("u")

    model = Session.model(blocked)
    assert model.echo == "Undo blocked: Minga …task/…step"
    actions = model.ui.status_bar.data.message_actions
    assert Enum.map(actions, &{&1.key, &1.label}) == [{"SPC a d", "Reject"}, {"SPC a y", "Keep"}]

    kept = Session.press(blocked, "SPC a y")
    message = "Kept the blocking Minga change"
    EditorCase.wait_until(kept.ctx, &(NoticeWorkflow.message(&1) == message))
    assert Session.model(kept).echo == message
  end

  test "the task review reaches its tree, confirmation, diff, empty, and completed views" do
    for id <-
          ~w(minga.review.buffer minga.review.keep_all.confirm minga.review.all_decided minga.review.empty minga.review.diff_inline) do
      entry = Registry.fetch!(id)
      session = Registry.drive(entry)

      try do
        model = Session.model(session)
        assert Registry.classify(model) == id

        for check <- entry.checks do
          assert Check.run(check, model) == :ok, check.name
        end
      after
        Session.stop(session)
      end
    end
  end
end
