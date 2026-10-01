alias MingaAgent.ArtifactQuota
alias MingaAgent.ArtifactStore
alias MingaAgent.Config
alias MingaAgent.Tool.Output
alias MingaAgent.Tool.Output.Range
alias MingaAgent.Tools.DirectoryListing
alias MingaAgent.Tools.Grep
alias MingaAgent.Tools.OutputCapture
alias MingaAgent.Tools.OutputLimit

iterations = 20
search_iterations = 5
repository = System.argv() |> List.first() |> Kernel.||(File.cwd!()) |> Path.expand()

bench_root =
  Path.join(
    System.tmp_dir!(),
    "minga-retained-output-bench-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
  )

File.mkdir_p!(bench_root)

percentile = fn
  [], _fraction ->
    nil

  values, fraction ->
    sorted = Enum.sort(values)
    Enum.at(sorted, max(ceil(length(sorted) * fraction) - 1, 0))
end

summarize = fn values ->
  %{p50: percentile.(values, 0.50), p95: percentile.(values, 0.95)}
end

distribution = fn values ->
  values
  |> Enum.frequencies()
  |> Enum.sort_by(fn {value, _count} -> value end)
  |> Enum.map(fn {value, count} -> %{value: value, count: count} end)
end

process_memories = fn labeled_pids ->
  Map.new(labeled_pids, fn {label, pid} ->
    bytes =
      case Process.info(pid, [:memory, :binary]) do
        [memory: process_bytes, binary: binaries] ->
          process_bytes + Enum.sum(Enum.map(binaries, &elem(&1, 1)))

        nil ->
          0
      end

    {label, bytes}
  end)
end

sampler_loop = fn sampler_loop, owner, labeled_pids, baseline, peaks ->
  receive do
    :stop ->
      deltas =
        Map.new(peaks, fn {label, peak} ->
          {label, max(peak - Map.fetch!(baseline, label), 0)}
        end)

      send(owner, {:memory_peak, self(), deltas})
  after
    1 ->
      observed = process_memories.(labeled_pids)

      next_peaks =
        Map.merge(peaks, observed, fn _label, peak, current -> max(peak, current) end)

      sampler_loop.(sampler_loop, owner, labeled_pids, baseline, next_peaks)
  end
end

run_with_peak_memory = fn pids, callback ->
  parent = self()

  producer =
    spawn(fn ->
      send(parent, {:producer_ready, self()})

      receive do
        :run ->
          started = System.monotonic_time()
          result = callback.()
          finished = System.monotonic_time()
          send(parent, {:producer_result, self(), result, finished - started})

          receive do
            :release -> :ok
          end
      end
    end)

  receive do
    {:producer_ready, ^producer} -> :ok
  end

  measured_pids = [{:producer, producer} | pids]
  baseline = process_memories.(measured_pids)

  sampler =
    spawn(fn -> sampler_loop.(sampler_loop, parent, measured_pids, baseline, baseline) end)

  send(producer, :run)

  {result, elapsed_native} =
    receive do
      {:producer_result, ^producer, result, elapsed_native} -> {result, elapsed_native}
    end

  send(sampler, :stop)

  peak_delta =
    receive do
      {:memory_peak, ^sampler, deltas} -> deltas
    end

  send(producer, :release)

  %{
    result: result,
    elapsed_us: System.convert_time_unit(elapsed_native, :native, :microsecond),
    observed_peak_process_memory_delta_bytes: peak_delta
  }
end

max_memory_deltas = fn samples ->
  samples
  |> Enum.flat_map(fn sample ->
    Map.to_list(sample.observed_peak_process_memory_delta_bytes)
  end)
  |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  |> Map.new(fn {label, values} -> {label, Enum.max(values)} end)
end

directory_usage = fn directory ->
  walk = fn walk, path ->
    case File.ls(path) do
      {:ok, names} ->
        Enum.reduce(names, {0, 0}, fn name, {bytes, files} ->
          child = Path.join(path, name)

          case File.lstat(child) do
            {:ok, %{type: :directory}} ->
              {child_bytes, child_files} = walk.(walk, child)
              {bytes + child_bytes, files + child_files}

            {:ok, %{type: :regular, size: size}} ->
              {bytes + size, files + 1}

            _other ->
              {bytes, files}
          end
        end)

      _error ->
        {0, 0}
    end
  end

  walk.(walk, directory)
