defmodule MingaAgent.StatusCommandTest do
  # Uses System.cmd through the status command runner; OS process tests stay serialized.
  use ExUnit.Case, async: false

  @moduletag timeout: 5_000

  alias Minga.Config.Options
  alias Minga.Events
  alias MingaAgent.StatusCommand

  setup do
    options = start_supervised!({Options, name: nil})

    task_supervisor =
      Module.concat(__MODULE__, "TaskSupervisor#{System.unique_integer([:positive])}")

    start_supervised!({Task.Supervisor, name: task_supervisor})

    pid =
      start_supervised!(
        {StatusCommand, name: nil, config_server: options, task_supervisor: task_supervisor}
      )

    %{options: options, command: pid}
  end

  test "runs configured command with agent env and caches stdout", ctx do
    dir = File.cwd!()

    Options.set(
      ctx.options,
      :agent_status_command,
      ~s[printf '%s|%s|%s|%s' "$MINGA_SESSION_ID" "$MINGA_MODEL" "$MINGA_STATUS" "$MINGA_WORKDIR"]
    )

    context = %{session_id: "s1", model: "sonnet", status: :thinking, workdir: dir}

    assert StatusCommand.content(context, ctx.command) == nil

    assert wait_until(fn -> StatusCommand.content(context, ctx.command) end) ==
             "s1|sonnet|thinking|#{dir}"
  end

  test "render reads do not rerun before the interval", ctx do
    path =
      Path.join(System.tmp_dir!(), "minga-status-command-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)

    Options.set(
      ctx.options,
      :agent_status_command,
      "n=$(cat #{path} 2>/dev/null || echo 0); n=$((n + 1)); echo $n > #{path}; printf $n"
    )

    context = %{session_id: "s1", model: "sonnet", status: :idle, workdir: File.cwd!()}

    assert wait_until(fn -> StatusCommand.content(context, ctx.command) end) == "1"

    for _ <- 1..5 do
      assert StatusCommand.content(context, ctx.command) == "1"
    end

    assert File.read!(path) == "1\n"
  end

  test "config changes replace the cached value without restart", ctx do
    Options.set(ctx.options, :agent_status_command, "printf first")
    context = %{session_id: "s1", model: "sonnet", status: :idle, workdir: File.cwd!()}

    assert wait_until(fn -> StatusCommand.content(context, ctx.command) end) == "first"

    Options.set(ctx.options, :agent_status_command, "printf second")

    assert wait_until(fn -> StatusCommand.content(context, ctx.command) end) == "second"
  end

  test "failures fall back to nil and log once per command", ctx do
    Events.subscribe(:log_message)
    Options.set(ctx.options, :agent_status_command, "exit 7")
    context = %{session_id: "s1", model: "sonnet", status: :idle, workdir: File.cwd!()}

    assert StatusCommand.content(context, ctx.command) == nil
    assert_receive {:minga_event, :log_message, %{text: text}}, 500
    assert String.contains?(text, "Agent status command failed")

    assert StatusCommand.content(context, ctx.command) == nil
    refute_receive {:minga_event, :log_message, %{text: ^text}}, 100
  end

  @spec wait_until((-> term()), non_neg_integer()) :: term()
  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        receive do
        after
          10 -> wait_until(fun, attempts - 1)
        end

      value ->
        value
    end
  end

  defp wait_until(fun, 0), do: flunk("condition was not met, last result: #{inspect(fun.())}")
end
