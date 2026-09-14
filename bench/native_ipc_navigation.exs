Code.require_file("../test/support/render_pipeline_test_helpers.ex", __DIR__)

alias MingaEditor.NativeIPC.Identity
alias MingaEditor.NativeIPC.Navigation
alias MingaEditor.NativeIPC.NavigationCommand
alias MingaEditor.RenderPipeline.TestHelpers
alias MingaEditor.Session.State, as: SessionState
alias MingaEditor.Shell.Runtime
alias MingaEditor.Shell.Traditional.State, as: TraditionalState
alias MingaEditor.State.Tab
alias MingaEditor.State.Tab.Context
alias MingaEditor.State.TabBar
alias MingaEditor.State.Windows
alias MingaEditor.Window

defmodule Minga.Bench.NativeIPCNavigation do
  @moduledoc false

  @warmup_iterations 20
  @sample_iterations 200
  @p99_limit_us 20_000
  @maximum_frame_bytes 65_536

  @spec run() :: :ok
  def run do
    identity =
      Identity.new(
        app_instance_id: "benchmark-app",
        core_instance_id: "benchmark-core",
        app_pid: System.pid() |> String.to_integer(),
        euid: File.stat!(File.cwd!()).uid,
        launch_nonce: nil,
        socket_path: "/tmp/minga-native-ipc-benchmark.sock",
        token: "benchmark-secret"
      )

    results =
      for {document, line_count} <- [small: 40, large: 100_000],
          pane_count <- [1, 4] do
        content = TestHelpers.long_content(line_count)
        state = build_state(content, pane_count)
        result = measure_scenario(state, identity, document, pane_count)
        stop_buffers(state)
        result
      end

    payload = %{
      "mix_env" => Atom.to_string(Mix.env()),
      "p99_limit_us" => @p99_limit_us,
      "maximum_frame_bytes" => @maximum_frame_bytes,
      "results" => results
    }

    IO.puts(JSON.encode!(payload))
    validate!(results)
  end

  @spec build_state(String.t(), pos_integer()) :: MingaEditor.State.t()
  defp build_state(content, pane_count) do
    state = TestHelpers.base_state(content: content)
    buffer = state.workspace.buffers.active

    windows =
      1..pane_count
      |> Map.new(fn id -> {id, Window.new(id, buffer, 24, 80)} end)
      |> then(&Windows.new(nil, 1, pane_count + 1, &1))

    workspace = SessionState.set_windows(state.workspace, windows)
    state = %{state | workspace: workspace}
    tab = Tab.new_file(1, "benchmark.ex")
    tab_bar = TabBar.new(tab) |> TabBar.update_context(1, Context.snapshot(workspace))
    shell_state = TraditionalState.install_tab_bar(Runtime.state(state.shell_runtime), tab_bar)
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end

  @spec measure_scenario(MingaEditor.State.t(), Identity.t(), atom(), pos_integer()) :: map()
  defp measure_scenario(state, identity, document, pane_count) do
    {:ok, inspection} = Navigation.inspect(state, identity, nil, 25)
    command = focus_command(inspection, identity)

    Enum.each(1..@warmup_iterations, fn _iteration ->
      {:ok, _inspection} = Navigation.inspect(state, identity, nil, 25)
      {:ok, _state, :editor_visible_focused} = Navigation.apply(state, identity, command)
    end)

    inspect_samples = samples(fn -> Navigation.inspect(state, identity, nil, 25) end)
    dispatch_samples = samples(fn -> Navigation.apply(state, identity, command) end)
    encoded = JSON.encode!(inspection)

    %{
      "document" => Atom.to_string(document),
      "panes" => pane_count,
      "response_bytes" => byte_size(encoded),
      "inspect_us" => percentiles(inspect_samples),
      "dispatch_us" => percentiles(dispatch_samples)
    }
  end

  @spec focus_command(map(), Identity.t()) :: NavigationCommand.t()
  defp focus_command(inspection, identity) do
    [tab] = inspection["authoritative"]["tabs"]
    [pane | _rest] = tab["panes"]

    {:ok, command} =
      NavigationCommand.parse(%{
        "type" => "focus_pane",
        "app_instance_id" => identity.app_instance_id,
        "core_instance_id" => identity.core_instance_id,
        "tab_id" => tab["id"],
        "pane_id" => pane["id"],
        "target_token" => pane["target_token"]
      })

    command
  end

  @spec samples((-> term())) :: [non_neg_integer()]
  defp samples(operation) do
    for _iteration <- 1..@sample_iterations do
      {elapsed, _result} = :timer.tc(operation)
      elapsed
    end
  end

  @spec percentiles([non_neg_integer()]) :: map()
  defp percentiles(samples) do
    sorted = Enum.sort(samples)

    %{
      "p50" => percentile(sorted, 50),
      "p95" => percentile(sorted, 95),
      "p99" => percentile(sorted, 99),
      "max" => List.last(sorted)
    }
  end

  @spec percentile([non_neg_integer()], pos_integer()) :: non_neg_integer()
  defp percentile(samples, percentile) do
    index = ceil(length(samples) * percentile / 100) - 1
    Enum.at(samples, max(index, 0))
  end

  @spec validate!([map()]) :: :ok
  defp validate!(results) do
    Enum.each(results, fn result ->
      if result["response_bytes"] > @maximum_frame_bytes do
        raise "#{label(result)} response exceeded #{@maximum_frame_bytes} bytes"
      end

      for operation <- ["inspect_us", "dispatch_us"] do
        if result[operation]["p99"] > @p99_limit_us do
          raise "#{label(result)} #{operation} p99 exceeded #{@p99_limit_us} us"
        end
      end
    end)

    :ok
  end

  @spec label(map()) :: String.t()
  defp label(result), do: "#{result["document"]}/#{result["panes"]}-pane"

  @spec stop_buffers(MingaEditor.State.t()) :: :ok
  defp stop_buffers(state) do
    Enum.each(state.workspace.buffers.list, &GenServer.stop/1)
  end
end

Minga.Bench.NativeIPCNavigation.run()