end

start_pair = fn root, session_id ->
  {:ok, quota} = ArtifactQuota.start_link(root: root)
  {:ok, store} = ArtifactStore.start_link(root: root, quota: quota, session_id: session_id)
  {quota, store}
end

stop_pair = fn quota, store ->
  if Process.alive?(store), do: GenServer.stop(store, :normal)
  if Process.alive?(quota), do: GenServer.stop(quota, :normal)
  :ok
end

drain_preads = fn drain_preads, traced_pid, requested, calls ->
  receive do
    {:trace, ^traced_pid, :call, {:file, :pread, [_io, _offset, count]}}
    when is_integer(count) and count >= 0 ->
      drain_preads.(drain_preads, traced_pid, requested + count, calls + 1)
  after
    10 -> {requested, calls}
  end
end

trace_fetch = fn store, reference, range ->
  :erlang.trace_pattern({:file, :pread, 3}, true, [])
  :erlang.trace(store, true, [:call])
  started = System.monotonic_time()

  result =
    case {range.unit, ArtifactStore.fetch(store, reference, range)} do
      {:bytes, {:ok, fetched}} when byte_size(fetched.bytes) == range.count ->
        :ok

      {:items, {:ok, fetched}} ->
        if length(String.split(fetched.bytes, "\n", trim: true)) == range.count,
          do: :ok,
          else: raise("late item-page fetch returned the wrong record count")

      other ->
        raise "late-page fetch failed: #{inspect(other)}"
    end

  elapsed = System.monotonic_time() - started
  :erlang.trace(store, false, [:call])
  :erlang.trace_pattern({:file, :pread, 3}, false, [])
  {requested_bytes, calls} = drain_preads.(drain_preads, store, 0, 0)

  %{
    result: result,
    elapsed_us: System.convert_time_unit(elapsed, :native, :microsecond),
    storage_pread_requested_bytes: requested_bytes,
    storage_pread_calls: calls
  }
end

summarize_fetches = fn
  [] ->
    nil

  fetches ->
    %{
      latency_us: summarize.(Enum.map(fetches, & &1.elapsed_us)),
      pread_requested_bytes: distribution.(Enum.map(fetches, & &1.storage_pread_requested_bytes)),
      pread_calls: distribution.(Enum.map(fetches, & &1.storage_pread_calls))
    }
end

fixture_identity = fn label, bytes ->
  %{
    label: label,
    bytes: byte_size(bytes),
    sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  }
end

legacy_measure = fn label, bytes ->
  samples =
    for _iteration <- 1..iterations do
      run_with_peak_memory.([], fn ->
        OutputLimit.truncate_utf8(bytes, OutputLimit.default_max_bytes(), "\n[truncated]")
      end)
    end

  %{
    label: label,
    capture_to_visible_us: summarize.(Enum.map(samples, & &1.elapsed_us)),
    observed_peak_process_memory_delta_bytes: max_memory_deltas.(samples),
    retrieval: %{available: false, reason: "legacy truncation retains no exact backing bytes"},
    visible_bytes: samples |> hd() |> Map.fetch!(:result) |> byte_size()
  }
end

