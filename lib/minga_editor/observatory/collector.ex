defmodule MingaEditor.Observatory.Collector do
  @moduledoc """
  Collects a BEAM Observatory snapshot off the Editor GenServer.

  `collect/1` runs the blocking `Minga.SystemObserver` queries plus the process
  tree build, then wraps the result in `MingaEditor.Observatory.Data`.

  It is **total**: any failure while talking to the observer or building the
  tree (observer process down, malformed snapshot data tripping `build_tree/1`
  or `visible/2`, a throw, or an exit) falls back to an empty view instead of
  raising. Totality is load-bearing because the Editor runs `collect/1` inside
  an unmonitored Task whose result message is the only thing that re-arms the
  refresh tick. A silent crash would freeze the refresh loop while the panel
  stays open, so the collection must never raise.
  """

  alias Minga.SystemObserver
  alias Minga.SystemObserver.TreeNode
  alias MingaEditor.Observatory.Data

  @doc """
  Builds the current Observatory data, querying `server` for the process
  snapshot and sample history. Always returns a `Data` struct, even on failure.
  """
  @spec collect(GenServer.server()) :: Data.t()
  def collect(server \\ SystemObserver) do
    case SystemObserver.snapshot(server) do
      %{processes: processes} ->
        processes
        |> TreeNode.build_tree()
        |> Data.visible(SystemObserver.samples(server))

      nil ->
        Data.visible(nil, [])
    end
  rescue
    _ -> Data.visible(nil, [])
  catch
    _kind, _ -> Data.visible(nil, [])
  end
end
