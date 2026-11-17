defmodule MingaAgent.Session.Transcript.Entry do
  @moduledoc """
  Current source entry and its revision facts within one reset generation.

  `created_revision` distinguishes appends from revisions relative to a cursor.
  `content_revision` changes only when message content changes, not when a tool
  preview or collapse flag changes. `change_revision` includes presentation changes.
  Ordinals are zero-based and stable until an explicit reset.
  """

  alias MingaAgent.Message
  alias MingaAgent.ToolCall
  alias MingaAgent.TranscriptEntry

  @enforce_keys [:id, :ordinal, :message, :created_revision, :content_revision, :change_revision]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: pos_integer(),
          ordinal: non_neg_integer(),
          message: Message.t(),
          created_revision: non_neg_integer(),
          content_revision: non_neg_integer(),
          change_revision: non_neg_integer()
        }

  @doc "Creates the current facts for an identified source entry."
  @spec new(TranscriptEntry.t(), non_neg_integer(), non_neg_integer()) :: t()
  def new(%TranscriptEntry{id: id, message: message}, ordinal, revision) do
    %__MODULE__{
      id: id,
      ordinal: ordinal,
      message: message,
      created_revision: revision,
      content_revision: revision,
      change_revision: revision
    }
  end

  @doc "Revises current facts, retaining content revision for presentation-only changes."
  @spec revise(t(), Message.t(), non_neg_integer()) :: t()
  def revise(%__MODULE__{message: message} = entry, message, _revision), do: entry

  def revise(%__MODULE__{} = entry, message, revision) do
    content_revision =
      if same_content?(entry.message, message), do: entry.content_revision, else: revision

    %{entry | message: message, content_revision: content_revision, change_revision: revision}
  end

  @doc "Freezes the identified payload at the explicit branch/persistence list boundary."
  @spec freeze(t()) :: TranscriptEntry.t()
  def freeze(%__MODULE__{id: id, message: message}), do: TranscriptEntry.new(id, message)

  defp same_content?({:thinking, text, _}, {:thinking, text, _}), do: true

  defp same_content?({:tool_call, %ToolCall{} = old}, {:tool_call, %ToolCall{} = new}) do
    old.id == new.id and old.name == new.name and old.args == new.args and
      old.status == new.status and old.result == new.result and old.output == new.output and
      old.is_error == new.is_error and old.auto_approved_scope == new.auto_approved_scope and
      old.started_at == new.started_at and old.duration_ms == new.duration_ms
  end

  defp same_content?(old, new), do: old == new
end