retained_measure = fn label, bytes ->
  samples =
    for iteration <- 1..iterations do
      root = Path.join(bench_root, "#{label}-#{iteration}")
      File.mkdir_p!(root)
      session_id = "#{label}-record"
      {quota, store} = start_pair.(root, session_id)
      key = {:delivery, "#{label}-#{iteration}", "capture"}

      captured =
        run_with_peak_memory.([artifact_store: store, artifact_quota: quota], fn ->
          OutputCapture.bytes(store, key, bytes, [])
        end)

      {warm, cold, outcome} =
        case captured.result do
          {_result_kind, %Output{reference: reference}} when reference != nil ->
            count = min(65_536, reference.bytes)
            offset = reference.bytes - count
            {:ok, range} = Range.new(:page, :bytes, offset, count, reference.bytes)
            warm = trace_fetch.(store, reference, range)
            stop_pair.(quota, store)
            {cold_quota, cold_store} = start_pair.(root, session_id)
            cold = trace_fetch.(cold_store, reference, range)
            stop_pair.(cold_quota, cold_store)
            {warm, cold, inspect(elem(captured.result, 0))}

          {result_kind, _reason} ->
            stop_pair.(quota, store)
            {nil, nil, inspect(result_kind)}
        end

      {disk_bytes, file_count} = directory_usage.(root)
      File.rm_rf!(root)

      %{
        capture_to_visible_us: captured.elapsed_us,
        observed_peak_process_memory_delta_bytes:
          captured.observed_peak_process_memory_delta_bytes,
        warm: warm,
        cold: cold,
        retained_disk_bytes: disk_bytes,
        retained_file_count: file_count,
        outcome: outcome
      }
    end

  warm = samples |> Enum.map(& &1.warm) |> Enum.reject(&is_nil/1)
  cold = samples |> Enum.map(& &1.cold) |> Enum.reject(&is_nil/1)

  %{
    label: label,
    capture_to_visible_us: summarize.(Enum.map(samples, & &1.capture_to_visible_us)),
    late_page_warm: summarize_fetches.(warm),
    late_page_cold_after_store_and_quota_reopen: summarize_fetches.(cold),
    observed_peak_process_memory_delta_bytes: max_memory_deltas.(samples),
    retained_disk_bytes: distribution.(Enum.map(samples, & &1.retained_disk_bytes)),
    retained_file_count: distribution.(Enum.map(samples, & &1.retained_file_count)),
    outcomes: distribution.(Enum.map(samples, & &1.outcome))
  }
end

sub_cap = String.duplicate("0123456789abcdef", 256)
ten_x_visible_cap = String.duplicate("åbcdefghijklmno", 32_000)
quota_crossing = :binary.copy("q", Config.artifact_limits().capture_bytes + 1)

fixtures = [
  {"sub-cap", sub_cap},
  {"ten-x-visible-cap", ten_x_visible_cap},
  {"quota-crossing", quota_crossing}
]

capture_cases =
  Enum.map(fixtures, fn {label, bytes} ->
    %{
      fixture: fixture_identity.(label, bytes),
      retained: retained_measure.(label, bytes),
      legacy_baseline: legacy_measure.(label, bytes)
    }
  end)

ignored_names = MapSet.new(DirectoryListing.ignored_names())

corpus_files = fn root ->
  walk = fn walk, path, relative ->
    path
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      if MapSet.member?(ignored_names, name) do
        []
      else
        child = Path.join(path, name)
        child_relative = if relative == "", do: name, else: Path.join(relative, name)

        case File.lstat(child) do
          {:ok, %{type: :directory}} -> walk.(walk, child, child_relative)
          {:ok, %{type: :regular, size: size}} -> [{child_relative, child, size}]
          _other -> []
        end
      end
    end)
  end

  walk.(walk, root, "")
end

repository_files = corpus_files.(repository)

repository_digest =
  repository_files
  |> Enum.reduce(:crypto.hash_init(:sha256), fn {relative, path, size}, context ->
    file_digest = path |> File.read!() |> then(&:crypto.hash(:sha256, &1))
    :crypto.hash_update(context, [relative, <<0>>, Integer.to_string(size), <<0>>, file_digest])
  end)
  |> :crypto.hash_final()
  |> Base.encode16(case: :lower)

repository_commit =
  case System.cmd("git", ["-C", repository, "rev-parse", "HEAD"], stderr_to_stdout: true) do
    {commit, 0} -> String.trim(commit)
    {_message, _status} -> nil
  end

