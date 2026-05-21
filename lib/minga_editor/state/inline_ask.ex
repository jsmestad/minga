defmodule MingaEditor.State.InlineAsk do
  @moduledoc """
  Ephemeral inline ask overlays keyed by buffer.

  Inline asks are presentation state only. They are not persisted and they do not create workspaces until explicitly promoted.
  """

  alias Minga.Project.FileRef

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

  @doc "Returns the active ask for a buffer."
  @spec active(store(), pid() | nil) :: t() | nil
  def active(store, buffer_pid) when is_map(store) and is_pid(buffer_pid),
    do: Map.get(store, buffer_pid)

  def active(_store, _buffer_pid), do: nil

  @doc "Returns true when the given session pid belongs to an inline ask."
  @spec session?(store(), pid()) :: boolean()
  def session?(store, session_pid) when is_map(store) and is_pid(session_pid) do
    Enum.any?(store, fn {_buffer, ask} -> ask.session_pid == session_pid end)
  end

  @doc "Opens or replaces an ask for its buffer."
  @spec put(store(), t()) :: store()
  def put(store, %__MODULE__{buffer_pid: buffer_pid} = ask) when is_map(store) do
    Map.put(store, buffer_pid, ask)
  end

  @doc "Dismisses the ask for a buffer."
  @spec dismiss(store(), pid() | nil) :: {store(), pid() | nil}
  def dismiss(store, buffer_pid) when is_map(store) and is_pid(buffer_pid) do
    {ask, store} = Map.pop(store, buffer_pid)
    {store, if(ask, do: ask.session_pid, else: nil)}
  end

  def dismiss(store, _buffer_pid), do: {store, nil}

  @doc "Appends input to an ask."
  @spec append_input(t(), String.t()) :: t()
  def append_input(%__MODULE__{status: :input, prompt: prompt} = ask, text)
      when is_binary(text) do
    %{ask | prompt: prompt <> text}
  end

  def append_input(%__MODULE__{} = ask, _text), do: ask

  @doc "Deletes one input character."
  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{status: :input, prompt: prompt} = ask) do
    %{ask | prompt: prompt |> String.graphemes() |> Enum.drop(-1) |> Enum.join()}
  end

  def backspace(%__MODULE__{} = ask), do: ask

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

  @doc "Scrolls response text within the bounded overlay."
  @spec scroll(t(), integer()) :: t()
  def scroll(%__MODULE__{scroll: current} = ask, delta) when is_integer(delta) do
    %{ask | scroll: max(current + delta, 0)}
  end

  @doc "Marks the ask as failed."
  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{} = ask, message) when is_binary(message) do
    %{ask | status: :error, response: message, session_pid: nil}
  end
end
