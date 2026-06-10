defmodule Minga.Bench.AgentStreamReplay do
  @moduledoc """
  Deterministic synthetic agent-streaming fixture (ticket #2215).

  The keystroke-latency baseline measures typing latency under agent-streaming
  load. To keep the numbers comparable across runs, the load must be a fixed
  replay rather than wall-clock randomness: every run interleaves the *same*
  sequence of streamed message chunks between keystrokes.

  `chunks/0` returns a fixed list of text chunks that mimic a coding agent
  streaming a response token-by-token. The bench appends each chunk to a
  scratch message store / streams it through the same path an agent would,
  forcing chrome rebuilds and competing render work while the user types.

  This module is pure data: no timers, no RNG, no IO.
  """

  @doc """
  Returns the deterministic stream of agent chunks replayed during the
  agent-streaming scenario. Stable across runs by construction.
  """
  @spec chunks() :: [String.t()]
  def chunks do
    base = [
      "I'll start by reading the relevant module ",
      "and the surrounding tests so I understand ",
      "the current behaviour. ",
      "```elixir\n",
      "def handle_event(socket, %{\"key\" => key}) do\n",
      "  socket\n",
      "  |> assign(:last_key, key)\n",
      "  |> maybe_dispatch(key)\n",
      "end\n",
      "```\n",
      "Next, I'll thread the correlation id ",
      "through the render pipeline so the frontend ",
      "can resolve the sample at the frame boundary. ",
      "This keeps the wire change minimal: one ",
      "sequence id on key events, echoed on batch_end."
    ]

    # Repeat the base script deterministically so the load lasts the whole
    # typing run. The repetition count is fixed, not derived from timing.
    for _ <- 1..8, chunk <- base, do: chunk
  end
end
