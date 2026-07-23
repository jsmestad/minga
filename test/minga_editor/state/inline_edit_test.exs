defmodule MingaEditor.State.InlineEditTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileRef
  alias MingaEditor.State.InlineEdit

  test "thinking creates a running phase with no rewrite" do
    session = self()
    running = self() |> edit() |> InlineEdit.thinking(session)

    assert InlineEdit.phase(running) == {:running, session, :none}
    assert InlineEdit.running?(running)
    assert InlineEdit.session_pid(running) == session
    assert InlineEdit.rewrite(running) == ""
  end

  test "stream, tool, and direct proposals expose the locked rewrite" do
    base = edit(self())

    proposed =
      base
      |> InlineEdit.thinking(self())
      |> InlineEdit.append_proposal("A")
      |> InlineEdit.append_proposal("B")
      |> InlineEdit.proposed()

    tool =
      base
      |> InlineEdit.thinking(self())
      |> InlineEdit.install_proposal("TOOL")
      |> InlineEdit.append_proposal("stream")

    empty = InlineEdit.proposed(base, "")

    assert InlineEdit.proposed?(proposed)
    assert InlineEdit.session_pid(proposed) == nil
    assert InlineEdit.rewrite(proposed) == "AB"
    assert InlineEdit.rewrite(tool) == "TOOL"
    assert InlineEdit.proposed?(empty)
    assert InlineEdit.rewrite(empty) == ""
  end

  test "failure clears session and exposes message as rewrite" do
    failed = self() |> edit() |> InlineEdit.thinking(self()) |> InlineEdit.fail("boom")

    assert InlineEdit.failed?(failed)
    assert InlineEdit.session_pid(failed) == nil
    assert InlineEdit.rewrite(failed) == "boom"
  end

  test "store rejects foreign overlays and polluted stores cannot claim sessions or crash dismiss" do
    buffer_pid = self()
    store = InlineEdit.put(%{}, edit(buffer_pid))

    assert InlineEdit.put(store, %{buffer_pid: buffer_pid}) == store

    refute InlineEdit.session?(
             %{buffer_pid => %{buffer_pid: buffer_pid, session: self()}},
             self()
           )

    assert {%{}, nil} = InlineEdit.dismiss(%{buffer_pid => %{buffer_pid: buffer_pid}}, buffer_pid)
  end

  defp edit(buffer_pid),
    do: InlineEdit.new(buffer_pid, buffer_ref("scratch.ex"), "scratch.ex", {0, 0}, "old")

  defp buffer_ref(name), do: %FileRef{kind: :buffer, display_name: name, buffer_pid: self()}
end