search_retained_samples =
  for iteration <- 1..search_iterations do
    root = Path.join(bench_root, "repository-search-#{iteration}")
    File.mkdir_p!(root)
    {quota, store} = start_pair.(root, "repository-search-record")

    sample =
      run_with_peak_memory.([artifact_store: store, artifact_quota: quota], fn ->
        Grep.capture("defmodule", repository, %{},
          artifact_store: store,
          capture_key: {:delivery, "repository-search-#{iteration}", "grep"},
          filter_root: repository
        )
      end)

    {warm, cold} =
      case sample.result do
        {_kind, %Output{reference: reference}} when reference != nil ->
          count = min(100, reference.items)
          {:ok, range} = Range.new(:page, :items, reference.items - count, count, reference.items)
          warm = trace_fetch.(store, reference, range)
          stop_pair.(quota, store)
          {cold_quota, cold_store} = start_pair.(root, "repository-search-record")
          cold = trace_fetch.(cold_store, reference, range)
          stop_pair.(cold_quota, cold_store)
          {warm, cold}

        _error ->
          stop_pair.(quota, store)
          {nil, nil}
      end

    output_summary =
      case sample.result do
        {:ok, output} ->
          %{
            status: "ok",
            captured_bytes: output.reference.bytes,
            visible_bytes: byte_size(output.view)
          }

        {:error, %Output{} = output} ->
          %{
            status: "incomplete",
            captured_bytes: output.reference && output.reference.bytes,
            visible_bytes: byte_size(output.view),
            capture: inspect(output.capture)
          }

        {:error, reason} ->
          %{status: "error", reason: inspect(reason)}
      end

    {disk_bytes, file_count} = directory_usage.(root)
    File.rm_rf!(root)

    %{
      elapsed_us: sample.elapsed_us,
      observed_peak_process_memory_delta_bytes: sample.observed_peak_process_memory_delta_bytes,
      retained_disk_bytes: disk_bytes,
      retained_file_count: file_count,
      warm: warm,
      cold: cold,
      output: output_summary
    }
  end

search_legacy_samples =
  for _iteration <- 1..search_iterations do
    run_with_peak_memory.([], fn ->
      Grep.execute("defmodule", repository, %{}, filter_root: repository)
    end)
  end

report = %{
  optimized_build: System.get_env("MIX_ENV") == "prod",
  methodology: %{
    latency: "monotonic clock around public capture/search calls; p50/p95 are nearest-rank",
    memory:
      "1ms polling of producer + ArtifactStore + ArtifactQuota process :memory plus referenced off-heap binary bytes; reported per-process deltas subtract each ready-state baseline after fixture allocation; sub-millisecond spikes may be missed",
    storage_reads:
      "call tracing of :file.pread/3 only on the ArtifactStore pid during the measured late-page fetch; requested count arguments are summed",
    cold_retrieval:
      "ArtifactStore and ArtifactQuota are both stopped normally and reopened from the same durable root before fetch",
    disk: "recursive regular-file logical sizes and counts under each isolated artifact root",
    legacy:
      "same in-memory byte fixture through unchanged OutputLimit.truncate_utf8/3; repository baseline uses Grep.execute/4; exact late retrieval is unavailable"
  },
  capture_cases: capture_cases,
  large_repository_search: %{
    fixture_identity: %{
      root: repository,
      git_head: repository_commit,
      candidate_regular_files: length(repository_files),
      candidate_regular_bytes: Enum.sum(Enum.map(repository_files, &elem(&1, 2))),
      candidate_corpus_sha256: repository_digest,
      corpus_note:
        "candidate corpus excludes DirectoryListing ignored basenames; it is measured fixture size, not a claim that the search executable read every byte"
    },
    retained: %{
      capture_to_visible_us: summarize.(Enum.map(search_retained_samples, & &1.elapsed_us)),
      late_page_warm:
        summarize_fetches.(
          search_retained_samples
          |> Enum.map(& &1.warm)
          |> Enum.reject(&is_nil/1)
        ),
      late_page_cold_after_store_and_quota_reopen:
        summarize_fetches.(
          search_retained_samples
          |> Enum.map(& &1.cold)
          |> Enum.reject(&is_nil/1)
        ),
      observed_peak_process_memory_delta_bytes: max_memory_deltas.(search_retained_samples),
      retained_disk_bytes:
        distribution.(Enum.map(search_retained_samples, & &1.retained_disk_bytes)),
      retained_file_count:
        distribution.(Enum.map(search_retained_samples, & &1.retained_file_count)),
      outcomes: Enum.map(search_retained_samples, & &1.output)
    },
    legacy_baseline: %{
      capture_to_visible_us: summarize.(Enum.map(search_legacy_samples, & &1.elapsed_us)),
      observed_peak_process_memory_delta_bytes: max_memory_deltas.(search_legacy_samples),
      retrieval: %{available: false, reason: "Grep.execute/4 returns only its visible page"},
      outcomes: distribution.(Enum.map(search_legacy_samples, &inspect(&1.result)))
    }
  }
}

IO.puts(JSON.encode!(report))
File.rm_rf!(bench_root)
