defmodule MingaEditor.State.InlineAsk do
  @moduledoc """
  Ephemeral inline ask overlays keyed by buffer.

  Inline asks are presentation state only. They are not persisted and they do not create workspaces until explicitly promoted.

  The shared per-buffer store mechanics (`active/2`, `put/2`, `dismiss/2`,
  `session?/2`) and prompt-input mechanics (`append_input/2`, `backspace/1`,
  `scroll/2`) live in `MingaEditor.InlineOverlay.Store` and
  `MingaEditor.InlineOverlay.Prompt` and are reused here. This module owns
  only the ask-specific shape and transitions: the read-only response
  accumulation and the `:answered` terminal state.
  """

  alias Minga.Project.FileRef
  alias MingaEditor.InlineOverlay.Prompt
  alias MingaEditor.InlineOverlay.Store

  @type status :: :input | :thinking | :answered | :error

  @type t :: %__MODULE__{
          buffer_pid: pid(),
          file_ref: FileRef.t(),
          file_label: String.t(),
          anchor_line: non_neg_integer(),
          selection_range: {non_neg_integer(), non_neg_integer()} | nil,
          context_text: String.t(),
          prompt: String.t(),
          response: String.t(),
          status: status(),
          session_pid: pid() | nil,
          scroll: non_neg_integer()
        }

  @enforce_keys [:buffer_pid, :file_ref, :file_label, :anchor_line]
  defstruct buffer_pid: nil,
            file_ref: nil,
            file_label: "",
            anchor_line: 0,
            selection_range: nil,
            context_text: "",
            prompt: "",
            response: "",
            status: :input,
            session_pid: nil,
            scroll: 0

  @type store :: %{pid() => t()}

  @doc "Creates a new ask for a buffer."
  @spec new(
          pid(),
          FileRef.t(),
          String.t(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()} | nil,
          String.t()
        ) :: t()
  def new(
        buffer_pid,
        %FileRef{} = file_ref,
        file_label,
        anchor_line,
        selection_range \\ nil,
        context_text \\ ""
      )
      when is_pid(buffer_pid) and is_binary(file_label) and is_integer(anchor_line) and
             anchor_line >= 0 and is_binary(context_text) do
    %__MODULE__{
      buffer_pid: buffer_pid,
      file_ref: file_ref,
      file_label: file_label,
      anchor_line: anchor_line,
      selection_range: selection_range,
      context_text: context_text
    }
  end

  @doc "Returns the prompt header."
  @spec header(t()) :: String.t()
  def header(%__MODULE__{selection_range: {first, last}, file_label: label}) do
    "Ask about lines #{first + 1}–#{last + 1} of #{label}"
  end

  def header(%__MODULE__{anchor_line: line, file_label: label}) do
    "Ask about line #{line + 1} of #{label}"
  end

  @doc "Builds the read-only prompt sent to the ephemeral agent session."
  @spec agent_prompt(t()) :: String.t()
  def agent_prompt(%__MODULE__{} = ask) do
    """
    You are answering a read-only inline question inside Minga. Do not edit files or request unrelated project context. Answer from the provided file context.

    #{header(ask)}
    File: #{file_identity(ask.file_ref)}

    Relevant text:
    #{ask.context_text}

    Question:
    #{ask.prompt}
    """
  end

  @spec file_identity(FileRef.t()) :: String.t()
  defp file_identity(%FileRef{kind: :path, relative_path: path}) when is_binary(path), do: path
  defp file_identity(%FileRef{display_name: name}), do: name

  # Store mechanics (active/session?/put/dismiss) and prompt mechanics
  # (append_input/backspace/scroll) are shared with inline edit; see
  # MingaEditor.InlineOverlay.Store and MingaEditor.InlineOverlay.Prompt.

  @spec active(store(), pid() | nil) :: t() | nil
  defdelegate active(store, buffer_pid), to: Store

  @spec session?(store(), pid()) :: boolean()
  defdelegate session?(store, session_pid), to: Store

  @spec put(store(), t()) :: store()
  defdelegate put(store, ask), to: Store

  @spec dismiss(store(), pid() | nil) :: {store(), pid() | nil}
  defdelegate dismiss(store, buffer_pid), to: Store

  @spec append_input(t(), String.t()) :: t()
  defdelegate append_input(ask, text), to: Prompt

  @spec backspace(t()) :: t()
  defdelegate backspace(ask), to: Prompt

  @spec scroll(t(), integer()) :: t()
  defdelegate scroll(ask, delta), to: Prompt

  @doc "Marks the ask as thinking."
  @spec thinking(t(), pid()) :: t()
  def thinking(%__MODULE__{} = ask, session_pid) when is_pid(session_pid) do
    %{ask | status: :thinking, session_pid: session_pid, response: "", scroll: 0}
  end

  @doc "Refreshes the visible status without changing session ownership."
  @spec mark_thinking(t()) :: t()
  def mark_thinking(%__MODULE__{} = ask), do: %{ask | status: :thinking}

  @doc "Appends response text."
  @spec append_response(t(), String.t()) :: t()
  def append_response(%__MODULE__{response: response} = ask, delta) when is_binary(delta) do
    %{ask | response: response <> delta}
  end

  @doc "Marks the ask as answered."
  @spec answered(t()) :: t()
  def answered(%__MODULE__{} = ask), do: %{ask | status: :answered, session_pid: nil}

  @doc "Marks the ask as failed."
  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{} = ask, message) when is_binary(message) do
    %{ask | status: :error, response: message, session_pid: nil}
  end
end
