defmodule MingaEditor.Agent.UIState.TranscriptProjection.Row do
  @moduledoc false

  alias MingaAgent.Session.Transcript.Entry
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState.TranscriptProjection

  @type role :: {:user, String.t()} | {:assistant, String.t()} | :turn | :system
  @type style :: :unprepared | {map(), TranscriptProjection.rendered_message() | nil}

  @enforce_keys [:entry, :lines, :role, :pinned?]
  defstruct [:entry, :lines, :role, :pinned?, style: :unprepared]

  @type t :: %__MODULE__{
          entry: Entry.t(),
          lines: Transcript.line_profile(),
          role: role(),
          pinned?: boolean(),
          style: style()
        }

  @spec new(Entry.t(), boolean()) :: t()
  def new(%Entry{message: message} = entry, pinned?) do
    %__MODULE__{
      entry: entry,
      lines: Transcript.line_profile(message),
      role: role(message),
      pinned?: pinned?
    }
  end

  @doc "Preserves entry-local content when only the presentation revision changes."
  @spec revise(t(), Entry.t()) :: t()
  def revise(
        %__MODULE__{entry: %Entry{id: id, content_revision: revision}} = row,
        %Entry{id: id, content_revision: revision} = entry
      ),
      do: %{row | entry: entry}

  def revise(%__MODULE__{entry: %Entry{id: id}, pinned?: pinned?}, %Entry{id: id} = entry),
    do: new(entry, pinned?)

  @spec pin(t(), boolean()) :: t()
  def pin(%__MODULE__{pinned?: pinned?} = row, pinned?), do: row
  def pin(%__MODULE__{} = row, pinned?), do: %{row | pinned?: pinned?}

  @spec style(t(), map(), TranscriptProjection.rendered_message() | nil) :: t()
  def style(%__MODULE__{} = row, syntax, rendered), do: %{row | style: {syntax, rendered}}

  @spec displayed_style(t()) :: TranscriptProjection.rendered_message() | nil
  def displayed_style(%__MODULE__{style: {_syntax, rendered}}), do: rendered
  def displayed_style(%__MODULE__{style: :unprepared}), do: nil

  @spec role(term()) :: role()
  defp role({:user, text}), do: {:user, text}
  defp role({:user, text, _attachments}), do: {:user, text}

  defp role({:assistant, text}) when text != "" do
    [opening | _] = String.split(text, "\n", parts: 2)
    {:assistant, String.trim(opening)}
  end

  defp role({kind, _}) when kind in [:assistant, :tool_call, :usage], do: :turn
  defp role({:thinking, _, _}), do: :turn
  defp role(_message), do: :system
end
