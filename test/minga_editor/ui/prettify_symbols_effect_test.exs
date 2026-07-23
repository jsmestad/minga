defmodule MingaEditor.UI.PrettifySymbolsEffectTest do
  @moduledoc "Behavior tests for Buffer-keyed latest-wins prettification."

  use ExUnit.Case, async: true

  alias Minga.Language.Highlight.Span
  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config
  alias Minga.Config.Options
  alias Minga.Core.Decorations
  alias Minga.Test.EffectProbe
  alias MingaEditor.Effect.Policy
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.PrettifySymbols
  alias MingaEditor.UI.PrettifySymbolsEffect

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    options = start_supervised!({Options, name: nil})
    previous_options = Process.put(:minga_config_options, options)

    on_exit(fn ->
      if is_nil(previous_options) do
        Process.delete(:minga_config_options)
      else
        Process.put(:minga_config_options, previous_options)
      end
    end)

    %{options: options}
  end

  test "request uses Buffer identity, latest-wins policy, and immutable parser input" do
    buffer = fake_buffer()

    highlight =
      Highlight.new()
      |> Highlight.put_names(["operator"])
      |> Highlight.put_spans(7, [Span.new(0, 2, 0)])

    request = PrettifySymbolsEffect.request(buffer, highlight, :elixir)

    assert request.resource == {:prettify_symbols, buffer}
    assert request.policy.mode == :latest_wins
    assert request.policy.max_queued == 0
    assert request.effect.highlight == highlight
    assert request.effect.filetype == :elixir
  end

  test "failed, stale, and canceled outcomes do not mutate EditorState" do
    buffer = fake_buffer()
    request = PrettifySymbolsEffect.request(buffer, Highlight.new(), :text)
    state = base_state()

    outcomes = [
      Outcome.failed(request, :buffer_closed),
      Outcome.stale(Outcome.completed(request, :applied), :superseded),
      Outcome.canceled(request, :superseded)
    ]

    Enum.each(outcomes, fn outcome ->
      assert {^state, ^outcome} = PrettifySymbolsEffect.apply(state, outcome)
      refute PrettifySymbolsEffect.render?(outcome)
    end)
  end

  test "worker returns data and outcome application mutates the buffer" do
    state = base_state(content: "->", filetype: :elixir)
    buffer = state.workspace.buffers.active
    request = PrettifySymbolsEffect.request(buffer, operator_highlight(), :elixir)

    assert {:ok, {:replace, [_conceal]}} = PrettifySymbolsEffect.run(request.effect)
    assert conceal_groups(buffer) == []

    outcome = Outcome.completed(request, {:replace, [{{0, 0}, {0, 2}, "→"}]})
    assert {^state, ^outcome} = PrettifySymbolsEffect.apply(state, outcome)
    assert conceal_groups(buffer) == [:prettify_symbols]
  end

  test "enable apply then disabled schedule clears only prettify conceals" do
    state = base_state(content: "->", filetype: :elixir)
    buffer = state.workspace.buffers.active
    highlight = operator_highlight()

    Config.set(:prettify_symbols, true)

    :ok = apply_prettify(buffer, highlight)

    assert conceal_groups(buffer) == [:prettify_symbols]

    Config.set(:prettify_symbols, false)
    assert ^state = PrettifySymbolsEffect.schedule(state, buffer)
    assert conceal_groups(buffer) == []
  end

  test "disabled cleanup cancels admitted work before clearing conceals" do
    task_supervisor = start_supervised!({Task.Supervisor, name: nil})

    scheduler =
      start_supervised!({EffectScheduler, task_supervisor: task_supervisor, owner: self()})

    :ok = EffectScheduler.attach(scheduler, self())
    state = base_state(content: "->", filetype: :elixir, effect_scheduler: scheduler)
    buffer = state.workspace.buffers.active

    Config.set(:prettify_symbols, true)

    :ok = apply_prettify(buffer, operator_highlight())

    request =
      EffectProbe.request(
        self(),
        :stale_prettify,
        {:prettify_symbols, buffer},
        Policy.latest_wins()
      )

    assert {:ok, _request_id, :running} = EffectScheduler.schedule(scheduler, request)
    assert_receive {:effect_started, :stale_prettify, _worker, _payloads}

    Config.set(:prettify_symbols, false)

    assert ^state = PrettifySymbolsEffect.schedule(state, buffer)
    refute EffectScheduler.active?(scheduler, EffectProbe)
    assert conceal_groups(buffer) == []
  end

  test "repeated disabled cleanup is idempotent and preserves other conceals and version" do
    state = base_state(content: "other", filetype: :elixir)
    buffer = state.workspace.buffers.active

    :ok =
      Buffer.batch_decorations(buffer, fn decs ->
        {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 1}, group: :other)
        decs
      end)

    Config.set(:prettify_symbols, false)
    version = Buffer.decorations_version(buffer)

    assert ^state = PrettifySymbolsEffect.schedule(state, buffer)
    assert ^state = PrettifySymbolsEffect.schedule(state, buffer)
    assert Buffer.decorations_version(buffer) == version
    assert conceal_groups(buffer) == [:other]
  end

  test "disabled cleanup ignores stale buffer exits and returns state" do
    state = base_state()
    {:ok, buffer} = BufferProcess.start_link(content: "->", filetype: :elixir)
    :ok = GenServer.stop(buffer)

    Config.set(:prettify_symbols, false)

    assert ^state = PrettifySymbolsEffect.schedule(state, buffer)
  end

  test "unexpected buffer exits propagate from worker and claimed application" do
    worker_buffer = crashing_buffer(:unexpected_worker_exit)

    effect = %PrettifySymbolsEffect{
      buffer: worker_buffer,
      highlight: operator_highlight(),
      filetype: :elixir
    }

    assert {:unexpected_worker_exit, {GenServer, :call, [^worker_buffer | _args]}} =
             catch_exit(PrettifySymbolsEffect.run(effect))

    apply_buffer = crashing_buffer(:unexpected_apply_exit)
    request = PrettifySymbolsEffect.request(apply_buffer, operator_highlight(), :elixir)
    outcome = Outcome.completed(request, :clear)

    assert {:unexpected_apply_exit, {GenServer, :call, [^apply_buffer | _args]}} =
             catch_exit(PrettifySymbolsEffect.apply(base_state(), outcome))
  end

  defp apply_prettify(buffer, highlight),
    do: PrettifySymbols.apply_update(buffer, PrettifySymbols.prepare(buffer, highlight, :elixir))

  defp operator_highlight do
    Highlight.new()
    |> Highlight.put_names(["operator"])
    |> Highlight.put_spans(1, [Span.new(0, 2, 0)])
  end

  defp conceal_groups(buffer) do
    buffer
    |> Buffer.decorations()
    |> Map.fetch!(:conceal_ranges)
    |> Enum.map(& &1.group)
    |> Enum.sort()
  end

  defp fake_buffer do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  defp crashing_buffer(reason) do
    spawn(fn ->
      receive do
        {:"$gen_call", _from, _request} -> exit(reason)
      end
    end)
  end
end
