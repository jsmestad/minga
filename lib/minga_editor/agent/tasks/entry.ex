defmodule MingaEditor.Agent.Tasks.Entry do
  @moduledoc """
  One task Minga is working on: an agent session the editor follows, with what it is doing now.

  An entry is the editor's projection of one session's events. It never calls the session; `MingaEditor.Agent.Tasks` installs the transitions below as the session's events arrive, and the tasks drawer and the modeline read the derived `state/2` and `words/2`.

  `subagents` are the foreground subagents the task's `subagent` tool calls started. They live only as long as the tool call and are reported through the parent's tool events. A background subagent is a session of its own, so it is a separate entry whose `parent` names the task that started it.
  """

  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.Tasks.Subagent

  @typedoc "The session status the task last reported."
  @type status :: :idle | :plan | :thinking | :tool_executing | :error | :stopped

  @typedoc """
  Why the task is waiting rather than working or failed.

  `{:retry, at_ms, reason}` while the provider waits to retry a request (`at_ms` is the wall-clock retry time); `{:limit, message}` when the plan's usage limit stopped the task until it resets.
  """
  @type waiting :: {:retry, integer(), String.t()} | {:limit, String.t()}

  @typedoc "The design-token state a task shows, or nil for a task that has not started work."
  @type state :: :needs_you | :working | :waiting | :failed | :done | :stopped

  @type t :: %__MODULE__{
          pid: pid(),
          seq: non_neg_integer(),
          title: String.t() | nil,
          parent: pid() | nil,
          status: status(),
          approval: PendingApproval.t() | nil,
          question: {term(), term()} | nil,
          activity: Activity.t(),
          failure: String.t() | nil,
          waiting: waiting() | nil,
          turns: non_neg_integer(),
          started_at: integer(),
          changed_at: integer(),
          subagents: [Subagent.t()]
        }

  @enforce_keys [:pid, :seq, :started_at, :changed_at]
  defstruct [
    :pid,
    :seq,
    :started_at,
    :changed_at,
    title: nil,
    parent: nil,
    status: :idle,
    approval: nil,
    question: nil,
    activity: %Activity{},
    failure: nil,
    waiting: nil,
    turns: 0,
    subagents: []
  ]

  @working [:thinking, :tool_executing]

  @doc "A task the editor has just started following."
  @spec new(pid(), non_neg_integer(), integer()) :: t()
  def new(pid, seq, now) when is_pid(pid) and is_integer(seq) and is_integer(now),
    do: %__MODULE__{pid: pid, seq: seq, started_at: now, changed_at: now}

  @doc "Names the task by its goal. A task keeps the first goal it is given; renaming goes through `rename/2`."
  @spec name(t(), String.t()) :: t()
  def name(%__MODULE__{title: nil} = entry, title) when is_binary(title) do
    case first_line(title) do
      "" -> entry
      line -> %{entry | title: line}
    end
  end

  def name(%__MODULE__{} = entry, _title), do: entry

  @doc "Replaces the task's title, for an explicit rename."
  @spec rename(t(), String.t()) :: t()
  def rename(%__MODULE__{} = entry, title) when is_binary(title) do
    case first_line(title) do
      "" -> entry
      line -> %{entry | title: line}
    end
  end

  @doc "Records the task that started this one, for a background subagent."
  @spec adopt(t(), pid()) :: t()
  def adopt(%__MODULE__{} = entry, parent) when is_pid(parent), do: %{entry | parent: parent}

  @doc """
  Applies one session event at wall-clock time `now`.

  Events the task does not show are ignored, so the caller can pass every event the session sends.
  """
  @spec observe(t(), term(), integer()) :: t()
  def observe(%__MODULE__{} = entry, event, now) do
    case apply_event(entry, event, now) do
      ^entry -> entry
      changed -> %{changed | changed_at: now}
    end
  end

  @spec apply_event(t(), term(), integer()) :: t()
  defp apply_event(entry, {:status_changed, status}, _now), do: change_status(entry, status)

  defp apply_event(entry, {:display_status_changed, :approval_waiting}, _now), do: entry

  defp apply_event(entry, {:display_status_changed, status}, _now),
    do: change_status(entry, status)

  defp apply_event(entry, {:tool_started, id, name, args}, now) do
    %{
      entry
      | activity: Activity.start_tool(entry.activity, id, name),
        waiting: nil,
        subagents: Subagent.started(entry.subagents, id, name, args, now)
    }
  end

  defp apply_event(entry, {:tool_ended, %MingaAgent.Event.ToolEnd{} = ended}, now) do
    %{
      entry
      | activity: Activity.finish_tool(entry.activity, ended.tool_call_id),
        subagents: Subagent.ended(entry.subagents, ended, now)
    }
  end

  defp apply_event(entry, {:tool_interrupted, id}, now) do
    %{
      entry
      | activity: Activity.finish_tool(entry.activity, id),
        subagents: Subagent.interrupted(entry.subagents, id, now)
    }
  end

  defp apply_event(entry, {:todo_plan_updated, todos}, _now) when is_list(todos),
    do: %{entry | activity: Activity.set_todos(entry.activity, todos)}

  defp apply_event(entry, {:approval_pending, %PublicApproval{} = approval}, _now),
    do: %{entry | approval: PendingApproval.new(entry.pid, approval)}

  defp apply_event(entry, {:approval_resolved, target, _decision}, _now),
    do: resolve_approval(entry, target)

  defp apply_event(entry, {:question_requested, target, question}, _now),
    do: %{entry | question: {target, question}}

  defp apply_event(%__MODULE__{question: {target, _question}} = entry, {event, target}, _now)
       when event in [:question_answered, :question_cancelled, :question_interrupted],
       do: %{entry | question: nil}

  defp apply_event(entry, {:error, message}, _now) when is_binary(message),
    do: %{entry | status: :error, failure: message, waiting: nil}

  defp apply_event(entry, {:model_limit_reached, message}, _now) when is_binary(message),
    do: %{entry | waiting: {:limit, message}}

  defp apply_event(entry, {:retry_scheduled, delay_ms, reason}, now)
       when is_integer(delay_ms) and is_binary(reason),
       do: %{entry | waiting: {:retry, now + delay_ms, reason}}

  defp apply_event(entry, _event, _now), do: entry

  @doc "Clears the approval this task is waiting on when `target` names it."
  @spec resolve_approval(t(), MingaAgent.ToolApproval.Target.t()) :: t()
  def resolve_approval(
        %__MODULE__{approval: %PendingApproval{approval: %PublicApproval{target: target}}} =
          entry,
        target
      ),
      do: %{entry | approval: nil}

  def resolve_approval(%__MODULE__{} = entry, _target), do: entry

  @doc "Marks the task stopped: its session ended or the user stopped it."
  @spec stop(t(), integer()) :: t()
  def stop(%__MODULE__{} = entry, now),
    do: %{entry | status: :stopped, approval: nil, question: nil, waiting: nil, changed_at: now}

  @spec change_status(t(), term()) :: t()
  defp change_status(%__MODULE__{status: old} = entry, :idle) when old in @working do
    %{
      entry
      | status: :idle,
        turns: entry.turns + 1,
        activity: Activity.finish_turn(entry.activity),
        waiting: nil
    }
  end

  defp change_status(entry, status) when status in @working do
    %{
      entry
      | status: status,
        failure: nil,
        activity: Activity.apply_status(entry.activity, status)
    }
  end

  defp change_status(entry, :error), do: %{entry | status: :error, waiting: nil}

  defp change_status(entry, status) when status in [:idle, :plan, :stopped],
    do: %{entry | status: status}

  defp change_status(entry, _status), do: entry

  @doc """
  The state the task shows, derived in one place so the drawer, the modeline and notifications agree.

  An open approval needs you before anything else; a retry or a usage limit is waiting, not failed; a finished turn is done.
  """
  @spec state(t()) :: state() | nil
  def state(%__MODULE__{approval: %PendingApproval{}}), do: :needs_you
  def state(%__MODULE__{question: {_target, _question}}), do: :needs_you
  def state(%__MODULE__{status: :stopped}), do: :stopped
  def state(%__MODULE__{waiting: {_kind, _detail}}), do: :waiting
  def state(%__MODULE__{waiting: {_kind, _at, _reason}}), do: :waiting
  def state(%__MODULE__{status: :error}), do: :failed
  def state(%__MODULE__{status: status}) when status in @working, do: :working
  def state(%__MODULE__{turns: turns}) when turns > 0, do: :done
  def state(%__MODULE__{}), do: nil

  @doc "The task's title, or the words a task without a goal shows."
  @spec title(t()) :: String.t()
  def title(%__MODULE__{title: nil}), do: "New task"
  def title(%__MODULE__{title: title}), do: title

  @doc """
  What the task is doing, in words, after its state word: "Editing chrome_state.ex · step 2 of 3", "Waiting · rate limited, retry in 40 s".

  `now` is the wall-clock time the words are for, so a retry counts down.
  """
  @spec words(t(), integer()) :: String.t()
  def words(%__MODULE__{} = entry, now) when is_integer(now) do
    entry
    |> state()
    |> state_words(entry, now)
  end

  @spec state_words(state() | nil, t(), integer()) :: String.t()
  defp state_words(:needs_you, %__MODULE__{approval: nil}, _now),
    do: join([word(:needs_you), "has a question"])

  defp state_words(:needs_you, entry, _now),
    do: join([word(:needs_you), request_words(entry.approval)])

  defp state_words(:working, entry, _now),
    do: join([entry.activity.active_action, step_words(Activity.progress(entry.activity))])

  defp state_words(:waiting, %__MODULE__{waiting: {:retry, at, reason}}, now),
    do: join([word(:waiting), "#{retry_reason(reason)}, retry in #{seconds_until(at, now)} s"])

  defp state_words(:waiting, %__MODULE__{waiting: {:limit, message}}, _now),
    do: join([word(:waiting), message])

  defp state_words(:failed, entry, _now), do: join([word(:failed), entry.failure])
  defp state_words(:stopped, _entry, _now), do: word(:stopped)
  defp state_words(:done, _entry, _now), do: word(:done)
  defp state_words(nil, _entry, _now), do: "Ready"

  @spec request_words(PendingApproval.t()) :: String.t()
  defp request_words(%PendingApproval{approval: %PublicApproval{preview: preview}}),
    do: "wants to " <> lower_first(preview.summary)

  # The provider's reason is a status or an error message; the drawer names the common one in words.
  @spec retry_reason(String.t()) :: String.t()
  defp retry_reason(reason) do
    if Regex.match?(~r/\b429\b|rate.?limit/i, reason), do: "rate limited", else: reason
  end

  @spec step_words({non_neg_integer(), pos_integer()} | nil) :: String.t() | nil
  defp step_words({step, steps}), do: "step #{max(step, 1)} of #{steps}"
  defp step_words(nil), do: nil

  @spec word(state()) :: String.t()
  defp word(state), do: Minga.Design.Tokens.state_word(state)

  @spec join([String.t() | nil]) :: String.t()
  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

  @spec seconds_until(integer(), integer()) :: non_neg_integer()
  defp seconds_until(at, now), do: max(0, div(at - now + 999, 1000))

  @spec lower_first(String.t()) :: String.t()
  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower_first(""), do: ""

  @spec first_line(String.t()) :: String.t()
  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd() |> String.trim()
end
