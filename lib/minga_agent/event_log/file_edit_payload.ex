defmodule MingaAgent.EventLog.FileEditPayload do
  @moduledoc """
  Owns the durable payload of a `:file_edit_proposed` event.

  Each side of an edit is file content or `:absent`, which means the file did not exist before or after the edit. The event log stores payloads as JSON, where an atom becomes a string, so `:absent` cannot be stored in the content field: it would read back as a file whose text is "absent".

  The payload keeps each side's content as a string (`""` when the file is absent), so readers that search or classify the text keep working. A separate boolean (`before_exists`, `after_exists`) records whether the file existed. Replay decodes the pair back to the content or `:absent`.

  Records written before the presence flags existed carry the string "absent" for a missing file. Those records cannot tell a missing file from a file whose text is "absent"; they decode as `:absent`, so a replay skips a reload instead of writing the word into a buffer.
  """

  @typedoc "One side of a file edit: the file content, or `:absent` when the file did not exist."
  @type side :: String.t() | :absent

  @legacy_absent "absent"

  @doc "Builds the event-log payload for one agent file edit."
  @spec new(String.t(), side(), side(), String.t(), String.t()) :: map()
  def new(path, before_content, after_content, tool_call_id, tool_name) do
    %{
      path: path,
      before_content: content(before_content),
      before_exists: before_content != :absent,
      after_content: content(after_content),
      after_exists: after_content != :absent,
      tool_call_id: tool_call_id,
      tool_name: tool_name
    }
  end

  @doc """
  Decodes one side from its stored content and presence flag.

  `exists` is `nil` for a record written before the presence flags existed.
  """
  @spec decode_side(term(), term()) :: side()
  def decode_side(_content, false), do: :absent
  def decode_side(content, true) when is_binary(content), do: content
  def decode_side(@legacy_absent, nil), do: :absent
  def decode_side(content, nil) when is_binary(content), do: content
  def decode_side(_content, _exists), do: ""

  @spec content(side()) :: String.t()
  defp content(:absent), do: ""
  defp content(content) when is_binary(content), do: content
end
