defmodule MingaEditor.Effects.GuiSearchBuildTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Search.Index
  alias MingaEditor.Effects.GuiSearchBuild
  alias MingaEditor.Effects.GuiSearchBuild.Result

  test "request uses one semantic latest-wins resource and a finite timeout" do
    request = GuiSearchBuild.request(self(), "foo", [], 3, true)

    assert request.resource == :gui_search
    assert request.policy.mode == :latest_wins
    assert request.timeout_ms == 10_000
    assert request.effect.search_revision == 3
    assert request.effect.select_first?
  end

  test "worker acquires a token-qualified atomic snapshot and returns no document content" do
    buffer = start_supervised!({BufferProcess, content: "foo\nnone\nfoo"})

    assert {:ok,
            %Result{
              buffer: ^buffer,
              version: 0,
              sequence: 0,
              search_revision: 4,
              index: index
            } = result} =
             GuiSearchBuild.run(%GuiSearchBuild{
               buffer: buffer,
               query: "foo",
               options: [],
               search_revision: 4,
               select_first?: false
             })

    assert Index.count(index) == 2
    refute inspect(result) =~ "none"
    assert Buffer.sync_revision(buffer) == {0, 0}
  end

  test "dead buffers fail explicitly instead of waiting forever" do
    buffer = spawn(fn -> :ok end)
    ref = Process.monitor(buffer)
    assert_receive {:DOWN, ^ref, :process, ^buffer, _reason}

    assert {:error, message} =
             GuiSearchBuild.run(%GuiSearchBuild{
               buffer: buffer,
               query: "foo",
               options: [],
               search_revision: 1,
               select_first?: false
             })

    assert message =~ "buffer unavailable"
  end

  @tag timeout: 3_000
  test "an alive non-buffer target becomes an explicit acquisition timeout" do
    target = spawn(fn -> ignore_messages() end)

    assert {:error, "buffer snapshot timed out"} =
             GuiSearchBuild.run(%GuiSearchBuild{
               buffer: target,
               query: "foo",
               options: [],
               search_revision: 1,
               select_first?: false
             })
  end

  defp ignore_messages do
    receive do
      _message -> ignore_messages()
    end
  end
end
