defmodule Minga.Test.LLMFormatter do
  @moduledoc """
  ExUnit formatter optimized for LLM agent consumption.

  Design principles:
  - One line per passing module (not per test, not dots)
  - Verbose failure output with copy-pasteable `mix test file:line` commands
  - No ANSI colors (LLMs can't see them)
  - Structured summary with all failure locations grouped at the end

  Usage:
      mix test --formatter Minga.Test.LLMFormatter
      mix test --formatter Minga.Test.LLMFormatter --max-failures 3
  """
  use GenServer

  import ExUnit.Formatter,
    only: [format_times: 1, format_test_failure: 5]

  ## Callbacks

  @spec init(keyword()) :: {:ok, map()}
  def init(opts) do
    IO.puts("ExUnit seed: #{opts[:seed]}, max_cases: #{opts[:max_cases]}\n")

    config = %{
      width: 120,
      module_results: %{},
      failures: [],
      failure_counter: 0,
      skipped_counter: 0,
      excluded_counter: 0,
      invalid_counter: 0,
      test_counter: %{}
    }

    {:ok, config}
  end

  def handle_cast({:suite_started, _opts}, config) do
    {:noreply, config}
  end

  def handle_cast({:suite_finished, times_us}, config) do
    IO.write("\n")

    # Print module summary
    config.module_results
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.each(fn {_name, %{passed: passed, failed: failed, time_us: time_us, file: file}} ->
      status = if failed == 0, do: "PASS", else: "FAIL"
      ms = format_ms(time_us)
      IO.puts("  #{status} #{file} (#{passed + failed} tests, #{ms})")
    end)

    IO.write("\n")
    IO.puts(format_times(times_us))

    # Reprint all failure locations grouped together for easy copy-paste
    if config.failure_counter > 0 do
      IO.puts("\nFailed test locations (copy-paste to re-run):\n")

      Enum.each(config.failures, fn {file, line, name} ->
        IO.puts("  mix test #{file}:#{line}  # #{name}")
      end)

      IO.write("\n")
    end

    print_summary(config)
    {:noreply, config}
  end

  def handle_cast({:test_started, _test}, config) do
    {:noreply, config}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: nil} = test}, config) do
    config = update_module_result(config, test, :passed)
    config = update_test_counter(config, test)
    {:noreply, config}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:excluded, _}}}, config) do
    {:noreply, %{config | excluded_counter: config.excluded_counter + 1}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:skipped, _}} = test}, config) do
    config = update_test_counter(config, test)
    {:noreply, %{config | skipped_counter: config.skipped_counter + 1}}
  end

  def handle_cast(
        {:test_finished,
         %ExUnit.Test{state: {:invalid, %ExUnit.TestModule{state: {:failed, _}}}} = test},
        config
      ) do
    config = update_test_counter(config, test)
    {:noreply, %{config | invalid_counter: config.invalid_counter + 1}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, failures}} = test}, config) do
    # Print failure immediately (same as default formatter)
    formatted =
      format_test_failure(
        test,
        failures,
        config.failure_counter + 1,
        config.width,
        &plain_formatter/2
      )

    IO.puts("\n#{formatted}")
    print_logs(test.logs)

    file = Path.relative_to_cwd(test.tags.file)
    line = test.tags.line
    name = to_string(test.name)

    config = update_module_result(config, test, :failed)
    config = update_test_counter(config, test)

    config = %{
      config
      | failure_counter: config.failure_counter + 1,
        failures: config.failures ++ [{file, line, name}]
    }

    {:noreply, config}
  end

  def handle_cast({:module_started, _module}, config) do
    {:noreply, config}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{state: nil}}, config) do
    {:noreply, config}
  end

  def handle_cast(
        {:module_finished, %ExUnit.TestModule{state: {:failed, failures}} = test_module},
        config
      ) do
    formatted =
      ExUnit.Formatter.format_test_all_failure(
        test_module,
        failures,
        config.failure_counter + 1,
        config.width,
        &plain_formatter/2
      )

    IO.puts("\n#{formatted}")

    failed_count = Enum.count(test_module.tests, &is_nil(&1.state))

    {:noreply, %{config | failure_counter: config.failure_counter + failed_count}}
  end

  def handle_cast(:max_failures_reached, config) do
    IO.puts("\n--max-failures reached, aborting test suite")
    {:noreply, config}
  end

  def handle_cast({:sigquit, current}, config) do
    IO.write("\n\n")

    if current != [] do
      IO.puts("Aborting, these tests have not completed:\n")
      Enum.each(current, fn test -> IO.puts("  * #{test.name}") end)
    end

    IO.puts("Showing results so far...\n")
    print_summary(config)
    {:noreply, config}
  end

  def handle_cast(_, config) do
    {:noreply, config}
  end

  ## Private

  defp update_module_result(config, %ExUnit.Test{module: module, time: time, tags: tags}, result) do
    file = Path.relative_to_cwd(tags.file)

    update_in(config.module_results, fn results ->
      Map.update(results, module, new_module_result(result, time, file), fn existing ->
        existing
        |> Map.update!(:time_us, &(&1 + time))
        |> increment_result(result)
      end)
    end)
  end

  defp new_module_result(:passed, time, file),
    do: %{passed: 1, failed: 0, time_us: time, file: file}

  defp new_module_result(:failed, time, file),
    do: %{passed: 0, failed: 1, time_us: time, file: file}

  defp increment_result(result, :passed), do: Map.update!(result, :passed, &(&1 + 1))
  defp increment_result(result, :failed), do: Map.update!(result, :failed, &(&1 + 1))

  defp update_test_counter(config, %{tags: %{test_type: test_type}}) do
    update_in(config.test_counter, fn counter ->
      Map.update(counter, test_type, 1, &(&1 + 1))
    end)
  end

  defp format_ms(us) do
    ms = div(us, 1000)

    if ms < 1 do
      "<1ms"
    else
      "#{ms}ms"
    end
  end

  defp print_summary(config) do
    total =
      Enum.reduce(config.test_counter, 0, fn {_, count}, acc -> acc + count end)

    test_counts =
      config.test_counter
      |> Enum.sort()
      |> Enum.map(fn {type, count} ->
        plural = ExUnit.plural_rule(to_string(type))
        label = if count == 1, do: type, else: plural
        "#{count} #{label}"
      end)
      |> Enum.join(", ")

    parts = [
      test_counts,
      "#{config.failure_counter} #{if config.failure_counter == 1, do: "failure", else: "failures"}"
    ]

    parts =
      if config.invalid_counter > 0,
        do: parts ++ ["#{config.invalid_counter} invalid"],
        else: parts

    parts =
      if config.skipped_counter > 0,
        do: parts ++ ["#{config.skipped_counter} skipped"],
        else: parts

    parts =
      if config.excluded_counter > 0,
        do: parts ++ ["#{config.excluded_counter} excluded"],
        else: parts

    status = if config.failure_counter > 0 or total == 0, do: "FAIL", else: "PASS"
    IO.puts("#{status}: #{Enum.join(parts, ", ")}")
  end

  # Plain text formatter (no ANSI colors)
  defp plain_formatter(:diff_enabled?, _), do: false
  defp plain_formatter(_key, msg), do: msg

  defp print_logs(""), do: nil

  defp print_logs(output) do
    indent = "\n     "
    output = String.replace(output, "\n", indent)
    IO.puts(["     The following output was logged:", indent | output])
  end
end
