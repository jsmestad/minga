defmodule Minga.Frontend.Adapter.GUI.AgentContextEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentContext
  alias Minga.RenderModel.UI.AgentContext.Todo

  @op_gui_agent_context Opcodes.gui_agent_context()
  @command :gui_agent_context

  @spec encode(AgentContext.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%AgentContext{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_agent_context_fp do
      cmd = encode_agent_context_binary(model)
      {cmd, %{caches | last_agent_context_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_agent_context_binary(AgentContext.t()) :: binary()
  defp encode_agent_context_binary(%AgentContext{visible: false}) do
    payload =
      Writer.new(@command)
      |> Writer.uint8(:visible, 0)
      |> Writer.string16(:task, "")
      |> Writer.uint64(:dispatch_timestamp, DateTime.to_unix(DateTime.utc_now()))
      |> Writer.uint8(:status, 0)
      |> Writer.uint8(:can_approve, 0)
      |> Writer.finish()

    encode_command(payload)
  end

  defp encode_agent_context_binary(%AgentContext{} = model) do
    payload =
      Writer.new(@command)
      |> Writer.uint8(:visible, 1)
      |> Writer.string16(:task, model.task)
      |> Writer.uint64(:dispatch_timestamp, DateTime.to_unix(model.dispatch_timestamp))
      |> Writer.uint8(:status, status_to_byte(model.status))
      |> Writer.uint8(:can_approve, if(model.can_approve, do: 1, else: 0))
      |> Writer.append(encode_progress(model))
      |> Writer.append(encode_todos(model.todos))
      |> Writer.finish()

    encode_command(payload)
  end

  @spec encode_command(binary()) :: binary()
  defp encode_command(payload) do
    Writer.new(@command)
    |> Writer.uint8(:opcode, @op_gui_agent_context)
    |> Writer.payload16(:payload, payload)
    |> Writer.finish()
  end

  @spec status_to_byte(AgentContext.status()) :: non_neg_integer()
  defp status_to_byte(:idle), do: 0
  defp status_to_byte(:working), do: 1
  defp status_to_byte(:iterating), do: 2
  defp status_to_byte(:needs_you), do: 3
  defp status_to_byte(:done), do: 4
  defp status_to_byte(:errored), do: 5

  @spec encode_progress(AgentContext.t()) :: binary()
  defp encode_progress(%AgentContext{progress: progress}) do
    Writer.new(@command)
    |> Writer.string16(:active_action, progress.active_action)
    |> Writer.uint16(:tool_count, progress.tool_count)
    |> Writer.uint16(:file_count, progress.file_count)
    |> Writer.string16(:review_hint, progress.review_hint)
    |> Writer.finish()
  end

  @spec encode_todos([Todo.t()]) :: binary()
  defp encode_todos(todos) do
    Writer.new(@command)
    |> Writer.uint8(:todo_count, Enum.count(todos))
    |> Writer.append(Enum.map(todos, &encode_todo/1))
    |> Writer.finish()
  end

  @spec encode_todo(Todo.t()) :: binary()
  defp encode_todo(%Todo{} = todo) do
    Writer.new(@command)
    |> Writer.uint8(:todo_status, todo_status_to_byte(todo.status))
    |> Writer.string16(:todo_description, todo.description)
    |> Writer.finish()
  end

  @spec todo_status_to_byte(Todo.status()) :: non_neg_integer()
  defp todo_status_to_byte(:pending), do: 0
  defp todo_status_to_byte(:in_progress), do: 1
  defp todo_status_to_byte(:done), do: 2
end
