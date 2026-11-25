defmodule Minga.Bench.WorkspaceSymbolQuery do
  @moduledoc """
  Workspace symbol picker cost per keystroke, baseline against candidate (#3498).

  A fake language server holds a fixture of N workspace symbols and answers `workspace/symbol` from responses computed before timing starts, so the numbers measure only Minga's side. Time is split by the process that pays it, following the production path:

    * worker: the picker fetch worker runs `candidates/1` (request, response copy, item formatting) and `Candidate.from_items/1`.
    * editor: the Editor process runs the query edit (`Picker.filter/2` in the baseline, `Picker.filter_with_match_query/3` in the candidate) and installs a fetch result (`Picker.put_candidates/3`).

  The checked-out commit decides the pipeline, so run the script once on the baseline commit and once on the candidate commit:

    * baseline (no `WorkspaceSymbolSource.fetch_identity/1`): opening the picker requests the empty query and receives every symbol; each keystroke filters those items locally.
    * candidate: opening the picker sends no request; each keystroke requests its query, and the picker shows the server rows without filtering them again.

  Each sample runs in a fresh process. Workloads cover 10,000 and 100,000 symbols with a short query, a long query, and a rapidly replaced query sequence.

  Run with:

      MIX_ENV=test mix run bench/workspace_symbol_query.exs [SAMPLES]

  Output is printed; do not commit it (AGENTS.md, "Benchmark results stay out of the tree").
  """

  alias Minga.LSP.SyncServer
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.WorkspaceSymbolSource

  @sizes [10_000, 100_000]
  @workloads [
    {"short", ["f"]},
    {"long", ["Module4242.function_42"]},
    {"rapid", ["f", "fu", "fun", "func", "funct"]}
  ]

  def run(samples) do
    Code.ensure_loaded!(WorkspaceSymbolSource)
    mode = if function_exported?(WorkspaceSymbolSource, :fetch_identity, 1), do: :candidate, else: :baseline
    IO.puts("mode=#{mode} commit=#{commit()} samples=#{samples} otp=#{System.otp_release()}")

    IO.puts(
      "size\tworkload\trequests\tresponse_bytes\titems_built\tretained_words\topen_worker_p50_us\topen_editor_p50_us\tkey_editor_p10_us\tkey_editor_p50_us\tkey_editor_p90_us\tkey_worker_p50_us"
    )

    for size <- @sizes, {name, queries} <- @workloads do
      symbols = fixture(size)
      responses = Map.new(["" | queries], &{&1, server_filter(symbols, &1)})

      results = for _ <- 1..samples, do: isolated(fn -> sample(mode, responses, queries) end)
      report(size, name, results)
    end
  end

  # One open plus one keystroke per query, timed separately.
  defp sample(mode, responses, queries) do
    buffer = self()
    server = spawn_link(fn -> fake_server(responses, 0, 0) end)
    SyncServer.put_clients(buffer, [server])

    {open_times, picker} = open(buffer)

    {key_times, picker} =
      Enum.map_reduce(queries, picker, fn query, picker -> keystroke(mode, buffer, picker, query) end)

    send(server, {:stats, self()})

    receive do
      {:stats, requests, bytes} ->
        %{
          open: open_times,
          keys: key_times,
          requests: requests,
          bytes: bytes,
          items_built: picker_items_built(picker),
          retained: :erts_debug.flat_size(picker)
        }
    end
  after
    :ets.delete(SyncServer.registry_table(), self())
  end

  # Both commits fetch once when the picker opens.
  defp open(buffer) do
    empty = Picker.new([], title: "Workspace Symbols", max_visible: 40)
    {worker_us, {items, candidates}} = :timer.tc(fn -> fetch(buffer, nil) end)
    {editor_us, picker} = :timer.tc(fn -> Picker.put_candidates(empty, items, candidates) end)
    {%{worker: worker_us, editor: editor_us}, picker}
  end

  # The baseline filters the items it already holds, in the Editor.
  defp keystroke(:baseline, _buffer, picker, query) do
    {editor_us, picker} = :timer.tc(fn -> Picker.filter(picker, query) end)
    {%{worker: 0, editor: editor_us}, picker}
  end

  # The candidate records the query in the Editor, fetches in the worker, and installs the result in the Editor.
  defp keystroke(:candidate, buffer, picker, query) do
    {edit_us, picker} = :timer.tc(fn -> Picker.filter_with_match_query(picker, query, "") end)
    {worker_us, {items, candidates}} = :timer.tc(fn -> fetch(buffer, picker) end)
    {install_us, picker} = :timer.tc(fn -> Picker.put_candidates(picker, items, candidates) end)
    {%{worker: worker_us, editor: edit_us + install_us}, picker}
  end

  defp fetch(buffer, picker) do
    items = WorkspaceSymbolSource.candidates(context(buffer, picker))
    Process.put(:items_built, Process.get(:items_built, 0) + length(items))
    {items, MingaEditor.UI.Picker.Candidate.from_items(items)}
  end

  defp picker_items_built(_picker), do: Process.get(:items_built, 0)

  defp context(buffer, picker) do
    picker_ui = %PickerState{picker: picker, source: if(picker, do: WorkspaceSymbolSource)}

    %Context{
      buffers: %{active: buffer},
      editing: nil,
      search: nil,
      viewport: nil,
      tab_bar: nil,
      picker_ui: picker_ui,
      capabilities: nil,
      theme: nil
    }
  end

  defp fake_server(responses, requests, bytes) do
    receive do
      {:"$gen_cast", {:async_request, "workspace/symbol", %{"query" => query}, caller, ref}} ->
        response = Map.fetch!(responses, query)
        send(caller, {:lsp_response, ref, {:ok, response}})
        fake_server(responses, requests + 1, bytes + :erlang.external_size(response))

      {:stats, pid} ->
        send(pid, {:stats, requests, bytes})
    end
  end

  # Stands in for server-side filtering, computed before timing.
  defp server_filter(symbols, ""), do: symbols

  defp server_filter(symbols, query) do
    needle = String.downcase(query)
    Enum.filter(symbols, &String.contains?(String.downcase(&1["name"]), needle))
  end

  defp fixture(size) do
    for i <- 1..size do
      module = "Module#{rem(i, 5_000)}"
      name = if rem(i, 7) == 0, do: "#{module}.function_#{rem(i, 100)}", else: "#{module}.value_#{i}"

      %{
        "name" => name,
        "kind" => 12,
        "containerName" => module,
        "location" => %{
          "uri" => "file:///project/lib/module_#{rem(i, 5_000)}.ex",
          "range" => %{"start" => %{"line" => rem(i, 400), "character" => 2}}
        }
      }
    end
  end

  defp isolated(fun) do
    parent = self()
    ref = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(parent, {ref, fun.()}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        raise "sample failed: #{inspect(reason)}"
    end
  end

  defp report(size, name, results) do
    first = hd(results)
    keys = Enum.flat_map(results, & &1.keys)
    key_editor = Enum.map(keys, & &1.editor)
    opens = Enum.map(results, & &1.open)

    IO.puts(
      Enum.join(
        [
          size,
          name,
          first.requests,
          first.bytes,
          first.items_built,
          first.retained,
          percentile(Enum.map(opens, & &1.worker), 50),
          percentile(Enum.map(opens, & &1.editor), 50),
          percentile(key_editor, 10),
          percentile(key_editor, 50),
          percentile(key_editor, 90),
          percentile(Enum.map(keys, & &1.worker), 50)
        ],
        "\t"
      )
    )
  end

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, div(p * length(sorted), 100)))
  end

  defp commit do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end

samples =
  case System.argv() do
    [n | _] -> String.to_integer(n)
    [] -> 15
  end

Minga.Bench.WorkspaceSymbolQuery.run(samples)
