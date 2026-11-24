defmodule MingaEditor.Agent.Transcript do
  @moduledoc "Entry-local semantic line classification and provenance anchors for Agent chat."

  alias MingaAgent.Session.Transcript.Entry

  @typedoc "Line type for transcript-line-to-message mapping."
  @type line_type :: :text | :code | :tool | :thinking | :usage | :system | :empty

  @type empty_state :: :checking | :credentials_missing | :no_model | nil

  @doc "Resolves the stable message id that should anchor a provenance jump for a tool call."
  @spec turn_anchor_id([Entry.t()], String.t()) :: pos_integer() | nil
  def turn_anchor_id(entries, tool_call_id) do
    find_turn_anchor(entries, tool_call_id, nil, nil)
  end

  defp find_turn_anchor([], _tool_call_id, _user, _thinking), do: nil

  defp find_turn_anchor(
         [%Entry{id: id, message: {:tool_call, %{id: tool_call_id}}} | _rest],
         tool_call_id,
         user,
         thinking
       ),
       do: user || thinking || id

  defp find_turn_anchor([%Entry{id: id, message: message} | rest], tool_call_id, user, thinking) do
    case message_kind(message) do
      :user -> find_turn_anchor(rest, tool_call_id, id, thinking)
      :thinking -> find_turn_anchor(rest, tool_call_id, user, id)
      _other -> find_turn_anchor(rest, tool_call_id, user, thinking)
    end
  end

  @type line_profile :: {pos_integer(), line_type() | tuple()}

  @doc "Derives semantic lines for one message, with independent fence state."
  @spec line_profile(term()) :: line_profile()
  def line_profile({:assistant, text}) do
    case :binary.match(text, "```") do
      :nomatch -> {line_count(text), :text}
      {_start, _length} -> fenced_line_profile(text)
    end
  end

  def line_profile({:user, text}), do: {line_count(text), :text}
  def line_profile({:user, text, _attachments}), do: {line_count(text), :text}
  def line_profile({:thinking, text, _collapsed?}), do: {line_count(text), :thinking}
  def line_profile({:system, text, _level}), do: {line_count(text), :system}

  def line_profile({:tool_call, %{result: result}}),
    do: {line_count(String.slice(result, 0, 500)), :tool}

  def line_profile({:usage, _usage}), do: {1, :usage}
  def line_profile(_message), do: {1, :text}

  @doc "Returns the local line type, including the separator after the message."
  @spec line_type_at(line_profile(), non_neg_integer()) :: line_type()
  def line_type_at({count, _types}, count), do: :empty
  def line_type_at({_count, types}, offset) when is_tuple(types), do: elem(types, offset)
  def line_type_at({_count, type}, _offset), do: type

  @spec fenced_line_profile(String.t()) :: line_profile()
  defp fenced_line_profile(text) do
    {types, _open?} =
      text
      |> :binary.split("\n", [:global])
      |> Enum.map_reduce(false, &assistant_line_type/2)

    types = List.to_tuple(types)
    {tuple_size(types), types}
  end

  @spec assistant_line_type(String.t(), boolean()) :: {:code | :text, boolean()}
  defp assistant_line_type(line, open?) do
    if String.starts_with?(String.trim_leading(line), "```") do
      {:code, not open?}
    else
      {if(open?, do: :code, else: :text), open?}
    end
  end

  @spec line_count(String.t()) :: pos_integer()
  defp line_count(text), do: count_newlines(text, 0, byte_size(text), 1)

  defp count_newlines(_text, size, size, count), do: count

  defp count_newlines(text, start, size, count) do
    case :binary.match(text, "\n", scope: {start, size - start}) do
      :nomatch -> count
      {index, 1} -> count_newlines(text, index + 1, size, count + 1)
    end
  end

  @doc "Returns the synthetic message for the current Agent setup state."
  @spec empty_state_message(:checking | :credentials_missing | :no_model) ::
          {:system, String.t(), :info}
  def empty_state_message(:checking) do
    {:system, "Checking agent credentials and model availability...", :info}
  end

  def empty_state_message(:credentials_missing) do
    {:system,
     """
     Connect a provider

     Open Models and connections with /model, or run /auth <provider> to open a masked API key prompt. Run /login to sign in with a ChatGPT subscription.

     Examples:
       /auth anthropic
       /auth openai
       /auth google
     """, :info}
  end

  def empty_state_message(:no_model) do
    {:system,
     """
     Pick a model

     Use the model picker button, /model, or SPC a S m to choose a configured model before starting a chat.
     """, :info}
  end

  @spec message_kind(term()) :: atom()
  defp message_kind({kind, _}), do: kind
  defp message_kind({kind, _, _}), do: kind
  defp message_kind(_), do: :unknown
end
