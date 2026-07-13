defmodule Minga.Perf.KeystrokeLatencyTest do
  @moduledoc """
  Measures per-hop GenServer scheduling delay on the keystroke render path.

  Background (issue #2174): production keystroke latency (~5.4ms) is ~3.7ms
  higher than headless single-process latency (~1.7ms). The gap was attributed
  to GenServer scheduling jitter across the render hops, but that jitter was
  never measured. This test drives the real async render pipeline
  (Editor → Renderer.Server → Port.Manager → Editor) over a simulated typing
  session and reports p50/p90/max scheduling delay for each hop so the
  optimization decision rests on data, not assumption.

  Excluded by default. Run with:

      mix test --include perf test/perf/keystroke_latency_test.exs

  The three hops measured (`[:minga, :render, :hop_latency]`):

    * `:cast_snapshot`  — Editor → Renderer.Server (`cast_snapshot/3`)
    * `:send_commands`  — Renderer.Server emit → Port.Manager (`send_render_commands/2`)
    * `:render_done`    — Renderer.Server → Editor (`{:render_done, writeback}`)
  """

  # Drives a real Renderer.Server and HeadlessPort; not safe to run concurrently
  # with other tests that touch the shared shell registry.
  use ExUnit.Case, async: false

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.Viewport
  alias Minga.Test.HeadlessPort

  @moduletag :perf

  # Enough keystrokes to produce stable percentiles without making the run slow.
  @iterations 200

  # Minimal stand-in for the Editor process. It runs the exact production
  # hop-3 measurement (Minga.Telemetry.hop_latency/2 via the same code the
  # real Editor uses) so the scheduling delay measured here is the genuine
  # Renderer.Server → Editor message hop.
  defmodule EditorStub do
    @moduledoc false
    use GenServer

    @spec start_link(term()) :: GenServer.on_start()
    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_), do: {:ok, nil}

    @impl true
    def handle_info({:render_done, %{render_sent_at: sent_at}}, state) do
      Minga.Telemetry.hop_latency(:render_done, sent_at)
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  setup do
    MingaEditor.Shell.Registry.reset_for_test()
    MingaEditor.Shell.Registry.seed_builtin()

    on_exit(fn ->
      MingaEditor.Shell.Registry.reset_for_test()
      MingaEditor.Shell.Registry.seed_builtin()
    end)

    :ok
  end

  test "reports per-hop scheduling delay across a typing session" do
    attach_hop_collector()

    editor = start_supervised!(EditorStub)
    renderer = start_supervised!({RendererServer, name: nil, editor_pid: editor})
    {state, port} = build_editor_state(renderer)
    snapshot = Input.from_editor_state(state)

    # Serialize one full frame per iteration (cast → render → emit → writeback)
    # so each keystroke produces one clean sample per hop instead of being
    # coalesced away under burst load.
    for seq <- 1..@iterations do
      frame_ref = HeadlessPort.prepare_await(port)
      RendererServer.cast_snapshot(renderer, snapshot, seq)
      assert {:ok, _screen} = HeadlessPort.collect_frame(frame_ref, 5_000)
    end

    # Let the trailing render_done writebacks land before draining samples.
    Process.sleep(50)
    samples = drain_samples()

    report =
      [:cast_snapshot, :send_commands, :render_done]
      |> Enum.map(fn hop -> {hop, percentiles(Map.get(samples, hop, []))} end)

    print_report(report)

    for {hop, stats} <- report do
      assert stats.count > 0, "expected #{hop} hop samples, got none"
    end
  end

  # ── Telemetry collection ────────────────────────────────────────────────

  defp attach_hop_collector do
    parent = self()
    handler_id = {__MODULE__, :hop_latency, make_ref()}

    handler = fn [:minga, :render, :hop_latency], %{microseconds: us}, %{hop: hop}, pid ->
      send(pid, {:hop_sample, hop, us})
    end

    :ok = :telemetry.attach(handler_id, [:minga, :render, :hop_latency], handler, parent)
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp drain_samples(acc \\ %{}) do
    receive do
      {:hop_sample, hop, us} ->
        drain_samples(Map.update(acc, hop, [us], &[us | &1]))
    after
      0 -> acc
    end
  end

  # ── Percentiles ─────────────────────────────────────────────────────────

  @spec percentiles([integer()]) :: %{
          count: non_neg_integer(),
          p50: integer(),
          p90: integer(),
          max: integer()
        }
  defp percentiles([]), do: %{count: 0, p50: 0, p90: 0, max: 0}

  defp percentiles(samples) do
    sorted = Enum.sort(samples)
    count = Enum.count(sorted)

    %{
      count: count,
      p50: percentile(sorted, count, 0.50),
      p90: percentile(sorted, count, 0.90),
      max: Enum.at(sorted, -1)
    }
  end

  @spec percentile([integer()], pos_integer(), float()) :: integer()
  defp percentile(sorted, count, quantile) do
    index = min(count - 1, trunc(quantile * count))
    Enum.at(sorted, index)
  end

  # ── Reporting ───────────────────────────────────────────────────────────

  defp print_report(report) do
    lines =
      Enum.map(report, fn {hop, s} ->
        "  #{String.pad_trailing(to_string(hop), 16)} " <>
          "n=#{String.pad_leading(to_string(s.count), 4)}  " <>
          "p50=#{pad_us(s.p50)}  p90=#{pad_us(s.p90)}  max=#{pad_us(s.max)}  " <>
          "#{classify(s.p90)}"
      end)

    IO.puts(
      "\n[render hop latency — #{@iterations} keystrokes]\n" <>
        Enum.join(lines, "\n") <>
        "\n  classification uses p90; see issue #2174 acceptance decision tree.\n"
    )
  end

  defp pad_us(us), do: String.pad_leading("#{us}µs", 8)

  # Maps a hop's p90 scheduling delay onto the ticket's decision thresholds.
  defp classify(p90) when p90 >= 500, do: "HOT (>500µs: candidate for targeted optimization)"
  defp classify(p90) when p90 >= 100, do: "WARM (>100µs: notable scheduling delay)"
  defp classify(_p90), do: "OK (<100µs: jitter is not the bottleneck)"

  # ── Harness ─────────────────────────────────────────────────────────────

  defp build_editor_state(renderer_pid) do
    buf = start_supervised!({Minga.Buffer, content: "the quick brown fox"})
    port = start_supervised!({HeadlessPort, width: 80, height: 24})

    workspace = %MingaEditor.Session.State{
      buffers: %MingaEditor.State.Buffers{active: buf, list: [buf], active_index: 0},
      viewport: Viewport.new(24, 80),
      editing: MingaEditor.VimState.new(),
      windows: %MingaEditor.State.Windows{
        tree: MingaEditor.WindowTree.new(1),
        map: %{1 => MingaEditor.Window.new(1, buf, 24, 80)},
        active: 1,
        next_id: 2
      },
      keymap_scope: :editor
    }

    state = %MingaEditor.State{
      backend: :tui,
      port_manager: port,
      workspace: workspace,
      renderer: renderer_pid,
      shell_runtime:
        MingaEditor.Shell.Runtime.new(
          MingaEditor.Shell.Runtime.default_entry(),
          %MingaEditor.Shell.Traditional.State{}
        )
    }

    {state, port}
  end
end
