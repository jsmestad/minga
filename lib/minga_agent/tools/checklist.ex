defmodule MingaAgent.Tools.Checklist do
  @moduledoc "Model tools for reading and replacing the owning Session's checklist."

  alias MingaAgent.Checklist
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Spec
  alias MingaAgent.Tool.Output.Reference

  @page_bytes 40_000

  @doc "Declares the checklist read tool."
  @spec read_spec() :: Spec.t()
  def read_spec do
    spec(
      "todo_read",
      "Read the first page of the ordered checklist. For more tasks, pass next_offset and the same revision as offset and expected_revision. A null next_offset marks the end.",
      %{
        "type" => "object",
        "properties" => %{
          "offset" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
          "expected_revision" => %{"type" => "integer", "minimum" => 0}
        },
        "additionalProperties" => false
      },
      :read_only
    )
  end

  @doc "Declares the revision-checked checklist replacement tool."
  @spec write_spec() :: Spec.t()
  def write_spec do
    spec(
      "todo_write",
      "Replace the current checklist at the revision returned by todo_read. Preserve task IDs across updates. A stale revision does not change the checklist. Tasks record status and evidence, but do not schedule work.",
      %{
        "type" => "object",
        "properties" => %{
          "expected_revision" => %{"type" => "integer", "minimum" => 0},
          "tasks" => %{
            "type" => "array",
            "maxItems" => 100,
            "items" => %{
              "type" => "object",
              "properties" => %{
                "id" => %{"type" => "string", "minLength" => 1, "maxLength" => 64},
                "description" => %{"type" => "string", "minLength" => 1, "maxLength" => 512},
                "status" => %{
                  "type" => "string",
                  "enum" => ["pending", "in_progress", "blocked", "done"]
                },
                "note" => %{"type" => ["string", "null"], "maxLength" => 2048},
                "result_ref" => %{
                  "type" => ["string", "null"],
                  "description" =>
                    "Reuse the result_ref token returned by todo_read or pass a retained output token from this session."
                }
              },
              "required" => ["id", "description", "status"],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["expected_revision", "tasks"],
        "additionalProperties" => false
      },
      # Replacing the checklist changes Session state, so concurrent writes would race and break model order.
      :mutating
    )
  end

  @spec spec(String.t(), String.t(), map(), Spec.effect()) :: Spec.t()
  defp spec(name, description, schema, effect) do
    Spec.new!(
      name: name,
      effect: effect,
      description: description,
      parameter_schema: schema,
      source: :builtin,
      category: :agent,
      approval_level: :auto,
      capabilities: [],
      context_requirements: [:tool_context],
      build: fn context -> fn _validated_args -> execute(context) end end
    )
  end

  @spec execute(Context.t()) :: {:ok, String.t()} | {:error, term()}
  defp execute(%Context{session_invocation: {session, invocation}}) do
    case GenServer.call(session, {:checklist_invocation, invocation}, 30_000) do
      {:page, checklist, durable?, offset} ->
        {:ok, encode_page(checklist, durable?, offset)}

      {:written, revision, count, durable?} ->
        {:ok, JSON.encode!(%{revision: revision, task_count: count, durable: durable?})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute(_context), do: {:error, :session_invocation_required}

  @spec encode_page(Checklist.t(), boolean(), non_neg_integer()) :: String.t()
  defp encode_page(checklist, durable?, offset) do
    {revision, tasks} = Checklist.snapshot(checklist)
    {rows, next_offset} = encode_rows(Enum.drop(tasks, offset), offset, @page_bytes, [])

    metadata = JSON.encode!(%{revision: revision, durable: durable?, next_offset: next_offset})
    header = binary_part(metadata, 0, byte_size(metadata) - 1)
    IO.iodata_to_binary([header, ",\"tasks\":[", Enum.intersperse(rows, ","), "]}"])
  end

  @spec encode_rows([MingaAgent.TodoItem.t()], non_neg_integer(), integer(), [binary()]) ::
          {[binary()], non_neg_integer() | nil}
  defp encode_rows([], _offset, _budget, rows), do: {Enum.reverse(rows), nil}

  defp encode_rows([item | rest], offset, budget, rows) do
    reference =
      case item.result_ref do
        %Reference{token: token} -> token
        nil -> nil
      end

    row =
      JSON.encode!(%{
        id: item.id,
        description: item.description,
        status: item.status,
        note: item.note,
        result_ref: reference
      })

    bytes = byte_size(row) + 1

    if bytes > budget,
      do: {Enum.reverse(rows), offset},
      else: encode_rows(rest, offset + 1, budget - bytes, [row | rows])
  end
end
