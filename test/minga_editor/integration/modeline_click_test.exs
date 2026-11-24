defmodule MingaEditor.Integration.ModelineClickTest do
  @moduledoc """
  A modeline segment's click does what its key does: the frontend sends the segment's target as a GUI `execute_command`, and the running editor handles it as the key would.
  """

  use ExUnit.Case, async: true

  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Session

  test "clicking the file segment opens the switcher, as SPC , does" do
    session = Session.start()

    file =
      session |> Session.model() |> Model.modeline_segments() |> Enum.find(&(&1.id == :filename))

    assert %{target: :buffer_list, key: "SPC ,"} = file
    refute session |> Session.model() |> Model.open?(:picker)

    clicked =
      session
      |> Session.click({:gui_action, {:execute_command, Atom.to_string(file.target)}})
      |> Session.model()

    pressed = Session.start() |> Session.press("SPC ,") |> Session.model()

    assert Model.open?(clicked, :picker)
    assert clicked.picker_title == pressed.picker_title
  end
end
