defmodule Minga.Editor.Commands.AgentSubStates do
  @moduledoc """
  Agent sub-state command handlers: search, mention completion, diff review, tool approval.

  These handle key input within transient sub-states of the agent scope.
  Extracted from `Commands.Agent` to reduce module size.
  """

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.ChatSearch
  alias Minga.Agent.DiffReview
  alias Minga.Agent.FileMention
  alias Minga.Agent.Session
  alias Minga.Agent.UIState
  alias Minga.Agent.UIState.Panel
  alias Minga.Agent.View.Preview
  alias Minga.Buffer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
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
    saved = UIState.search_saved_scroll(AgentAccess.agent_ui(state))
    state = update_agent_ui(state, &UIState.cancel_search/1)
    if saved, do: update_agent_ui(state, &UIState.set_scroll(&1, saved)), else: state
  end

  def handle_search_key(state, 127) do
    query = UIState.search_query(AgentAccess.agent_ui(state)) || ""

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
    query = (UIState.search_query(AgentAccess.agent_ui(state)) || "") <> char
    state = update_agent_ui(state, &UIState.update_search_query(&1, query))
    run_search(state, query)
  end

  def handle_search_key(state, _cp), do: state

  @doc "Starts search mode in the chat."
  @spec start_search(state()) :: state()
  def start_search(state) do
    scroll = AgentAccess.panel(state).scroll.offset
    update_agent_ui(state, &UIState.start_search(&1, scroll))
  end

  @doc "Jumps to the next search match."
  @spec next_match(state()) :: state()
  def next_match(state) do
    if AgentAccess.view(state).search.input_active do
      state
    else
      state = update_agent_ui(state, &UIState.next_search_match/1)
      scroll_to_current_match(state)
    end
  end

  @doc "Jumps to the previous search match."
  @spec prev_match(state()) :: state()
  def prev_match(state) do
    if AgentAccess.view(state).search.input_active do
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

  def handle_mention_key(state, 13, _mods), do: accept_mention_completion(state)

  def handle_mention_key(state, 27, _mods) do
    update_panel(state, fn p -> %{p | mention_completion: nil} end)
  end

  def handle_mention_key(state, 127, _mods) do
    comp = AgentAccess.panel(state).mention_completion

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

  def handle_mention_key(state, cp, mods)
      when cp >= 32 and band(mods, 0x02) == 0 and band(mods, 0x04) == 0 do
    mention_insert_char(state, <<cp::utf8>>)
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

  @doc "Triggers /slash command completion when / is typed at position (0, 0)."
  @spec trigger_slash_completion(state()) :: state()
  def trigger_slash_completion(state) do
    commands = Minga.Agent.SlashCommand.completions("")

    candidates =
      Enum.map(commands, fn cmd ->
        {cmd.name, cmd.description}
      end)

    if candidates != [] do
      comp = %{
        prefix: "",
        all_files: [],
        candidates: Enum.map(candidates, fn {name, _} -> name end),
        selected: 0,
        anchor_line: 0,
        anchor_col: 0,
        slash_candidates: candidates
      }

      update_panel(state, fn p -> %{p | mention_completion: comp} end)
    else
      state
    end
  end

  # ── Diff review commands ───────────────────────────────────────────────────

  @doc "Accepts the current diff hunk during review."
  @spec accept_hunk(state()) :: state()
  def accept_hunk(state) do
    case AgentAccess.view(state).preview do
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
    case AgentAccess.view(state).preview do
      %Preview{content: {:diff, review}} ->
        hunk = DiffReview.current_hunk(review)
        if hunk, do: revert_hunk_on_disk(review.path, hunk)

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
    case AgentAccess.view(state).preview do
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
    case AgentAccess.view(state).preview do
      %Preview{content: {:diff, review}} ->
        unresolved_hunks =
          review.hunks
          |> Enum.with_index()
          |> Enum.reject(fn {_hunk, idx} -> Map.has_key?(review.resolutions, idx) end)
          |> Enum.map(fn {hunk, _idx} -> hunk end)
          |> Enum.reverse()

        revert_hunks_on_disk(review.path, unresolved_hunks)

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
  def approve_tool(state) do
    agent = AgentAccess.agent(state)
    session = agent.session
    approval = agent.pending_approval

    if is_pid(session) and is_map(approval) do
      Session.respond_to_approval(session, :approve)
      update_agent(state, &AgentState.clear_pending_approval/1)
    else
      state
    end
  end

  @doc "Denies the pending tool execution."
  @spec deny_tool(state()) :: state()
  def deny_tool(state) do
    agent = AgentAccess.agent(state)
    session = agent.session
    approval = agent.pending_approval

    if is_pid(session) and is_map(approval) do
      Session.respond_to_approval(session, :reject)
      update_agent(state, &AgentState.clear_pending_approval/1)
    else
      state
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec mention_insert_char(state(), String.t()) :: state()
  defp mention_insert_char(state, " ") do
    state = update_panel(state, fn p -> %{p | mention_completion: nil} end)
    AgentCommands.input_char(state, " ")
  end

  defp mention_insert_char(state, char) do
    state = AgentCommands.input_char(state, char)
    comp = AgentAccess.panel(state).mention_completion
    new_prefix = comp.prefix <> char

    update_panel(state, fn p ->
      %{p | mention_completion: FileMention.update_prefix(comp, new_prefix)}
    end)
  end

  @spec should_trigger_mention?(state()) :: boolean()
  defp should_trigger_mention?(state) do
    panel = AgentAccess.panel(state)
    {line, col} = UIState.input_cursor(panel)
    current_line = Enum.at(UIState.input_lines(panel), line, "")
    col == 0 or String.at(current_line, col - 1) in [" ", "\t", nil]
  end

  @spec start_mention_completion(state()) :: state()
  defp start_mention_completion(state) do
    files = list_project_files()
    {line, col} = UIState.input_cursor(AgentAccess.panel(state))
    completion = FileMention.new_completion(files, line, col - 1)
    update_panel(state, fn p -> %{p | mention_completion: completion} end)
  end

  @spec accept_mention_completion(state()) :: state()
  defp accept_mention_completion(state) do
    comp = AgentAccess.panel(state).mention_completion

    case FileMention.selected_path(comp) do
      nil ->
        update_panel(state, fn p -> %{p | mention_completion: nil} end)

      path ->
        panel = AgentAccess.panel(state)
        {line, _col} = UIState.input_cursor(panel)
        lines = UIState.input_lines(panel)
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
  defp list_project_files do
    root =
      try do
        case Minga.Project.root() do
          nil -> File.cwd!()
          r -> r
        end
      catch
        :exit, _ -> File.cwd!()
      end

    case Minga.Project.list_files(root) do
      {:ok, paths} -> paths
      {:error, _} -> []
    end
  end

  @spec run_search(state(), String.t()) :: state()
  defp run_search(state, query) do
    session = AgentAccess.session(state)
    messages = if session, do: safe_messages(session), else: []
    matches = ChatSearch.find_matches(messages, query)
    state = update_agent_ui(state, &UIState.set_search_matches(&1, matches))
    if matches != [], do: scroll_to_current_match(state), else: state
  end

  @spec scroll_to_current_match(state()) :: state()
  defp scroll_to_current_match(state) do
    case AgentAccess.view(state).search do
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
    session = AgentAccess.session(state)
    messages = if session, do: safe_messages(session), else: []

    case AgentBufferSync.message_start_line(messages, msg_idx) do
      nil -> state
      line_idx -> update_agent_ui(state, &UIState.set_scroll(&1, line_idx))
    end
  end

  @spec maybe_finish_review(state()) :: state()
  defp maybe_finish_review(state) do
    case Preview.diff_review(AgentAccess.view(state).preview) do
      %DiffReview{} = review ->
        if DiffReview.resolved?(review), do: update_preview(state, &Preview.clear/1), else: state

      nil ->
        state
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
  defp update_agent(state, fun), do: AgentAccess.update_agent(state, fun)

  @spec update_agent_ui(state(), (UIState.t() -> UIState.t())) :: state()
  defp update_agent_ui(state, fun), do: AgentAccess.update_agent_ui(state, fun)

  @spec update_preview(state(), (Preview.t() -> Preview.t())) :: state()
  defp update_preview(state, fun) do
    AgentAccess.update_view(state, fn v ->
      %{v | preview: fun.(v.preview)}
    end)
  end

  @spec sync_mention_to_buffer(state(), String.t(), non_neg_integer(), non_neg_integer()) ::
          state()
  defp sync_mention_to_buffer(state, content, line, col) do
    panel = AgentAccess.panel(state)

    if is_pid(panel.prompt_buffer) do
      Buffer.replace_content(panel.prompt_buffer, content)
      Buffer.move_to(panel.prompt_buffer, {line, col})
    end

    state
  end

  @spec update_panel(state(), (Panel.t() -> Panel.t())) :: state()
  defp update_panel(state, fun) do
    AgentAccess.update_panel(state, fun)
  end
end
