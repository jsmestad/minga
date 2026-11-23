defmodule MingaEditor.LaunchWarmup do
  @moduledoc """
  Loads the editor's code in the background once the first frame is dispatched.

  The release boots in interactive mode (`rel/env.sh.eex`) so launch does not load every module before the first frame. The cost moves to the first use of a feature instead: the first Agent open loaded, and JIT-compiled, a few dozen modules inside the Editor process. This warm-up loads the `:minga` application's remaining modules in a low-priority task, in small batches so a module the Editor needs meanwhile never waits long behind it.

  Disabled with `config :minga, launch_code_warmup: false`, and a no-op in embedded mode, where every module is already loaded.
  """

  @batch_size 16

  @doc "Starts the background warm-up and returns at once."
  @spec start() :: :ok
  def start do
    if Application.get_env(:minga, :launch_code_warmup, true) and :code.get_mode() == :interactive,
      do: start_task()

    :ok
  end

  @spec start_task() :: :ok
  defp start_task do
    _started = Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, &warm/0)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @spec warm() :: :ok
  defp warm do
    Process.flag(:priority, :low)

    Minga.Telemetry.span([:minga, :editor, :code_warmup], %{}, fn ->
      case :application.get_key(:minga, :modules) do
        {:ok, modules} -> load_missing(modules)
        :undefined -> :ok
      end
    end)
  end

  @spec load_missing([module()]) :: :ok
  defp load_missing(modules) do
    modules
    |> Enum.reject(&:erlang.module_loaded/1)
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(&:code.ensure_modules_loaded/1)
  end
end
