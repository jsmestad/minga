Code.require_file("credo/checks/no_blocking_handle_info_check.exs")

defmodule Minga.Credo.NoBlockingHandleInfoCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.NoBlockingHandleInfoCheck

  @moduletag :credo

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source_code, params \\ [], filename \\ "lib/minga_editor.ex") do
    source_code
    |> to_source_file(filename)
    |> run_check(NoBlockingHandleInfoCheck, params)
  end

  # ── Flagged inline blocking work ───────────────────────────────────────────

  test "flags inline File.ls in a handle_info clause" do
    """
    defmodule MingaEditor do
      def handle_info({:scan_dir, path}, state) do
        {:ok, _entries} = File.ls(path)
        {:noreply, state}
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "File.ls"
      assert issue.message =~ "blocks the editor GenServer mailbox"
    end)
  end

  test "flags inline GenServer.call in a handle_info clause" do
    """
    defmodule MingaEditor do
      def handle_info({:refresh, server}, state) do
        data = GenServer.call(server, :snapshot)
        {:noreply, %{state | data: data}}
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "GenServer.call"
    end)
  end

  test "flags inline request_sync in a handle_info clause" do
    """
    defmodule MingaEditor do
      def handle_info({:lsp_tick, client}, state) do
        Client.request_sync(client, "textDocument/formatting", params, 5_000)
        {:noreply, state}
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "Client.request_sync"
    end)
  end

  test "flags Enum.reduce over an unbounded collection in a handle_info clause" do
    """
    defmodule MingaEditor do
      def handle_info({:recompute, _meta}, state) do
        total = Enum.reduce(state.items, 0, fn item, acc -> acc + item end)
        {:noreply, %{state | total: total}}
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "Enum.reduce"
    end)
  end

  test "flags Enum.map piped from an unbounded collection in a handle_info clause" do
    """
    defmodule MingaEditor do
      def handle_info({:rebuild, _meta}, state) do
        rows =
          state.items
          |> Enum.map(fn item -> transform(item) end)

        {:noreply, %{state | rows: rows}}
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "Enum.map"
    end)
  end

  # ── Not flagged ────────────────────────────────────────────────────────────

  test "does not flag a cheap pattern-match-and-delegate-to-Task clause" do
    """
    defmodule MingaEditor do
      def handle_info({:fetch_candidates, source, revision}, state) do
        Task.async(fn -> source.candidates(revision) end)
        {:noreply, state}
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "does not flag a pure state update clause" do
    """
    defmodule MingaEditor do
      def handle_info({:set_status, status}, state) do
        {:noreply, %{state | status: status}}
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "does not flag Enum.map over a literal list" do
    """
    defmodule MingaEditor do
      def handle_info({:seed, _meta}, state) do
        rows = Enum.map([:a, :b, :c], &to_string/1)
        {:noreply, %{state | rows: rows}}
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "does not flag blocking work in a non-handle_info function" do
    """
    defmodule MingaEditor do
      def open_file(server, path) do
        GenServer.call(server, {:open_file, path})
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  # ── Allowlist ──────────────────────────────────────────────────────────────

  test "suppresses a flagged clause whose message tag is in the default allowlist" do
    # :observatory_tick is a known in-flight violator (#2631). Even with an
    # inline primitive present, the clause is suppressed by its message tag.
    """
    defmodule MingaEditor do
      def handle_info({:observatory_tick, token}, state) do
        data = GenServer.call(:observer, :snapshot)
        {:noreply, %{state | data: data}}
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "suppresses the bare-atom file-tree refresh tag in the default allowlist" do
    """
    defmodule MingaEditor do
      def handle_info(:file_tree_refresh_timer, state) do
        {:ok, _} = File.ls(state.root)
        {:noreply, state}
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "allows extending the allowlist via the allow param" do
    """
    defmodule MingaEditor do
      def handle_info({:custom_tick, _meta}, state) do
        data = GenServer.call(:server, :data)
        {:noreply, %{state | data: data}}
      end
    end
    """
    |> check(allow: [:custom_tick])
    |> refute_issues()
  end

  # ── Inline comment suppression ─────────────────────────────────────────────

  test "suppresses with minga:allow-blocking comment and justification" do
    """
    defmodule MingaEditor do
      def handle_info({:tiny_scan, path}, state) do
        File.ls(path) # minga:allow-blocking — bounded single-dir scan, <1ms
        {:noreply, state}
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  # ── Scope filtering ────────────────────────────────────────────────────────

  test "skips files outside the editor" do
    """
    defmodule Minga.Git.Watcher do
      def handle_info({:scan, path}, state) do
        File.ls(path)
        {:noreply, state}
      end
    end
    """
    |> check([], "lib/minga/git/watcher.ex")
    |> refute_issues()
  end

  test "skips test files" do
    """
    defmodule MingaEditorTest do
      def handle_info({:scan, path}, state) do
        File.ls(path)
        {:noreply, state}
      end
    end
    """
    |> check([], "test/minga_editor_test.exs")
    |> refute_issues()
  end
end
