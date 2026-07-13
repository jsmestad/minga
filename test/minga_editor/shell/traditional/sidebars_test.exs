defmodule MingaEditor.Shell.Traditional.SidebarsTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Observatory.Data
  alias MingaEditor.Observatory.Inspection
  alias MingaEditor.Shell.Traditional.Observatory
  alias MingaEditor.Shell.Traditional.Sidebars

  test "Git status close clears its selected surface and paired TUI state" do
    sidebars =
      %Sidebars{}
      |> Sidebars.replace_git_status(%{entries: []})
      |> Sidebars.replace_git_status_tui(%URI{path: "/status"})
      |> Sidebars.select("git_status")

    closed = Sidebars.close_git_status(sidebars)

    assert Sidebars.active_id(closed) == nil
    assert Sidebars.git_status_panel(closed) == nil
    assert Sidebars.git_status_tui_state(closed) == nil
  end

  test "closing Observatory clears every surface value and invalidates delayed work" do
    timer = make_ref()
    token = make_ref()
    data = Data.visible(nil, [])
    inspection = %Inspection{visible: true, title: "Process", lines: [], width: 20, height: 10}

    sidebars =
      %Sidebars{}
      |> Sidebars.open_observatory({timer, token})
      |> Sidebars.replace_observatory_data(data)
      |> Sidebars.inspect_observatory(inspection)

    closed = Sidebars.close_observatory(sidebars)
    observatory = Sidebars.observatory(closed)

    assert Sidebars.active_id(closed) == nil
    refute Observatory.visible?(observatory)
    assert Observatory.timer(observatory) == nil
    assert Observatory.data(observatory) == nil
    assert Observatory.inspection(observatory) == nil
    assert {:stale, ^closed} = Sidebars.expire_observatory(closed, token)

    next_timer = {make_ref(), make_ref()}
    assert {:stale, ^closed} = Sidebars.complete_observatory(closed, token, data, next_timer)
  end

  test "replacement tokens reject an old tick and accept only the current collection" do
    first_token = make_ref()
    second_token = make_ref()

    sidebars =
      %Sidebars{}
      |> Sidebars.open_observatory({make_ref(), first_token})
      |> Sidebars.open_observatory({make_ref(), second_token})

    assert {:stale, ^sidebars} = Sidebars.expire_observatory(sidebars, first_token)
    assert {:collect, collecting} = Sidebars.expire_observatory(sidebars, second_token)

    data = Data.visible(nil, [])
    next_timer = make_ref()
    next_token = make_ref()

    assert {:stale, ^collecting} =
             Sidebars.complete_observatory(
               collecting,
               first_token,
               data,
               {next_timer, next_token}
             )

    assert {:accepted, scheduled} =
             Sidebars.complete_observatory(
               collecting,
               second_token,
               data,
               {next_timer, next_token}
             )

    observatory = Sidebars.observatory(scheduled)
    assert Observatory.visible?(observatory)
    assert Observatory.data(observatory) == data
    assert Observatory.timer(observatory) == next_timer
    assert observatory.token == next_token
  end
end
