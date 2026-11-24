defmodule MingaAgent.Session.JobNotice do
  @moduledoc """
  The host-origin model message that tells the owning agent which background jobs ended.

  A notice is not a user instruction and not a tool result. It is one model message per delivery boundary that batches every job whose notice was pending. The message uses the `:user` role because providers accept host content after the leading instructions only in that role, and it carries `minga_origin: :job_notice` metadata so `MingaAgent.Session.Continuation` can tell it apart from user steering. Its text says it comes from the host, not from the user.

  The Session shows a delivered notice in the display transcript as a system entry built by `display_text/1`, never as a user message.

  Every function is pure.
  """

  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Tool.Output.Codec, as: OutputCodec
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tools.OutputLimit
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @origin :job_notice
  @command_bytes 240
  @header "Host notice (not from the user): background jobs you started have ended."

  @doc "Renders one host-origin model message for the given ended background jobs."
  @spec message([Record.t(), ...]) :: Message.t()
  def message([%Record{} | _] = records) do
    %Message{
      role: :user,
      content: [ContentPart.text(Enum.join([@header | Enum.map(records, &line/1)], "\n"))],
      metadata: %{minga_origin: @origin, job_ids: Enum.map(records, & &1.id)}
    }
  end

  @doc "Renders the display transcript text for the given ended background jobs."
  @spec display_text([Record.t(), ...]) :: String.t()
  def display_text([%Record{} | _] = records), do: Enum.map_join(records, "\n", &line/1)

  @doc "Returns true when the message carries job-notice origin metadata, valid or not."
  @spec notice?(term()) :: boolean()
  def notice?(%Message{metadata: %{minga_origin: @origin}}), do: true
  def notice?(_message), do: false

  @doc """
  Validates a job-notice message.

  A valid notice is a `:user` message with one text part, `minga_origin: :job_notice` metadata, and a non-empty list of unique job ids.
  """
  @spec validate(term()) :: :ok | {:error, :invalid_job_notice}
  def validate(%Message{
        role: :user,
        content: [%ContentPart{type: :text, text: text}],
        tool_calls: nil,
        tool_call_id: nil,
        metadata: %{minga_origin: @origin, job_ids: [_ | _] = ids}
      })
      when is_binary(text) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and Enum.uniq(ids) == ids,
      do: :ok,
      else: {:error, :invalid_job_notice}
  end

  def validate(_message), do: {:error, :invalid_job_notice}

  @spec line(Record.t()) :: String.t()
  defp line(%Record{} = record) do
    "Background job #{record.id} (`#{command(record.command)}`) #{outcome(record)}#{output(record)}"
  end

  @spec outcome(Record.t()) :: String.t()
  defp outcome(%Record{status: {:terminal, outcome, nil}}), do: "finished: #{outcome}."

  defp outcome(%Record{status: {:terminal, outcome, code}}),
    do: "finished: #{outcome}, exit #{code}."

  defp outcome(%Record{status: {:interrupted, reason}}),
    do: "was interrupted (#{reason}). Its outcome is unknown and it was not rerun."

  @spec output(Record.t()) :: String.t()
  defp output(%Record{output_ref: %Reference{} = reference}) do
    " Output reference for fetch_output: " <>
      JSON.encode!(OutputCodec.encode_reference(reference))
  end

  defp output(%Record{id: id}), do: " Use job_output(\"#{id}\") to read its output."

  @spec command(String.t()) :: String.t()
  defp command(command) when byte_size(command) <= @command_bytes, do: command
  defp command(command), do: OutputLimit.utf8_prefix(command, @command_bytes) <> "..."
end
