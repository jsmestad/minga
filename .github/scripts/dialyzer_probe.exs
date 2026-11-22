# Experiment for #3869 (do not merge). Runs the same classic analysis as `mix dialyzer` (same PLT, files, and warnings) and records where memory peaks.
# Usage: mix run --no-compile --no-start .github/scripts/dialyzer_probe.exs
# PROBE_FILES=tiny analyses a single small module, which measures the cost of loading the PLT.
# PROBE_TIMING=debug prints dialyzer's own per-phase memory stamps every 50 ms.
defmodule DialyzerProbe do
  def sample_loop(best) do
    receive do
      {:report, from} -> send(from, {:peak, best})
    after
      250 ->
        total = :erlang.memory(:total)

        best =
          if total > elem(best, 0) do
            {total, snapshot()}
          else
            best
          end

        sample_loop(best)
    end
  end

  defp snapshot do
    mem = :erlang.memory()

    procs =
      Process.list()
      |> Enum.map(fn pid ->
        info = Process.info(pid, [:memory, :initial_call, :current_function, :message_queue_len, :total_heap_size])
        {pid, info}
      end)
      |> Enum.reject(fn {_pid, info} -> info == nil end)
      |> Enum.sort_by(fn {_pid, info} -> -info[:memory] end)
      |> Enum.take(6)
      |> Enum.map(fn {pid, info} ->
        {pid, info[:memory], info[:initial_call], info[:current_function], info[:message_queue_len]}
      end)

    word = :erlang.system_info(:wordsize)

    ets =
      :ets.all()
      |> Enum.map(fn t -> {t, :ets.info(t, :name), :ets.info(t, :size), (:ets.info(t, :memory) || 0) * word} end)
      |> Enum.sort_by(fn {_, _, _, m} -> -m end)
      |> Enum.take(8)

    %{memory: mem, procs: procs, ets: ets, ets_count: length(:ets.all())}
  end
end

plt = Dialyxir.Project.plt_file() |> to_charlist()
files = Dialyxir.Project.dialyzer_files()

files =
  case System.get_env("PROBE_FILES") do
    "tiny" -> Enum.filter(files, &String.ends_with?(to_string(&1), "/Elixir.Minga.Core.Face.beam"))
    _ -> files
  end

timing =
  case System.get_env("PROBE_TIMING") do
    "debug" -> :debug
    _ -> true
  end

extra_flags =
  case System.get_env("PROBE_FLAGS") do
    nil -> []
    "" -> []
    flags -> flags |> String.split(",") |> Enum.map(&String.to_atom/1)
  end

warnings = [:unknown] ++ Dialyxir.Project.dialyzer_flags() ++ extra_flags
IO.puts("probe: plt=#{plt} files=#{length(files)} warnings=#{inspect(warnings)} schedulers=#{System.schedulers_online()}")

sampler = spawn(fn -> DialyzerProbe.sample_loop({0, nil}) end)

# PROBE_TRACE=1 attributes warning-phase memory to the module each worker is collecting warnings for.
if System.get_env("PROBE_TRACE") == "1" do
  table = :ets.new(:probe_modules, [:public, :named_table])

  tracer =
    spawn(fn ->
      loop = fn loop ->
        receive do
          {:trace, pid, :call, {:dialyzer_succ_typings, _, _}, mod} ->
            :ets.insert(table, {pid, {mod, :contracts_without_fun}, System.monotonic_time(:millisecond)})
            loop.(loop)

          {:trace, pid, :call, {step_mod, _, _}, _msg} ->
            step = if step_mod == :dialyzer_dataflow, do: :dataflow, else: :behaviours

            case :ets.lookup(table, pid) do
              [{^pid, {mod, _}, _}] -> :ets.insert(table, {pid, {mod, step}, System.monotonic_time(:millisecond)})
              _ -> :ok
            end

            loop.(loop)

          _ ->
            loop.(loop)
        end
      end

      loop.(loop)
    end)

  Enum.each([:dialyzer_succ_typings, :dialyzer_dataflow, :dialyzer_behaviours], &Code.ensure_loaded!/1)
  1 = :erlang.trace_pattern({:dialyzer_succ_typings, :collect_warnings, 2}, [{[:"$1", :_], [], [{:message, :"$1"}]}], [:global])
  1 = :erlang.trace_pattern({:dialyzer_dataflow, :get_warnings, 5}, [{:_, [], [{:message, :dataflow}]}], [:global])
  1 = :erlang.trace_pattern({:dialyzer_behaviours, :check_callbacks, 5}, [{:_, [], [{:message, :behaviours}]}], [:global])
  :erlang.trace(:all, true, [:call, :arity, {:tracer, tracer}])

  spawn(fn ->
    watch = fn watch, acc ->
      receive do
        {:report, from} -> send(from, {:modules, acc})
      after
        200 ->
          total = :erlang.memory(:total)

          acc =
            :ets.tab2list(table)
            |> Enum.reduce(acc, fn {pid, mod, started}, acc ->
              case Process.info(pid, :memory) do
                {:memory, heap} ->
                  {t0, peak_total, peak_heap} = Map.get(acc, mod, {started, 0, 0})
                  Map.put(acc, mod, {t0, max(peak_total, total), max(peak_heap, heap)})

                nil ->
                  :ets.delete(table, pid)
                  acc
              end
            end)

          watch.(watch, acc)
      end
    end

    Process.register(self(), :probe_module_watch)
    watch.(watch, %{})
  end)
end
{us, result} = :timer.tc(fn -> :dialyzer.run(check_plt: false, init_plt: plt, files: files, warnings: warnings, timing: timing) end)
send(sampler, {:report, self()})

if Process.whereis(:probe_module_watch) do
  send(:probe_module_watch, {:report, self()})

  receive do
    {:modules, acc} ->
      IO.puts("probe: warning-phase module steps observed: #{map_size(acc)}")

      acc
      |> Enum.sort_by(fn {_mod, {_t0, _total, heap}} -> -heap end)
      |> Enum.take(30)
      |> Enum.each(fn {mod, {_t0, total, heap}} ->
        IO.puts("probe-module #{inspect(mod)} worker_peak=#{div(heap, 1_048_576)} MiB vm_total_peak=#{div(total, 1_048_576)} MiB")
      end)
  after
    10_000 -> IO.puts("probe: module watch did not report")
  end
end

receive do
  {:peak, {total, snap}} ->
    IO.puts("probe: analysis #{div(us, 1_000_000)} s, #{length(result)} warnings")
    IO.puts("probe: peak erlang:memory(total) #{div(total, 1_048_576)} MiB")
    IO.inspect(snap, label: "probe: snapshot at peak", limit: :infinity, printable_limit: 200, width: 160)
end
