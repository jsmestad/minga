defmodule MingaEditor.Shell.Traditional.ToolPrompts do
  @moduledoc """
  Pure owner of Traditional missing-tool prompt decisions and queue state.

  Tool discovery and installation checks remain in handlers. This value only
  owns the user's session-local decisions and ordered prompt lifecycle.
  """

  @type t :: %__MODULE__{
          declined: MapSet.t(atom()),
          queue: [atom()],
          suppressed?: boolean()
        }

  defstruct declined: MapSet.new(), queue: [], suppressed?: false

  @doc "Controls whether missing-tool prompts are suppressed."
  @spec suppress(t(), boolean()) :: t()
  def suppress(%__MODULE__{} = prompts, suppressed?) when is_boolean(suppressed?),
    do: %{prompts | suppressed?: suppressed?}

  @doc "Returns whether prompts are suppressed."
  @spec suppressed?(t()) :: boolean()
  def suppressed?(%__MODULE__{suppressed?: suppressed?}), do: suppressed?

  @doc "Returns the ordered pending tool queue."
  @spec queue(t()) :: [atom()]
  def queue(%__MODULE__{queue: queue}), do: queue

  @doc "Returns the set of tools declined during this editor session."
  @spec declined(t()) :: MapSet.t(atom())
  def declined(%__MODULE__{declined: declined}), do: declined

  @doc "Returns whether a tool was declined or is already queued."
  @spec decided?(t(), atom()) :: boolean()
  def decided?(%__MODULE__{} = prompts, tool_name),
    do: MapSet.member?(prompts.declined, tool_name) or tool_name in prompts.queue

  @doc "Queues a tool once."
  @spec enqueue(t(), atom()) :: t()
  def enqueue(%__MODULE__{} = prompts, tool_name) when is_atom(tool_name) do
    if decided?(prompts, tool_name),
      do: prompts,
      # Small human-facing prompt queues preserve order directly.
      # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
      else: %{prompts | queue: prompts.queue ++ [tool_name]}
  end

  @doc "Replaces prompt decisions and queue atomically."
  @spec replace(t(), [atom()], MapSet.t(atom())) :: t()
  def replace(%__MODULE__{} = prompts, queue, declined) when is_list(queue),
    do: %{prompts | queue: queue, declined: declined}

  @doc "Drops the current queued prompt."
  @spec advance(t()) :: t()
  def advance(%__MODULE__{queue: [_current | rest]} = prompts), do: %{prompts | queue: rest}
  def advance(%__MODULE__{} = prompts), do: prompts
end
