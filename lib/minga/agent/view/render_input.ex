defmodule Minga.Agent.View.RenderInput do
  @moduledoc """
  Focused input for the agent view renderers.

  Contains exactly the data needed to render the prompt input and dashboard
  sidebar, without requiring a full `EditorState`. This enables isolated
  testing and makes the data dependency graph explicit.

  Both `PromptRenderer` and `DashboardRenderer` consume this struct.
  """

  alias Minga.Agent.Session
  alias Minga.Agent.UIState
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Scroll
  alias Minga.Theme

  @enforce_keys [:theme, :agent_status, :panel, :agent_ui]
  defstruct [
    :theme,
    :agent_status,
    :panel,
    :agent_ui,
    messages: [],
    usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0},
    pending_approval: nil,
    session_title: "Minga Agent",
    lsp_servers: []
  ]

  @type t :: %__MODULE__{
          theme: Theme.t(),
          agent_status: atom() | nil,
          panel: panel_data(),
          agent_ui: agent_ui_data(),
          messages: list(),
          usage: map(),
          pending_approval: map() | nil,
          session_title: String.t(),
          lsp_servers: [atom()]
        }

  @typedoc "Agent panel fields needed for rendering."
  @type panel_data :: %{
          input_focused: boolean(),
          input_lines: [String.t()],
          input_cursor: {non_neg_integer(), non_neg_integer()},
          mode: atom(),
          mode_state: term(),
          scroll: Scroll.t(),
          spinner_frame: non_neg_integer(),
          model_name: String.t(),
          provider_name: String.t(),
          thinking_level: String.t(),
          display_start_index: non_neg_integer(),
          mention_completion: Minga.Agent.FileMention.completion() | nil,
          pasted_blocks: [UIState.paste_block()]
        }

  @typedoc "Agentic view fields needed for rendering."
  @type agent_ui_data :: %{
          chat_width_pct: non_neg_integer(),
          help_visible: boolean(),
          focus: atom(),
          search: UIState.search_state() | nil,
          toast: UIState.toast() | nil,
          context_estimate: non_neg_integer()
        }

  @doc """
  Extracts a focused `RenderInput` from full editor state.

  Reads the agent session (messages, usage) and agent UI state, producing
  a self-contained struct that both `PromptRenderer` and `DashboardRenderer`
  can render from without touching `EditorState` again.
  """
  @spec extract(EditorState.t()) :: t()
  def extract(%EditorState{} = state) do
    agent = AgentAccess.agent(state)
    panel = AgentAccess.panel(state)
    session = AgentAccess.session(state)
    view = AgentAccess.view(state)

    messages =
      if session do
        try do
          Session.messages(session)
        catch
          :exit, _ -> []
        end
      else
        []
      end

    usage =
      if session do
        try do
          Session.usage(session)
        catch
          :exit, _ -> empty_usage()
        end
      else
        empty_usage()
      end

    %__MODULE__{
      theme: state.theme,
      agent_status: agent.status,
      panel: %{
        input_focused: panel.input_focused,
        input_lines: UIState.input_lines(panel),
        input_cursor: UIState.input_cursor(panel),
        mode: state.workspace.vim.mode,
        mode_state: state.workspace.vim.mode_state,
        scroll: panel.scroll,
        spinner_frame: panel.spinner_frame,
        model_name: panel.model_name,
        provider_name: panel.provider_name,
        thinking_level: panel.thinking_level,
        display_start_index: panel.display_start_index,
        mention_completion: panel.mention_completion,
        pasted_blocks: panel.pasted_blocks
      },
      agent_ui: %{
        chat_width_pct: view.chat_width_pct,
        help_visible: view.help_visible,
        focus: view.focus,
        search: view.search,
        toast: view.toast,
        context_estimate: view.context_estimate
      },
      messages: messages,
      usage: usage,
      pending_approval: agent.pending_approval,
      session_title: session_title(messages),
      lsp_servers: safe_lsp_servers()
    }
  end

  @doc "Returns a zero-value usage map."
  @spec empty_usage() :: map()
  def empty_usage, do: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec safe_lsp_servers() :: [atom()]
  defp safe_lsp_servers do
    Minga.LSP.Supervisor.active_servers()
  catch
    :exit, _ -> []
  end

  @spec session_title([term()]) :: String.t()
  defp session_title(messages) do
    case Enum.find(messages, fn msg -> match?({:user, _}, msg) or match?({:user, _, _}, msg) end) do
      {:user, text} -> truncate_title(text)
      {:user, text, _attachments} -> truncate_title(text)
      nil -> "Minga Agent"
    end
  end

  @spec truncate_title(String.t()) :: String.t()
  defp truncate_title(text) do
    first_line = text |> String.split("\n") |> hd()
    truncated = String.slice(first_line, 0, 50)
    if String.length(truncated) == 50, do: truncated <> "...", else: truncated
  end
end
