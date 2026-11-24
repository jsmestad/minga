defmodule Minga.Storyboard.MingaStateTest do
  @moduledoc """
  The modeline speaks Minga's state in the real editor: a session that starts with Minga working shows it in words, in the state's colour role, and keeps it there while which-key is open.
  """

  use ExUnit.Case, async: true

  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Session

  @moduletag :storyboard

  test "Minga working reads as working in the minga role, at rest and under which-key" do
    session = Session.start(minga: :thinking)

    session |> Session.model() |> assert_state(:modeline, :working)

    session
    |> Session.press("SPC a (pause)")
    |> Session.model()
    |> assert_which_key("SPC a")
    |> assert_state(:modeline, :working)
  end

  test "a status that needs you shows needs-you and Minga's state from the same value" do
    model = Session.start(minga: :approval_waiting) |> Session.model()

    model
    |> assert_state(:modeline, :needs_you)
    |> assert_modeline_order([:mode, :needs_you, :file, :minga, :filetype, :position])
  end
end
