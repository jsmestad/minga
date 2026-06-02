defmodule MingaEditor.Agent.SemanticUI.Entry do
  @moduledoc """
  Source-owned semantic agent UI contribution.

  The payload is an existing `Minga.RenderModel.UI.*` value, or a list of existing extension-panel content values. This keeps agent UI contribution data on the same semantic render-model path used by built-in GUI/TUI surfaces.
  """

  alias Minga.Extension.ContributionCleanup
  alias Minga.RenderModel.UI.Action
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.Board
  alias Minga.RenderModel.UI.ExtensionPanel
  alias Minga.RenderModel.UI.ExtensionPanel.Content

  @typedoc "Source that owns the contribution."
  @type source :: ContributionCleanup.contribution_source()

  @typedoc "Semantic surface where the contribution is consumed."
  @type surface :: :status_card | :transcript_enrichment | :dashboard_section | :panel

  @typedoc "Existing render-model value stored by the registry."
  @type payload ::
          Board.Card.t() | AgentChat.message_body() | [Content.t()] | ExtensionPanel.Panel.t()

  @type t :: %__MODULE__{
          source: source(),
          id: String.t(),
          surface: surface(),
          target: term(),
          priority: integer(),
          payload: payload(),
          actions: [Action.t()]
        }

  @enforce_keys [:source, :id, :surface, :payload]
  defstruct source: nil,
            id: nil,
            surface: nil,
            target: :default,
            priority: 100,
            payload: nil,
            actions: []

  @doc "Builds an entry owned by `source`."
  @spec new(source(), t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(source, %__MODULE__{source: source} = entry), do: validate(entry)
  def new(source, %__MODULE__{} = entry), do: validate(%{entry | source: source})

  def new(source, attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    with {:ok, id} <- required_string(attrs, :id),
         {:ok, surface} <- surface(Map.get(attrs, :surface)),
         {:ok, payload} <- payload(surface, Map.get(attrs, :payload)),
         {:ok, actions} <- actions(Map.get(attrs, :actions, [])),
         {:ok, priority} <- priority(Map.get(attrs, :priority, 100)) do
      validate(%__MODULE__{
        source: source,
        id: id,
        surface: surface,
        target: Map.get(attrs, :target, :default),
        priority: priority,
        payload: payload,
        actions: actions
      })
    end
  end

  @doc "Updates the cached render-model payload and optional render-model action metadata."
  @spec publish(t(), payload(), [Action.t() | map() | keyword()] | nil) ::
          {:ok, t()} | {:error, term()}
  def publish(%__MODULE__{} = entry, new_payload, actions \\ nil) do
    with {:ok, payload} <- payload(entry.surface, new_payload),
         {:ok, new_actions} <- publish_actions(actions, entry.actions) do
      {:ok, %{entry | payload: payload, actions: new_actions}}
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  defp validate(
         %__MODULE__{
           id: id,
           surface: surface,
           payload: payload,
           actions: actions,
           priority: priority
         } = entry
       ) do
    with {:ok, _id} <- required_binary_value(id, :id),
         {:ok, surface} <- surface(surface),
         {:ok, _payload} <- payload(surface, payload),
         {:ok, _actions} <- actions(actions),
         {:ok, _priority} <- priority(priority) do
      {:ok, entry}
    end
  end

  @spec publish_actions([Action.t()] | nil, [Action.t()]) ::
          {:ok, [Action.t()]} | {:error, term()}
  defp publish_actions(nil, existing), do: {:ok, existing}
  defp publish_actions(actions, _existing), do: actions(actions)

  @spec required_string(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp required_string(attrs, key), do: required_binary_value(Map.get(attrs, key), key)

  @spec required_binary_value(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp required_binary_value(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary_value(_value, key), do: {:error, {:invalid, key}}

  @spec surface(term()) :: {:ok, surface()} | {:error, term()}
  defp surface(surface)
       when surface in [:status_card, :transcript_enrichment, :dashboard_section, :panel],
       do: {:ok, surface}

  defp surface(other), do: {:error, {:invalid, :surface, other}}

  @spec priority(term()) :: {:ok, integer()} | {:error, term()}
  defp priority(value) when is_integer(value), do: {:ok, value}
  defp priority(_value), do: {:error, {:invalid, :priority}}

  @spec actions(term()) :: {:ok, [Action.t()]} | {:error, term()}
  defp actions(actions) when is_list(actions), do: normalize_actions(actions, [])
  defp actions(_actions), do: {:error, {:invalid, :actions}}

  @spec normalize_actions([term()], [Action.t()]) :: {:ok, [Action.t()]} | {:error, term()}
  defp normalize_actions([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_actions([action | rest], acc) do
    case Action.new(action) do
      {:ok, normalized} -> normalize_actions(rest, [normalized | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  @spec payload(surface(), term()) :: {:ok, payload()} | {:error, term()}
  defp payload(:status_card, %Board.Card{} = card), do: {:ok, card}
  defp payload(:panel, %ExtensionPanel.Panel{} = panel), do: {:ok, panel}
  defp payload(:dashboard_section, blocks) when is_list(blocks), do: dashboard_content(blocks, [])
  defp payload(:transcript_enrichment, body), do: transcript_body(body)
  defp payload(surface, _payload), do: {:error, {:invalid_payload, surface}}

  @spec dashboard_content([term()], [Content.t()]) :: {:ok, [Content.t()]} | {:error, term()}
  defp dashboard_content([], acc), do: {:ok, Enum.reverse(acc)}

  defp dashboard_content([%module{} = block | rest], acc),
    do: dashboard_content_module(module, block, rest, acc)

  defp dashboard_content([_block | _rest], _acc),
    do: {:error, {:invalid_payload, :dashboard_section}}

  @spec dashboard_content_module(module(), struct(), [term()], [Content.t()]) ::
          {:ok, [Content.t()]} | {:error, term()}
  defp dashboard_content_module(module, block, rest, acc) do
    if extension_panel_content_module?(module) do
      dashboard_content(rest, [block | acc])
    else
      {:error, {:invalid_payload, :dashboard_section}}
    end
  end

  @spec extension_panel_content_module?(module()) :: boolean()
  defp extension_panel_content_module?(module) do
    module in [
      Minga.RenderModel.UI.ExtensionPanel.Content.Text,
      Minga.RenderModel.UI.ExtensionPanel.Content.StyledText,
      Minga.RenderModel.UI.ExtensionPanel.Content.Table,
      Minga.RenderModel.UI.ExtensionPanel.Content.KeyValue,
      Minga.RenderModel.UI.ExtensionPanel.Content.Separator,
      Minga.RenderModel.UI.ExtensionPanel.Content.Progress,
      Minga.RenderModel.UI.ExtensionPanel.Content.Tree,
      Minga.RenderModel.UI.ExtensionPanel.Content.Unknown
    ]
  end

  @spec transcript_body(term()) :: {:ok, AgentChat.message_body()} | {:error, term()}
  defp transcript_body({:user, text} = body) when is_binary(text), do: {:ok, body}
  defp transcript_body({:user, text, _attachments} = body) when is_binary(text), do: {:ok, body}
  defp transcript_body({:assistant, text} = body) when is_binary(text), do: {:ok, body}
  defp transcript_body({:styled_assistant, lines} = body), do: styled_transcript_body(body, lines)

  defp transcript_body({:thinking, text, collapsed?} = body)
       when is_binary(text) and is_boolean(collapsed?), do: {:ok, body}

  defp transcript_body({:tool_call, %AgentChat.ToolCallView{}} = body), do: {:ok, body}

  defp transcript_body({:styled_tool_call, %AgentChat.ToolCallView{}, lines} = body),
    do: styled_transcript_body(body, lines)

  defp transcript_body({:approval_tool_call, %AgentChat.ApprovalView{}} = body), do: {:ok, body}

  defp transcript_body({:system, text, level} = body) when is_binary(text) and is_atom(level),
    do: {:ok, body}

  defp transcript_body({:usage, %AgentChat.Usage{}} = body), do: {:ok, body}
  defp transcript_body(_body), do: {:error, {:invalid_payload, :transcript_enrichment}}

  @spec styled_transcript_body(AgentChat.message_body(), term()) ::
          {:ok, AgentChat.message_body()} | {:error, term()}
  defp styled_transcript_body(body, lines) when is_list(lines) do
    if Enum.all?(lines, &styled_line?/1) do
      {:ok, body}
    else
      {:error, {:invalid_payload, :transcript_enrichment}}
    end
  end

  defp styled_transcript_body(_body, _lines),
    do: {:error, {:invalid_payload, :transcript_enrichment}}

  @spec styled_line?(term()) :: boolean()
  defp styled_line?(line) when is_list(line), do: Enum.all?(line, &styled_run?/1)
  defp styled_line?(_line), do: false

  @spec styled_run?(term()) :: boolean()
  defp styled_run?({text, fg, bg, flags})
       when is_binary(text) and is_integer(fg) and fg >= 0 and is_integer(bg) and bg >= 0 and
              is_integer(flags) and flags >= 0,
       do: true

  defp styled_run?({text, fg, bg, flags, url})
       when is_binary(text) and is_integer(fg) and fg >= 0 and is_integer(bg) and bg >= 0 and
              is_integer(flags) and flags >= 0 and is_binary(url),
       do: true

  defp styled_run?(_run), do: false
end
