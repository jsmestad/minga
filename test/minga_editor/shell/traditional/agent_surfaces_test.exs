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

  test "session updates replace only the matching ask entry and ignore missing sessions" do
    first_buffer = self()
    second_buffer = spawn_session()
    first_session = spawn_session()
    second_session = spawn_session()
    missing_session = spawn_session()

    on_exit(fn ->
      Enum.each([second_buffer, first_session, second_session, missing_session], fn pid ->
        Process.exit(pid, :kill)
      end)
    end)

    first_ask = first_buffer |> ask() |> InlineAsk.thinking(first_session)
    second_ask = second_buffer |> ask() |> InlineAsk.thinking(second_session)

    surfaces =
      %AgentSurfaces{}
      |> AgentSurfaces.activate_ask(first_ask)
      |> AgentSurfaces.activate_ask(second_ask)

    updated = AgentSurfaces.append_ask_response(surfaces, first_session, "first")

    assert InlineAsk.active(AgentSurfaces.asks(updated), first_buffer).response == "first"
    assert InlineAsk.active(AgentSurfaces.asks(updated), second_buffer) == second_ask
    assert AgentSurfaces.append_ask_response(updated, missing_session, "missing") == updated
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

  test "session updates replace only the matching edit entry and ignore missing sessions" do
    first_buffer = self()
    second_buffer = spawn_session()
    first_session = spawn_session()
    second_session = spawn_session()
    missing_session = spawn_session()

    on_exit(fn ->
      Enum.each([second_buffer, first_session, second_session, missing_session], fn pid ->
        Process.exit(pid, :kill)
      end)
    end)

    first_edit = first_buffer |> edit() |> InlineEdit.thinking(first_session)
    second_edit = second_buffer |> edit() |> InlineEdit.thinking(second_session)

    surfaces =
      %AgentSurfaces{}
      |> AgentSurfaces.activate_edit(first_edit)
      |> AgentSurfaces.activate_edit(second_edit)

    updated = AgentSurfaces.append_edit_proposal(surfaces, first_session, "first")

    assert InlineEdit.active(AgentSurfaces.edits(updated), first_buffer).proposed_rewrite ==
             "first"

    assert InlineEdit.active(AgentSurfaces.edits(updated), second_buffer) == second_edit
    assert AgentSurfaces.append_edit_proposal(updated, missing_session, "missing") == updated
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
