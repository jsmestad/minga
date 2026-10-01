defmodule Minga.Smoke.RetainedOutput do
  @moduledoc false

  alias Minga.Buffer
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStores
  alias MingaAgent.ArtifactSupervisor
  alias MingaAgent.Session.Continuation
  alias MingaAgent.SessionStore
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.ToolCall
  alias MingaAgent.ToolRouter.Context
  alias MingaAgent.ToolRouter.SourceCapture
  alias MingaAgent.Tools.Grep
  alias MingaAgent.Tools.OutputCapture
  alias MingaAgent.TurnUsage

  @record "retained-output-smoke"
  @source String.duplicate("αβγ retained output\n", 10_000)

  @spec run([String.t()]) :: :ok
  def run([phase, root]) when phase in ["capture", "restore"] do
    opts = [
      name: Minga.Smoke.ArtifactSupervisor,
      root: Path.join(root, "artifacts"),
      quota: Minga.Smoke.ArtifactQuota,
      registry: Minga.Smoke.ArtifactRegistry,
      store_supervisor: Minga.Smoke.ArtifactStores
    ]

    {:ok, supervisor} = ArtifactSupervisor.start_link(opts)
    {:ok, runtime} = ArtifactSupervisor.runtime(opts)
    {:ok, store} = ArtifactStores.ensure_record(@record, runtime)

    try do
      case phase do
        "capture" -> capture(root, store, runtime)
        "restore" -> restore(root, store, runtime)
      end
    after
      Supervisor.stop(supervisor)
    end
  end

  def run(_args),
    do:
      raise(
        "Usage: MIX_ENV=prod mix run scripts/retained_output_smoke.exs capture|restore /tmp/owned-smoke-root"
      )

  @spec capture(String.t(), GenServer.server(), ArtifactStores.Runtime.t()) :: :ok
  defp capture(root, store, runtime) do
    project = Path.join(root, "project")
    File.mkdir_p!(project)
    {_, 0} = System.cmd("git", ["init", "--quiet", project])
    path = Path.join(project, "unsaved.txt")
    File.write!(path, "disk content")
    {:ok, buffer} = Buffer.start_link(file_path: path)
    :ok = Buffer.replace_content(buffer, @source)

    ensure!(
      Buffer.content(buffer) == @source and File.read!(path) != @source,
      "fixture is not an unsaved buffer"
    )

    {:ok, read} =
      SourceCapture.capture(%Context{}, path, store, {:delivery, "read-checkpoint", "read"}, [])

    ensure!(
      read.capture == :complete and read.reference.bytes == byte_size(@source),
      "unsaved buffer capture is incomplete"
    )

    ensure!(
      byte_size(read.view) < read.reference.bytes,
      "read did not exceed its presentation cap"
    )

    {:ok, range} = Range.new(:page, :bytes, 100_000, 65_536, read.reference.bytes)
    {:ok, page} = ArtifactStore.fetch(store, read.reference, range)

    ensure!(
      page.bytes == binary_part(@source, 100_000, 65_536),
      "read page differs from unsaved content"
    )

    :ok = Buffer.replace_content(buffer, String.replace(@source, "retained", "changed!"))
    GenServer.stop(buffer)
    File.write!(path, "source replaced on disk")

    matches = Enum.map_join(1..250, "\n", &"α match-#{&1}") <> "\n"
    File.write!(Path.join(project, "matches.txt"), matches)
    File.write!(Path.join(project, ".gitignore"), "ignored.txt\n")
    File.write!(Path.join(project, "ignored.txt"), "α match-ignored\n")

    {:ok, search} =
      Grep.capture("α match", project, %{},
        artifact_store: store,
        capture_key: {:delivery, "search-checkpoint", "grep"},
        filter_root: project
      )

    ensure!(
      search.capture == :complete and search.reference.items == 250,
      "search did not retain all nonignored matches"
    )

    ensure!(
      match?({:truncated, _}, search.presentation),
      "search did not exceed its first presentation page"
    )

    {:ok, late_range} = Range.new(:page, :items, 248, 2, search.reference.items)
    {:ok, late} = ArtifactStore.fetch(store, search.reference, late_range)

    ensure!(
      late.bytes =~ "match-249" and late.bytes =~ "match-250",
      "late search page differs from captured matches"
    )

    File.write!(Path.join(project, "matches.txt"), "no original matches remain\n")

    disk_path = Path.join(project, "same-size.txt")
    File.write!(disk_path, "aaaa")
    mtime = File.stat!(disk_path).mtime

    {:ok, disk_before} =
      SourceCapture.capture(%Context{}, disk_path, store, {:delivery, "disk-before", "read"}, [])

    File.write!(disk_path, "bbbb")
    File.touch!(disk_path, mtime)

    {:ok, disk_after} =
      SourceCapture.capture(%Context{}, disk_path, store, {:delivery, "disk-after", "read"}, [])

    ensure!(
      disk_before.revision != disk_after.revision,
      "same-size same-mtime disk edit retained its revision"
    )

    {:ok, continuation} =
      Continuation.replace_messages(Continuation.new(), [
        ReqLLM.Context.user("original task"),
        ReqLLM.Context.assistant("completed reads")
      ])

    {:ok, compacted} =
      Continuation.replace_messages(continuation, [
        ReqLLM.Context.system("Compacted task: retain the original read and search references")
      ])

    messages =
      Enum.map([{"read", read}, {"grep", search}], fn {name, output} ->
        {:tool_call, ToolCall.new(name, name) |> ToolCall.complete(output.view, output)}
      end)

    data = %{
      id: @record,
      model_name: "retention-smoke",
      provider_name: "native",
      messages: messages,
      usage: TurnUsage.new(),
      continuation: compacted
    }

    :ok = SessionStore.save(data, Path.join(root, "config"), artifact_runtime: runtime)
    :ok = ArtifactStore.release(store, {:delivery, "read-checkpoint", "read"})
    :ok = ArtifactStore.release(store, {:delivery, "search-checkpoint", "grep"})
    {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)
    oversized = :binary.copy("x", runtime.limits.capture_bytes + 1)

    ensure!(
      match?(
        {:error, :capture_byte_limit},
        OutputCapture.bytes(store, {:delivery, "refused", "read"}, oversized, [])
      ),
      "oversized capture was not refused before retention"
    )

    ensure!(
      match?(
        {:error, :unknown_delivery},
        ArtifactStore.lookup_delivery(store, {:delivery, "refused", "read"})
      ),
      "refused capture created a delivery"
    )

    IO.puts(
      JSON.encode!(%{
        phase: "capture",
        status: "ok",
        unsaved_bytes: read.reference.bytes,
        retained_search_items: search.reference.items,
        same_metadata_revision_changed: true,
        compacted_and_snapshot_pinned: true,
        quota_refusal_verified: true
      })
    )

    :ok
  end

  @spec restore(String.t(), GenServer.server(), ArtifactStores.Runtime.t()) :: :ok
  defp restore(root, store, runtime) do
    {:ok, data} = SessionStore.load(@record, Path.join(root, "config"), artifact_runtime: runtime)
    [{:tool_call, read}, {:tool_call, search}] = data.messages
    {:ok, range} = Range.new(:page, :bytes, 100_000, 65_536, read.output.reference.bytes)
    {:ok, page} = ArtifactStore.fetch(store, read.output.reference, range)

    ensure!(
      page.bytes == binary_part(@source, 100_000, 65_536),
      "application restart lost original unsaved bytes"
    )

    {:ok, range} = Range.new(:page, :items, 248, 2, search.output.reference.items)
    {:ok, page} = ArtifactStore.fetch(store, search.output.reference, range)

    ensure!(
      page.bytes =~ "match-249" and page.bytes =~ "match-250",
      "application restart replayed changed search sources"
    )

    ensure!(
      File.read!(Path.join(root, "project/matches.txt")) == "no original matches remain\n",
      "search source mutation was not preserved"
    )

    ensure!(
      length(data.continuation.messages) == 1,
      "snapshot did not preserve the compacted boundary"
    )

    IO.puts(
      JSON.encode!(%{
        phase: "restore",
        status: "ok",
        original_unsaved_bytes_verified: true,
        original_search_page_verified: true,
        compacted_boundary_verified: true
      })
    )

    :ok
  end

  @spec ensure!(boolean(), String.t()) :: :ok
  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(message)
end

Minga.Smoke.RetainedOutput.run(System.argv())
