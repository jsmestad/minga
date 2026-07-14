defmodule MingaEditor.Commands.AgentSubStates do
  @moduledoc """
  Agent sub-state command handlers: search, mention completion, diff review, tool approval.

  These handle key input within transient sub-states of the agent scope.
  Extracted from `Commands.Agent` to reduce module size.
  """

  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.ChatSearch
  alias MingaEditor.Agent.DiffReview
  alias MingaAgent.FileMention
  alias MingaAgent.ProjectView
  alias MingaAgent.Session
  alias MingaEditor.Agent.SlashCommand
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.View.Preview
  alias Minga.Buffer
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.TabBar
  alias Minga.Git

  import Bitwise

  @type state :: EditorState.t()

  # ── Search input handling ──────────────────────────────────────────────────

  @doc "Handles a key during active search input."
  @spec handle_search_key(state(), non_neg_integer()) :: state()
  def handle_search_key(state, 13) do
    update_agent_ui(state, &UIState.confirm_search/1)
  end

  def handle_search_key(state, 27) do
    saved = UIState.search_saved_scroll(state.workspace.agent_ui)
    state = update_agent_ui(state, &UIState.cancel_search/1)
    if saved, do: update_agent_ui(state, &UIState.set_scroll(&1, saved)), else: state
  end

  def handle_search_key(state, 127) do
    query = UIState.search_query(state.workspace.agent_ui) || ""

    if query == "" do
      handle_search_key(state, 27)
    else
      new_query = String.slice(query, 0..-2//1)
      state = update_agent_ui(state, &UIState.update_search_query(&1, new_query))
      run_search(state, new_query)
    end
  end

  def handle_search_key(state, cp) when cp >= 32 and cp <= 126 do
    char = <<cp::utf8>>
    query = (UIState.search_query(state.workspace.agent_ui) || "") <> char
    state = update_agent_ui(state, &UIState.update_search_query(&1, query))
    run_search(state, query)
  end

  def handle_search_key(state, _cp), do: state

  @doc "Starts search mode in the chat."
  @spec start_search(state()) :: state()
  def start_search(state) do
    scroll = state.workspace.agent_ui.panel.scroll.offset
    update_agent_ui(state, &UIState.start_search(&1, scroll))
  end

  @doc "Jumps to the next search match."
  @spec next_match(state()) :: state()
  def next_match(state) do
    if state.workspace.agent_ui.view.search.input_active do
      state
    else
      state = update_agent_ui(state, &UIState.next_search_match/1)
      scroll_to_current_match(state)
    end
  end

  @doc "Jumps to the previous search match."
  @spec prev_match(state()) :: state()
  def prev_match(state) do
    if state.workspace.agent_ui.view.search.input_active do
      state
    else
      state = update_agent_ui(state, &UIState.prev_search_match/1)
      scroll_to_current_match(state)
    end
  end

  # ── Mention completion handling ────────────────────────────────────────────

  @doc "Handles a key during active mention completion."
  @spec handle_mention_key(state(), non_neg_integer(), non_neg_integer()) :: state()
  def handle_mention_key(state, 9, mods) do
    if band(mods, 0x01) != 0 do
      update_panel(state, fn p ->
        comp = FileMention.select_prev(p.mention_completion)
        %{p | mention_completion: comp}
      end)
    else
      update_panel(state, fn p ->
        comp = FileMention.select_next(p.mention_completion)
        %{p | mention_completion: comp}
      end)
    end
  end

  def handle_mention_key(state, 13, _mods), do: accept_completion(state)

  def handle_mention_key(state, 27, _mods) do
    update_panel(state, fn p -> %{p | mention_completion: nil} end)
  end

  def handle_mention_key(state, 127, _mods) do
    comp = state.workspace.agent_ui.panel.mention_completion

    if slash_completion?(comp) do
      slash_backspace(state, comp)
    else
      mention_backspace(state, comp)
    end
  end

  def handle_mention_key(state, cp, mods)
      when cp >= 32 and band(mods, 0x02) == 0 and band(mods, 0x04) == 0 do
    comp = state.workspace.agent_ui.panel.mention_completion

    if slash_completion?(comp) do
      slash_insert_char(state, comp, <<cp::utf8>>)
    else
      mention_insert_char(state, <<cp::utf8>>)
    end
  end

  def handle_mention_key(state, _cp, _mods), do: state

  @doc "Triggers @-mention file completion if at word boundary."
  @spec trigger_mention(state()) :: state()
  def trigger_mention(state) do
    if should_trigger_mention?(state) do
      state = AgentCommands.input_char(state, "@")
      start_mention_completion(state)
    else
      AgentCommands.input_char(state, "@")
    end
  end

  @doc "Returns true when the prompt cursor is inside the leading slash command token."
  @spec slash_command_token_at_cursor?(state()) :: boolean()
  def slash_command_token_at_cursor?(state), do: slash_command_token_at_cursor(state) != nil

  @doc "Triggers /slash command completion from the current slash command token."
  @spec trigger_slash_completion(state()) :: state()
  def trigger_slash_completion(state) do
    case slash_command_token_at_cursor(state) do
      {prefix, anchor_line, anchor_col} ->
        slash_completion_state(state, prefix, anchor_line, anchor_col)
        |> update_slash_completion(state)

      nil ->
        update_slash_completion(nil, state)
    end
  end

  # ── Diff review commands ───────────────────────────────────────────────────

  @doc "Accepts the current diff hunk during review."
  @spec accept_hunk(state()) :: state()
  def accept_hunk(state) do
    case state.workspace.agent_ui.view.preview do
      %Preview{content: {:diff, _review}} ->
        state =
          update_preview(
            state,
            &Preview.update_diff(&1, fn r -> DiffReview.accept_current(r) end)
          )

        maybe_finish_review(state)

      _ ->
        state
    end
  end

  @doc "Rejects the current diff hunk during review."
  @spec reject_hunk(state()) :: state()
  def reject_hunk(state) do
    case state.workspace.agent_ui.view.preview do
      %Preview{content: {:diff, review}} ->
        hunk = DiffReview.current_hunk(review)
        if hunk, do: revert_hunk(state, review, hunk)

        state =
          update_preview(
            state,
            &Preview.update_diff(&1, fn r -> DiffReview.reject_current(r) end)
          )

        maybe_finish_review(state)

      _ ->
        state
    end
  end

  @doc "Accepts all remaining diff hunks."
  @spec accept_all_hunks(state()) :: state()
  def accept_all_hunks(state) do
    case state.workspace.agent_ui.view.preview do
      %Preview{content: {:diff, _}} ->
        state =
          update_preview(state, &Preview.update_diff(&1, fn r -> DiffReview.accept_all(r) end))

        maybe_finish_review(state)

      _ ->
        state
    end
  end

  @doc "Rejects all remaining diff hunks."
  @spec reject_all_hunks(state()) :: state()
  def reject_all_hunks(state) do
    case state.workspace.agent_ui.view.preview do
      %Preview{content: {:diff, review}} ->
        unresolved_hunks =
          review.hunks
          |> Enum.with_index()
          |> Enum.reject(fn {_hunk, idx} -> Map.has_key?(review.resolutions, idx) end)
          |> Enum.map(fn {hunk, _idx} -> hunk end)
          |> Enum.reverse()

        revert_hunks(state, review, unresolved_hunks)

        state =
          update_preview(state, &Preview.update_diff(&1, fn r -> DiffReview.reject_all(r) end))

        maybe_finish_review(state)

      _ ->
        state
    end
  end

  # ── Tool approval commands ─────────────────────────────────────────────────

  @doc "Approves the pending tool execution."
  @spec approve_tool(state()) :: state()
  def approve_tool(state), do: respond_to_tool_approval(state, :approve)

  @doc "Approves this tool for the rest of the session."
  @spec trust_tool_session(state()) :: state()
  def trust_tool_session(state), do: respond_to_tool_approval(state, :approve_session)

  @doc "Approves this tool for the current turn."
  @spec trust_tool_turn(state()) :: state()
  def trust_tool_turn(state), do: respond_to_tool_approval(state, :approve_turn)

  @doc "Denies the pending tool execution."
  @spec deny_tool(state()) :: state()
  def deny_tool(state), do: respond_to_tool_approval(state, :reject)

  @spec respond_to_tool_approval(state(), Session.approval_decision()) :: state()
  defp respond_to_tool_approval(state, decision) do
    agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
    session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)
    approval = agent.pending_approval

    if is_pid(session) and is_map(approval) do
      apply_approval_response(
        state,
        AgentSession.respond_to_approval_pid(session, approval.tool_call_id, decision)
      )
    else
      state
    end
  end

  # Only clear the approval UI once the session has *accepted* the decision,
  # so an undelivered response never silently drops the prompt while the agent
  # stays blocked. `:no_pending_approval` is the one error that means the
  # session already resolved this approval, so the prompt is stale: clear it
  # rather than leave a dead prompt that every retry would re-fail.
  @spec apply_approval_response(state(), :ok | {:error, term()}) :: state()
  defp apply_approval_response(state, :ok) do
    update_agent(state, &AgentState.clear_pending_approval/1)
  end

  defp apply_approval_response(state, {:error, :no_pending_approval}) do
    state
    |> update_agent(&AgentState.clear_pending_approval/1)
    |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("Tool approval already resolved")
  end

  defp apply_approval_response(state, {:error, reason}) do
    Minga.Log.error(:agent, "[Agent] tool approval response failed: #{inspect(reason)}")

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "Tool approval failed: #{inspect(reason)}"
    )
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec slash_completion?(map() | nil) :: boolean()
  defp slash_completion?(comp), do: is_map(comp) and Map.has_key?(comp, :slash_candidates)

  @spec accept_completion(state()) :: state()
  defp accept_completion(state) do
    comp = state.workspace.agent_ui.panel.mention_completion

    if slash_completion?(comp) do
      accept_slash_completion(state, comp)
    else
      accept_mention_completion(state)
    end
  end

  @spec mention_backspace(state(), map()) :: state()
  defp mention_backspace(state, comp) do
    if comp.prefix == "" do
      state = AgentCommands.input_backspace(state)
      update_panel(state, fn p -> %{p | mention_completion: nil} end)
    else
      state = AgentCommands.input_backspace(state)
      new_prefix = String.slice(comp.prefix, 0..-2//1)

      update_panel(state, fn p ->
        %{p | mention_completion: FileMention.update_prefix(comp, new_prefix)}
      end)
    end
  end

  @spec slash_backspace(state(), map()) :: state()
  defp slash_backspace(state, %{prefix: ""}) do
    state = AgentCommands.input_backspace(state)
    update_panel(state, fn p -> %{p | mention_completion: nil} end)
  end

  defp slash_backspace(state, comp) do
    state = AgentCommands.input_backspace(state)
    new_input = trim_last_grapheme(comp.prefix)

    slash_completion_state(state, new_input, comp.anchor_line, comp.anchor_col)
    |> update_slash_completion(state)
  end

  @spec slash_insert_char(state(), map(), String.t()) :: state()
  defp slash_insert_char(state, comp, char) do
    state = AgentCommands.input_char(state, char)
    new_input = comp.prefix <> char

    slash_completion_state(state, new_input, comp.anchor_line, comp.anchor_col)
    |> update_slash_completion(state)
  end

  @spec trim_last_grapheme(String.t()) :: String.t()
  defp trim_last_grapheme(""), do: ""

  defp trim_last_grapheme(text) do
    text
    |> String.graphemes()
    |> Enum.drop(-1)
    |> Enum.join()
  end

  @spec slash_completion_state(state(), String.t(), non_neg_integer(), non_neg_integer()) ::
          map() | nil
  defp slash_completion_state(state, input, anchor_line, anchor_col) do
    candidates = SlashCommand.completion_candidates(state, input)

    if candidates == [] do
      nil
    else
      labels = Enum.map(candidates, & &1.label)

      %{
        prefix: input,
        all_files: [],
        candidates: labels,
        selected: 0,
        anchor_line: anchor_line,
        anchor_col: anchor_col,
        slash_candidates: Enum.map(candidates, &{&1.label, &1.description}),
        slash_insertions: Map.new(candidates, &{&1.label, &1.insert})
      }
    end
  end

  @spec update_slash_completion(map() | nil, state()) :: state()
  defp update_slash_completion(nil, state) do
    update_panel(state, fn p -> %{p | mention_completion: nil} end)
  end

  defp update_slash_completion(comp, state) do
    update_panel(state, fn p -> %{p | mention_completion: comp} end)
  end

  @spec slash_command_token_at_cursor(state()) ::
          {String.t(), non_neg_integer(), non_neg_integer()} | nil
  defp slash_command_token_at_cursor(state) do
    panel = state.workspace.agent_ui.panel

    case MingaEditor.Agent.PromptBuffer.input_cursor(panel) do
      {0, col} ->
        current_line = Enum.at(MingaEditor.Agent.PromptBuffer.input_lines(panel), 0, "")
        before_cursor = String.slice(current_line, 0, col)

        if leading_slash_token?(before_cursor) do
          {String.trim_leading(before_cursor, "/"), 0, 0}
        else
          nil
        end

      {_line, _col} ->
        nil
    end
  end

  @spec leading_slash_token?(String.t()) :: boolean()
  defp leading_slash_token?("/"), do: true

  defp leading_slash_token?("/" <> rest) do
    not String.contains?(rest, [" ", "\t", "\n"])
  end

  defp leading_slash_token?(_text), do: false

  @spec accept_slash_completion(state(), map()) :: state()
  defp accept_slash_completion(state, comp) do
    case Enum.at(comp.candidates, comp.selected) do
      nil ->
        update_panel(state, fn p -> %{p | mention_completion: nil} end)

      label ->
        insert = Map.get(Map.get(comp, :slash_insertions, %{}), label, label)
        replace_slash_input(state, comp, insert)
    end
  end

  @spec replace_slash_input(state(), map(), String.t()) :: state()
  defp replace_slash_input(state, comp, insert) do
    panel = state.workspace.agent_ui.panel
    {line, _col} = MingaEditor.Agent.PromptBuffer.input_cursor(panel)
    lines = MingaEditor.Agent.PromptBuffer.input_lines(panel)
    current = Enum.at(lines, line, "")
    anchor_col = comp.anchor_col

    before = String.slice(current, 0, anchor_col)

    after_prefix =
      String.slice(
        current,
        anchor_col + 1 + String.length(comp.prefix),
        String.length(current)
      )

    new_line = before <> "/" <> insert <> " " <> after_prefix
    new_col = anchor_col + 1 + String.length(insert) + 1
    new_lines = List.replace_at(lines, line, new_line)
    new_content = Enum.join(new_lines, "\n")

    state = sync_mention_to_buffer(state, new_content, line, new_col)
    update_panel(state, fn p -> %{p | mention_completion: nil} end)
  end

  @spec mention_insert_char(state(), String.t()) :: state()
  defp mention_insert_char(state, " ") do
    state = update_panel(state, fn p -> %{p | mention_completion: nil} end)
    AgentCommands.input_char(state, " ")
  end

  defp mention_insert_char(state, char) do
    state = AgentCommands.input_char(state, char)
    comp = state.workspace.agent_ui.panel.mention_completion
    new_prefix = comp.prefix <> char

    update_panel(state, fn p ->
      %{p | mention_completion: FileMention.update_prefix(comp, new_prefix)}
    end)
  end

  @spec should_trigger_mention?(state()) :: boolean()
  defp should_trigger_mention?(state) do
    panel = state.workspace.agent_ui.panel
    {line, col} = MingaEditor.Agent.PromptBuffer.input_cursor(panel)
    current_line = Enum.at(MingaEditor.Agent.PromptBuffer.input_lines(panel), line, "")
    col == 0 or String.at(current_line, col - 1) in [" ", "\t", nil]
  end

  @spec start_mention_completion(state()) :: state()
  defp start_mention_completion(state) do
    files = list_project_files()
    {line, col} = MingaEditor.Agent.PromptBuffer.input_cursor(state.workspace.agent_ui.panel)
    completion = FileMention.new_completion(files, line, col - 1)
    update_panel(state, fn p -> %{p | mention_completion: completion} end)
  end

  @spec accept_mention_completion(state()) :: state()
  defp accept_mention_completion(state) do
    comp = state.workspace.agent_ui.panel.mention_completion

    case FileMention.selected_path(comp) do
      nil ->
        update_panel(state, fn p -> %{p | mention_completion: nil} end)

      path ->
        panel = state.workspace.agent_ui.panel
        {line, _col} = MingaEditor.Agent.PromptBuffer.input_cursor(panel)
        lines = MingaEditor.Agent.PromptBuffer.input_lines(panel)
        current = Enum.at(lines, line)
        anchor_col = comp.anchor_col

        before = String.slice(current, 0, anchor_col)

        after_prefix =
          String.slice(
            current,
            anchor_col + 1 + String.length(comp.prefix),
            String.length(current)
          )

        new_line = before <> "@" <> path <> " " <> after_prefix
        new_col = anchor_col + 1 + String.length(path) + 1
        new_lines = List.replace_at(lines, line, new_line)
        new_content = Enum.join(new_lines, "\n")

        state = sync_mention_to_buffer(state, new_content, line, new_col)
        update_panel(state, fn p -> %{p | mention_completion: nil} end)
    end
  end

  @spec list_project_files() :: [String.t()]
  defp list_project_files, do: cached_project_files()

  @spec cached_project_files() :: [String.t()]
  defp cached_project_files do
    Minga.Project.files()
  catch
    :exit, _ -> []
  end

  @spec run_search(state(), String.t()) :: state()
  defp run_search(state, query) do
    session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)
    messages = if session, do: safe_messages(session), else: []
    matches = ChatSearch.find_matches(messages, query)
    state = update_agent_ui(state, &UIState.set_search_matches(&1, matches))
    if matches != [], do: scroll_to_current_match(state), else: state
  end

  @spec scroll_to_current_match(state()) :: state()
  defp scroll_to_current_match(state) do
    case state.workspace.agent_ui.view.search do
      nil ->
        state

      search ->
        case Enum.at(search.matches, search.current) do
          nil -> state
          match -> scroll_to_message(state, ChatSearch.match_message_index(match))
        end
    end
  end

  @spec scroll_to_message(state(), non_neg_integer()) :: state()
  defp scroll_to_message(state, msg_idx) do
    session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)
    messages = if session, do: safe_messages(session), else: []

    case Transcript.message_start_line(messages, msg_idx) do
      nil -> state
      line_idx -> update_agent_ui(state, &UIState.set_scroll(&1, line_idx))
    end
  end

  @spec maybe_finish_review(state()) :: state()
  defp maybe_finish_review(state) do
    case Preview.diff_review(state.workspace.agent_ui.view.preview) do
      %DiffReview{} = review ->
        if DiffReview.resolved?(review), do: update_preview(state, &Preview.clear/1), else: state

      nil ->
        state
    end
  end

  @spec revert_hunk(state(), DiffReview.t(), map()) :: :ok | {:error, term()}
  defp revert_hunk(state, review, hunk) do
    case active_project_view(state) do
      %ProjectView{} = project_view -> revert_project_view_hunks(project_view, review, [hunk])
      nil -> revert_hunk_on_disk(review.path, hunk)
    end
  end

  @spec revert_hunks(state(), DiffReview.t(), [map()]) :: :ok | {:error, term()}
  defp revert_hunks(state, review, hunks) do
    case active_project_view(state) do
      %ProjectView{} = project_view -> revert_project_view_hunks(project_view, review, hunks)
      nil -> revert_hunks_on_disk(review.path, hunks)
    end
  end

  @spec active_project_view(state()) :: ProjectView.t() | nil
  defp active_project_view(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tab_bar}}}) do
    case TabBar.active_workspace(tab_bar) do
      %{project_view: %ProjectView{} = project_view} -> project_view
      _workspace -> nil
    end
  end

  defp active_project_view(_state), do: nil

  @spec revert_project_view_hunks(ProjectView.t(), DiffReview.t(), [map()]) ::
          :ok | {:error, term()}
  defp revert_project_view_hunks(%ProjectView{} = project_view, %DiffReview{} = review, hunks) do
    case review_relative_path(project_view, review.path) do
      {:ok, relative_path} ->
        revert_project_view_hunks(project_view, relative_path, review, hunks)

      :outside_project ->
        revert_hunks_on_disk(review.path, hunks)

      {:error, _reason} ->
        :ok
    end
  end

  @spec revert_project_view_hunks(ProjectView.t(), String.t(), DiffReview.t(), [map()]) ::
          :ok | {:error, term()}
  defp revert_project_view_hunks(project_view, relative_path, review, hunks) do
    case project_view_content(project_view, relative_path, review) do
      {:ok, content} ->
        write_reverted_project_view_hunks(project_view, relative_path, content, hunks)

      {:error, _reason} ->
        :ok
    end
  end

  @spec write_reverted_project_view_hunks(ProjectView.t(), String.t(), String.t(), [map()]) ::
          :ok | {:error, term()}
  defp write_reverted_project_view_hunks(project_view, relative_path, content, hunks) do
    reverted =
      hunks
      |> Enum.reduce(String.split(content, "\n"), fn hunk, lines ->
        Git.revert_hunk(lines, hunk)
      end)
      |> Enum.join("\n")

    write_project_view_content(project_view, relative_path, reverted)
  end

  @spec project_view_content(ProjectView.t(), String.t(), DiffReview.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp project_view_content(project_view, relative_path, review) do
    case ProjectView.read_file(project_view, relative_path) do
      {:ok, content} -> {:ok, content}
      {:error, :deleted} -> {:ok, Enum.join(review.after_lines, "\n")}
      {:error, _reason} = error -> error
    end
  end

  @spec write_project_view_content(ProjectView.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  defp write_project_view_content(project_view, relative_path, content) do
    ProjectView.write_file(project_view, relative_path, content)
  end

  @spec review_relative_path(ProjectView.t(), String.t()) ::
          {:ok, String.t()} | :outside_project | {:error, term()}
  defp review_relative_path(%ProjectView{project_root: root}, path) do
    case Path.type(path) do
      :relative -> ProjectView.normalize_relative_path(path)
      :absolute -> absolute_review_relative_path(root, path)
      :volumerelative -> :outside_project
    end
  end

  @spec absolute_review_relative_path(String.t(), String.t()) ::
          {:ok, String.t()} | :outside_project | {:error, term()}
  defp absolute_review_relative_path(root, path) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)

    if String.starts_with?(expanded_path, expanded_root <> "/") do
      ProjectView.normalize_relative_path(Path.relative_to(expanded_path, expanded_root))
    else
      :outside_project
    end
  end

  @spec revert_hunk_on_disk(String.t(), map()) :: :ok
  defp revert_hunk_on_disk(path, hunk) do
    case File.read(path) do
      {:ok, content} ->
        current_lines = String.split(content, "\n")
        reverted = Git.revert_hunk(current_lines, hunk)
        File.write(path, Enum.join(reverted, "\n"))

      {:error, _} ->
        :ok
    end
  end

  @spec revert_hunks_on_disk(String.t(), [map()]) :: :ok
  defp revert_hunks_on_disk(path, hunks) do
    case File.read(path) do
      {:ok, content} ->
        current_lines = String.split(content, "\n")

        reverted =
          Enum.reduce(hunks, current_lines, fn hunk, lines ->
            Git.revert_hunk(lines, hunk)
          end)

        File.write(path, Enum.join(reverted, "\n"))

      {:error, _} ->
        :ok
    end
  end

  @spec safe_messages(pid()) :: [term()]
  defp safe_messages(session) do
    Session.messages(session)
  catch
    :exit, _ -> []
  end

  # ── State update helpers (delegated to AA) ─────────────────────────────────

  @spec update_agent(state(), (AgentState.t() -> AgentState.t())) :: state()
  defp update_agent(state, fun),
    do:
      MingaEditor.Shell.Traditional.Workflow.install_agent_state(
        state,
        fun.(MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state))
      )

  @spec update_agent_ui(state(), (UIState.t() -> UIState.t())) :: state()
  defp update_agent_ui(state, fun),
    do:
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
        state,
        fun.(state.workspace.agent_ui)
      )

  @spec update_preview(state(), (Preview.t() -> Preview.t())) :: state()
  defp update_preview(state, fun) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_view(
      state,
      (fn v ->
         %{v | preview: fun.(v.preview)}
       end).(state.workspace.agent_ui.view)
    )
  end

  @spec sync_mention_to_buffer(state(), String.t(), non_neg_integer(), non_neg_integer()) ::
          state()
  defp sync_mention_to_buffer(state, content, line, col) do
    panel = state.workspace.agent_ui.panel

    if is_pid(panel.prompt_buffer) do
      Buffer.replace_content(panel.prompt_buffer, content)
      Buffer.move_to(panel.prompt_buffer, {line, col})
    end

    state
  end

  @spec update_panel(state(), (Panel.t() -> Panel.t())) :: state()
  defp update_panel(state, fun) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
      state,
      fun.(state.workspace.agent_ui.panel)
    )
  end
end
