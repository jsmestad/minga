defmodule MingaEditor.Shell.Traditional.AgentSurfacesTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileRef
  alias MingaEditor.Shell.Traditional.AgentSurfaces
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.State.InlineEdit

  test "replacement inline ask ignores the old session and cancellation returns the current session" do
    buffer = self()
    old_session = spawn_session()
    current_session = spawn_session()

    on_exit(fn ->
      Process.exit(old_session, :kill)
      Process.exit(current_session, :kill)
    end)

    old_ask = buffer |> ask() |> InlineAsk.thinking(old_session)
    current_ask = buffer |> ask() |> InlineAsk.thinking(current_session)

    surfaces =
      %AgentSurfaces{}
      |> AgentSurfaces.activate_ask(old_ask)
      |> AgentSurfaces.activate_ask(current_ask)
      |> AgentSurfaces.append_ask_response(old_session, "stale")

    assert InlineAsk.active(AgentSurfaces.asks(surfaces), buffer) == current_ask

    surfaces = AgentSurfaces.append_ask_response(surfaces, current_session, "current")
    assert InlineAsk.active(AgentSurfaces.asks(surfaces), buffer).response == "current"

    {canceled, session_pid} = AgentSurfaces.cancel_ask(surfaces, buffer)
    assert session_pid == current_session
    assert InlineAsk.active(AgentSurfaces.asks(canceled), buffer) == nil
  end

  test "replacement inline edit ignores stale completion and completes the current session" do
    buffer = self()
    old_session = spawn_session()
    current_session = spawn_session()

    on_exit(fn ->
      Process.exit(old_session, :kill)
      Process.exit(current_session, :kill)
    end)

    old_edit = buffer |> edit() |> InlineEdit.thinking(old_session)
    current_edit = buffer |> edit() |> InlineEdit.thinking(current_session)

    surfaces =
      %AgentSurfaces{}
      |> AgentSurfaces.activate_edit(old_edit)
      |> AgentSurfaces.activate_edit(current_edit)
      |> AgentSurfaces.complete_edit(old_session)

    assert InlineEdit.active(AgentSurfaces.edits(surfaces), buffer) == current_edit

    completed = AgentSurfaces.complete_edit(surfaces, current_session)

    assert %InlineEdit{status: :proposed, session_pid: nil} =
             InlineEdit.active(AgentSurfaces.edits(completed), buffer)
  end

  defp ask(buffer) do
    InlineAsk.new(buffer, file_ref(buffer), "scratch.ex", 0)
  end

  defp edit(buffer) do
    InlineEdit.new(buffer, file_ref(buffer), "scratch.ex", {0, 0}, "before")
  end

  defp file_ref(buffer) do
    %FileRef{kind: :buffer, display_name: "scratch.ex", buffer_pid: buffer}
  end

  defp spawn_session, do: spawn(fn -> receive do: (:stop -> :ok) end)
end
