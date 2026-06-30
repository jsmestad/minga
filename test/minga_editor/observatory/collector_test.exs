defmodule MingaEditor.Observatory.CollectorTest.FakeObserver do
  @moduledoc false
  # Stand-in for Minga.SystemObserver that replies to :snapshot and :samples
  # with caller-supplied values, so tests can feed Collector.collect/1 either
  # well-formed or deliberately malformed observer output.
  use GenServer

  @spec start_link(%{snapshot: term(), samples: term()}) :: GenServer.on_start()
  def start_link(replies), do: GenServer.start_link(__MODULE__, replies)

  @impl true
  def init(replies), do: {:ok, replies}

  @impl true
  def handle_call(:snapshot, _from, %{snapshot: snapshot} = replies),
    do: {:reply, snapshot, replies}

  def handle_call(:samples, _from, %{samples: samples} = replies),
    do: {:reply, samples, replies}
end

defmodule MingaEditor.Observatory.CollectorTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Observatory.Collector
  alias MingaEditor.Observatory.CollectorTest.FakeObserver
  alias MingaEditor.Observatory.Data

  describe "collect/1" do
    test "returns the empty fallback when the observer reports no snapshot" do
      {:ok, observer} = start_supervised({FakeObserver, %{snapshot: nil, samples: []}})

      assert %Data{visible: true, tree: nil, samples: []} = Collector.collect(observer)
    end

    # Liveness guard: Collector.collect/1 runs inside an unmonitored Task in the
    # Editor whose result message is the *only* thing that re-arms the refresh
    # tick. A non-:exit failure (a raise/throw on malformed observer output)
    # would kill the Task silently and freeze the refresh loop while the panel
    # stays open. So collect/1 must be total: it returns the empty fallback
    # rather than propagating the failure.
    test "is total: malformed snapshot data yields the empty fallback instead of raising" do
      # A non-empty snapshot map whose values are not ProcessSnapshot structs:
      # build_tree/1 reads `.parent_pid` on each value and raises KeyError.
      malformed = %{self() => %{not: :a_process_snapshot}}

      # Sanity: this shape genuinely crashes the tree builder, so this test would
      # fail without collect/1's rescue/catch (the regression it guards against).
      assert_raise KeyError, fn ->
        Minga.SystemObserver.TreeNode.build_tree(malformed)
      end

      {:ok, observer} =
        start_supervised({FakeObserver, %{snapshot: %{processes: malformed}, samples: []}})

      assert %Data{visible: true} = Collector.collect(observer)
    end

    test "is total: an observer that exits mid-call yields the empty fallback" do
      {:ok, observer} =
        start_supervised({FakeObserver, %{snapshot: %{processes: %{}}, samples: []}})

      GenServer.stop(observer)

      # snapshot/1 against a dead server exits; collect/1 catches it.
      assert %Data{visible: true, tree: nil, samples: []} = Collector.collect(observer)
    end
  end
end
