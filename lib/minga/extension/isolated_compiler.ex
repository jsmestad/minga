defmodule Minga.Extension.IsolatedCompiler do
  @moduledoc """
  Compiles extension source in a disposable BEAM OS process.

  Source executes in a standalone OS BEAM whose standard streams are a bounded
  byte-only Port. The child writes a bounded UTF-8 JSON report which the host
  reads through a verified regular-file descriptor. No source-created term or
  atom crosses an ETF-capable control connection.
  """

  alias Minga.Extension.DisposableBeam
  alias Minga.Extension.IsolatedCompilerTracer
  alias Minga.Extension.SecureFile

  @default_timeout 60_000
  @spawn_flush_timeout 5_000
  @max_report_bytes 128 * 1024
  @max_reports 128
  @max_module_name_bytes 255
  @max_diagnostic_field_bytes 4 * 1024
  @max_diagnostic_bytes 64 * 1024

  @typedoc "Complete isolated compiler report using string module identities."
  @type report :: %{expected_modules: [String.t()], diagnostics: [map()]}

  @doc "Compiles source files to a fresh staging directory in a standalone OS BEAM."
  @spec compile([String.t()], String.t(), keyword()) ::
          {:ok, report()} | {:error, String.t()}
  def compile(files, directory, opts \\ []) when is_list(files) and is_binary(directory) do
    timeout =
      Keyword.get(opts, :subprocess_timeout, Keyword.get(opts, :peer_timeout, @default_timeout))

    report_path = Path.join(directory, ".compiler-report-#{unique_suffix()}.json")

    request = %{"files" => files, "directory" => directory, "report_path" => report_path}

    result =
      case DisposableBeam.run(:compiler, request, directory, timeout) do
        :ok -> read_report(report_path)
        {:error, :output_limit_exceeded} -> {:error, "isolated compiler output exceeded limit"}
        {:error, :timeout} -> {:error, "isolated compiler timed out"}
        {:error, _reason} -> {:error, "isolated compiler process failed"}
      end

    File.rm(report_path)
    result
  end

  @doc false
  @spec run_disposable(map()) :: :ok
  def run_disposable(%{
        "files" => files,
        "directory" => directory,
        "report_path" => report_path
      })
      when is_list(files) and is_binary(directory) and is_binary(report_path) do
    if Enum.all?(files, &is_binary/1) do
      compile_worker(files, directory, report_path)
    else
      :ok
    end
  end

  def run_disposable(_request), do: :ok

  @spec compile_worker([String.t()], String.t(), String.t()) :: :ok
  defp compile_worker(files, directory, report_path) do
    report =
      try do
        do_compile_in_disposable(files, directory)
      rescue
        error -> {:error, bounded_text(Exception.message(error), @max_diagnostic_field_bytes)}
      catch
        _kind, _reason -> {:error, "extension compilation failed"}
      end

    write_report(report_path, report)
  end

  @spec do_compile_in_disposable([String.t()], String.t()) ::
          {:ok, report()} | {:error, String.t()}
  defp do_compile_in_disposable(files, directory) do
    {:ok, _applications} = Application.ensure_all_started(:elixir)
    File.mkdir_p!(directory)
    compiler_output = directory <> ".compiler-output-#{unique_suffix()}"
    File.mkdir_p!(compiler_output)
    config_key = IsolatedCompilerTracer.config_key()
    compile_owner = self()

    tracker =
      spawn(fn ->
        process_tracker_loop(%{}, MapSet.new([compile_owner]), %{}, directory, [])
      end)

    :persistent_term.put(config_key, %{tracker: tracker})

    previous_conflict = Code.get_compiler_option(:ignore_module_conflict)
    previous_infer = Code.get_compiler_option(:infer_signatures)
    previous_relative_paths = Code.get_compiler_option(:relative_paths)
    previous_tracers = Code.get_compiler_option(:tracers)

    Code.put_compiler_option(:ignore_module_conflict, true)
    Code.put_compiler_option(:infer_signatures, false)
    Code.put_compiler_option(:relative_paths, true)
    Code.put_compiler_option(:tracers, [IsolatedCompilerTracer | previous_tracers])
    :erlang.trace_pattern({:code, :load_binary, 3}, true, [])
    :erlang.trace_pattern({Module, :create, 3}, [{:_, [], [{:return_trace}]}], [])
    trace_flags = [:call, :procs, :set_on_spawn, {:tracer, tracker}]
    :erlang.trace(:all, true, trace_flags)
    :erlang.trace(:new_processes, true, trace_flags)

    try do
      {outcome, diagnostics} =
        Code.with_diagnostics(fn ->
          Kernel.ParallelCompiler.compile_to_path(files, compiler_output,
            return_diagnostics: true
          )
        end)

      finish_compile(outcome, diagnostics, tracker, directory, compiler_output)
    after
      :erlang.trace(:new_processes, false, [:all])
      :erlang.trace(:all, false, [:all])
      :erlang.trace_pattern({:code, :load_binary, 3}, false, [])
      :erlang.trace_pattern({Module, :create, 3}, false, [])
      send(tracker, :stop)
      Code.put_compiler_option(:ignore_module_conflict, previous_conflict)
      Code.put_compiler_option(:infer_signatures, previous_infer)
      Code.put_compiler_option(:relative_paths, previous_relative_paths)
      Code.put_compiler_option(:tracers, previous_tracers)
      :persistent_term.erase(config_key)
      File.rm_rf(compiler_output)
    end
  end

  @spec finish_compile(term(), [map()], pid(), String.t(), String.t()) ::
          {:ok, report()} | {:error, String.t()}
  defp finish_compile(
         {:ok, compiled_modules, _compiler_diagnostics},
         diagnostics,
         tracker,
         directory,
         compiler_output
       ) do
    deadline = System.monotonic_time(:millisecond) + @spawn_flush_timeout

    with :ok <- reject_duplicate_compiler_modules(compiled_modules),
         :ok <- copy_compiler_artifacts(compiler_output, directory),
         :ok <- await_quiescent_census(tracker, deadline, 0),
         {:ok, modules} <- artifact_names(directory) do
      {:ok, %{expected_modules: modules, diagnostics: sanitize_diagnostics(diagnostics)}}
    else
      {:error, :spawned_processes_active} ->
        {:error, "isolated compiler spawned processes did not finish"}

      {:error, _reason} ->
        {:error, "isolated compiler artifact inventory failed"}
    end
  end

  defp finish_compile(
         {:error, _errors, _compiler_diagnostics},
         _diagnostics,
         _tracker,
         _directory,
         _compiler_output
       ),
       do: {:error, "extension compilation failed (see *Messages*)"}

  defp finish_compile(_other, _diagnostics, _tracker, _directory, _compiler_output),
    do: {:error, "isolated compiler returned an invalid compile outcome"}

  @spec process_tracker_loop(
          %{optional(pid()) => true},
          MapSet.t(pid()),
          map(),
          String.t(),
          [String.t()]
        ) :: no_return()
  defp process_tracker_loop(active, tracked, barriers, directory, errors) do
    receive do
      {:compiler_emission, owner, ref, module, bytecode}
      when is_pid(owner) and is_reference(ref) and is_atom(module) and is_binary(bytecode) ->
        next_errors = write_runtime_emission(directory, module, bytecode, errors)
        result = if next_errors == errors, do: :ok, else: {:error, hd(next_errors)}
        send(owner, {:compiler_emission_result, ref, result})
        process_tracker_loop(active, tracked, barriers, directory, next_errors)

      {:trace, _pid, :call, {:code, :load_binary, [module, _filename, bytecode]}}
      when is_atom(module) and is_binary(bytecode) ->
        next_errors = observe_loaded_artifact(directory, module, bytecode, errors)
        process_tracker_loop(active, tracked, barriers, directory, next_errors)

      {:trace, _pid, :return_from, {Module, :create, 3}, {:module, module, bytecode, _result}}
      when is_atom(module) and is_binary(bytecode) ->
        next_errors = write_runtime_emission(directory, module, bytecode, errors)
        process_tracker_loop(active, tracked, barriers, directory, next_errors)

      {:trace, parent, :spawn, pid, _mfa} when is_pid(pid) ->
        if MapSet.member?(tracked, parent) do
          process_tracker_loop(
            Map.put(active, pid, true),
            MapSet.put(tracked, pid),
            barriers,
            directory,
            errors
          )
        else
          process_tracker_loop(active, tracked, barriers, directory, errors)
        end

      {:trace, pid, :exit, _reason} when is_pid(pid) ->
        process_tracker_loop(Map.delete(active, pid), tracked, barriers, directory, errors)

      {:barrier, owner, request_ref} when is_pid(owner) and is_reference(request_ref) ->
        delivered_ref = :erlang.trace_delivered(:all)

        process_tracker_loop(
          active,
          tracked,
          Map.put(barriers, delivered_ref, {owner, request_ref}),
          directory,
          errors
        )

      {:trace_delivered, :all, delivered_ref} ->
        case Map.pop(barriers, delivered_ref) do
          {{owner, request_ref}, remaining} ->
            alive = Enum.count(active, fn {pid, true} -> Process.alive?(pid) end)
            send(owner, {:tracker_barrier, request_ref, alive, errors})
            filtered = Map.filter(active, fn {pid, true} -> Process.alive?(pid) end)
            process_tracker_loop(filtered, tracked, remaining, directory, errors)

          {nil, _remaining} ->
            process_tracker_loop(active, tracked, barriers, directory, errors)
        end

      :stop ->
        exit(:normal)

      _message ->
        process_tracker_loop(active, tracked, barriers, directory, errors)
    end
  end

  @spec observe_loaded_artifact(String.t(), module(), binary(), [String.t()]) :: [String.t()]
  defp observe_loaded_artifact(directory, module, bytecode, errors) do
    module_name = Atom.to_string(module)

    if Regex.match?(~r/^elixir_compiler_\d+$/, module_name) do
      errors
    else
      if valid_artifact_name?(module_name),
        do: observe_named_loaded_artifact(directory, module_name, bytecode, errors),
        else: ["invalid runtime artifact name" | errors]
    end
  end

  @spec observe_named_loaded_artifact(String.t(), String.t(), binary(), [String.t()]) :: [
          String.t()
        ]
  defp observe_named_loaded_artifact(directory, module_name, bytecode, errors) do
    path = Path.join(directory, module_name <> ".beam")

    case File.read(path) do
      {:ok, ^bytecode} ->
        errors

      {:ok, _different} ->
        ["duplicate compiler output" | errors]

      {:error, :enoent} ->
        case File.write(path, bytecode, [:binary, :exclusive]) do
          :ok -> errors
          {:error, _reason} -> ["runtime artifact write failed" | errors]
        end

      {:error, _reason} ->
        ["runtime artifact read failed" | errors]
    end
  end

  @spec write_runtime_emission(String.t(), module(), binary(), [String.t()]) :: [String.t()]
  defp write_runtime_emission(directory, module, bytecode, errors) do
    module_name = Atom.to_string(module)

    if valid_artifact_name?(module_name) do
      path = Path.join(directory, module_name <> ".beam")

      case File.write(path, bytecode, [:binary, :exclusive]) do
        :ok -> errors
        {:error, :eexist} -> ["duplicate compiler output" | errors]
        {:error, _reason} -> ["runtime artifact write failed" | errors]
      end
    else
      ["invalid runtime artifact name" | errors]
    end
  end

  @spec valid_artifact_name?(String.t()) :: boolean()
  defp valid_artifact_name?(name) do
    name != "" and String.valid?(name) and byte_size(name) <= @max_module_name_bytes and
      Path.basename(name) == name and not String.contains?(name, ["/", "\\", <<0>>])
  end

  @spec await_quiescent_census(pid(), integer(), 0 | 1) ::
          :ok | {:error, :spawned_processes_active}
  defp await_quiescent_census(tracker, deadline, consecutive_empty) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :spawned_processes_active}
    else
      ref = make_ref()
      send(tracker, {:barrier, self(), ref})

      receive do
        {:tracker_barrier, ^ref, _active, [_error | _rest]} ->
          {:error, :spawned_processes_active}

        {:tracker_barrier, ^ref, 0, []} when consecutive_empty == 1 ->
          :ok

        {:tracker_barrier, ^ref, 0, []} ->
          await_quiescent_census(tracker, deadline, 1)

        {:tracker_barrier, ^ref, _active, []} ->
          await_quiescent_census(tracker, deadline, 0)
      after
        remaining -> {:error, :spawned_processes_active}
      end
    end
  end

  @spec reject_duplicate_compiler_modules([module()]) :: :ok | {:error, term()}
  defp reject_duplicate_compiler_modules(modules) do
    case modules |> Enum.frequencies() |> Enum.find(fn {_module, count} -> count > 1 end) do
      nil -> :ok
      {_module, _count} -> {:error, :duplicate_compiler_output}
    end
  end

  @spec copy_compiler_artifacts(String.t(), String.t()) :: :ok | {:error, term()}
  defp copy_compiler_artifacts(compiler_output, directory) do
    compiler_output
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.reduce_while(:ok, fn source, :ok ->
      destination = Path.join(directory, Path.basename(source))
      copy_compiler_artifact(source, destination)
    end)
  end

  @spec copy_compiler_artifact(String.t(), String.t()) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp copy_compiler_artifact(source, destination) do
    source
    |> File.read()
    |> copy_compiler_artifact_result(File.read(destination), destination)
  end

  @spec copy_compiler_artifact_result(
          {:ok, binary()} | {:error, File.posix()},
          {:ok, binary()} | {:error, File.posix()},
          String.t()
        ) :: {:cont, :ok} | {:halt, {:error, term()}}
  defp copy_compiler_artifact_result({:ok, binary}, {:error, :enoent}, destination) do
    case File.write(destination, binary, [:binary, :exclusive]) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp copy_compiler_artifact_result({:ok, binary}, {:ok, binary}, _destination),
    do: {:cont, :ok}

  defp copy_compiler_artifact_result({:ok, _binary}, {:ok, _different}, _destination),
    do: {:halt, {:error, :duplicate_compiler_output}}

  defp copy_compiler_artifact_result({:error, reason}, _destination_result, _destination),
    do: {:halt, {:error, reason}}

  defp copy_compiler_artifact_result(_source_result, {:error, reason}, _destination),
    do: {:halt, {:error, reason}}

  @spec artifact_names(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defp artifact_names(directory) do
    case File.ls(directory) do
      {:ok, entries} ->
        modules =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".beam"))
          |> Enum.map(&String.trim_trailing(&1, ".beam"))
          |> Enum.filter(&(String.valid?(&1) and byte_size(&1) <= @max_module_name_bytes))
          |> Enum.sort()

        if length(modules) <= @max_reports, do: {:ok, modules}, else: {:error, :too_many_modules}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec sanitize_diagnostics([map()]) :: [map()]
  defp sanitize_diagnostics(diagnostics) do
    diagnostics
    |> Enum.take(@max_reports)
    |> Enum.reduce_while({[], 0}, fn diagnostic, {acc, total} ->
      sanitized = sanitize_diagnostic(diagnostic)
      encoded_bytes = byte_size(JSON.encode!(sanitized))

      if total + encoded_bytes <= @max_diagnostic_bytes,
        do: {:cont, {[sanitized | acc], total + encoded_bytes}},
        else: {:halt, {acc, total}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec sanitize_diagnostic(term()) :: map()
  defp sanitize_diagnostic(diagnostic) when is_map(diagnostic) do
    %{
      "file" => bounded_text(Map.get(diagnostic, :file, "unknown"), @max_diagnostic_field_bytes),
      "line" => bounded_integer(position_part(Map.get(diagnostic, :position), 0)),
      "column" => bounded_integer(position_part(Map.get(diagnostic, :position), 1)),
      "severity" => severity(Map.get(diagnostic, :severity)),
      "message" =>
        bounded_text(
          Map.get(diagnostic, :message, "compiler diagnostic"),
          @max_diagnostic_field_bytes
        )
    }
  end

  defp sanitize_diagnostic(_diagnostic) do
    %{
      "file" => "unknown",
      "line" => 0,
      "column" => 0,
      "severity" => "warning",
      "message" => "compiler diagnostic"
    }
  end

  @spec position_part(term(), non_neg_integer()) :: non_neg_integer()
  defp position_part({line, _column}, 0) when is_integer(line) and line >= 0, do: line
  defp position_part({_line, column}, 1) when is_integer(column) and column >= 0, do: column
  defp position_part(line, 0) when is_integer(line) and line >= 0, do: line
  defp position_part(_position, _index), do: 0

  @spec bounded_integer(term()) :: non_neg_integer()
  defp bounded_integer(value) when is_integer(value) and value >= 0, do: min(value, 1_000_000_000)
  defp bounded_integer(_value), do: 0

  @spec severity(term()) :: String.t()
  defp severity(:error), do: "error"
  defp severity(:warning), do: "warning"
  defp severity(_other), do: "info"

  @spec bounded_text(term(), pos_integer()) :: String.t()
  defp bounded_text(value, max) when is_binary(value) do
    value
    |> String.slice(0, max)
    |> ensure_utf8()
  end

  defp bounded_text(value, max) do
    value
    |> inspect(limit: 20, printable_limit: max, width: 80)
    |> bounded_text(max)
  end

  @spec ensure_utf8(binary()) :: String.t()
  defp ensure_utf8(value) do
    if String.valid?(value), do: value, else: "invalid utf8"
  end

  @spec write_report(String.t(), {:ok, report()} | {:error, String.t()}) :: :ok
  defp write_report(path, {:ok, report}) do
    payload = %{
      "status" => "ok",
      "modules" => report.expected_modules,
      "diagnostics" => report.diagnostics
    }

    write_bounded_report(path, payload)
  end

  defp write_report(path, {:error, message}) do
    write_bounded_report(path, %{
      "status" => "error",
      "message" => bounded_text(message, @max_diagnostic_field_bytes)
    })
  end

  @spec write_bounded_report(String.t(), map()) :: :ok
  defp write_bounded_report(path, payload) do
    binary = JSON.encode!(payload)

    final =
      if byte_size(binary) <= @max_report_bytes,
        do: binary,
        else: JSON.encode!(%{"status" => "error", "message" => "compiler report exceeded limit"})

    temporary = path <> ".worker-tmp"

    with :ok <- File.write(temporary, final, [:binary, :exclusive]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, _reason} ->
        File.rm(temporary)
        :ok
    end
  end

  @spec read_report(String.t()) :: {:ok, report()} | {:error, String.t()}
  defp read_report(path) do
    case SecureFile.read(path, @max_report_bytes) do
      {:ok, binary} -> decode_report(binary)
      {:error, _reason} -> {:error, "isolated compiler report was unsafe"}
    end
  end

  @spec decode_report(binary()) :: {:ok, report()} | {:error, String.t()}
  defp decode_report(binary) do
    case JSON.decode(binary) do
      {:ok, %{"status" => "ok", "modules" => modules, "diagnostics" => diagnostics}}
      when is_list(modules) and is_list(diagnostics) ->
        decode_success_report(modules, diagnostics)

      {:ok, %{"status" => "error", "message" => message}} when is_binary(message) ->
        {:error, bounded_text(message, @max_diagnostic_field_bytes)}

      _other ->
        {:error, "isolated compiler returned an invalid report"}
    end
  end

  @spec decode_success_report([term()], [term()]) :: {:ok, report()} | {:error, String.t()}
  defp decode_success_report(modules, diagnostics) do
    valid_modules? =
      length(modules) <= @max_reports and length(Enum.uniq(modules)) == length(modules) and
        Enum.all?(
          modules,
          &(is_binary(&1) and String.valid?(&1) and byte_size(&1) <= @max_module_name_bytes)
        )

    valid_diagnostics? =
      length(diagnostics) <= @max_reports and Enum.all?(diagnostics, &valid_diagnostic?/1)

    if valid_modules? and valid_diagnostics? do
      normalized = Enum.map(diagnostics, &normalize_diagnostic/1)
      {:ok, %{expected_modules: Enum.sort(modules), diagnostics: normalized}}
    else
      {:error, "isolated compiler returned an invalid report"}
    end
  end

  @spec valid_diagnostic?(term()) :: boolean()
  defp valid_diagnostic?(%{
         "file" => file,
         "line" => line,
         "column" => column,
         "severity" => severity,
         "message" => message
       }) do
    is_binary(file) and byte_size(file) <= @max_diagnostic_field_bytes and is_integer(line) and
      is_integer(column) and severity in ["error", "warning", "info"] and is_binary(message) and
      byte_size(message) <= @max_diagnostic_field_bytes
  end

  defp valid_diagnostic?(_diagnostic), do: false

  @spec normalize_diagnostic(map()) :: map()
  defp normalize_diagnostic(diagnostic) do
    %{
      file: diagnostic["file"],
      position: {diagnostic["line"], diagnostic["column"]},
      severity: String.to_existing_atom(diagnostic["severity"]),
      message: diagnostic["message"]
    }
  end

  @spec unique_suffix() :: String.t()
  defp unique_suffix do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
