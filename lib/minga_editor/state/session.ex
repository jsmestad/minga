defmodule MingaEditor.State.Session do
  @moduledoc """
  Session persistence state for the Editor.

  Groups the Editor's session-related fields into a focused sub-struct:
  the periodic save timer and the directory paths for session files and
  swap files. These are set once at startup and only the timer mutates
  during the Editor's lifetime.

  All mutations go through functions on this module.
  """

  @type pending_quit :: :quit | :quit_all | nil
  @type application_quit_request_id :: 0..0xFFFFFFFF
  @type application_quit_response_outcome ::
          :needs_decision | :proceeding | :cancelled | :save_failed
  @type application_quit_policy_intent :: :inventory | :save | :discard | :cancel
  @type application_quit ::
          :idle
          | {:requesting, application_quit_request_id()}
          | {:awaiting_decision, application_quit_request_id()}
          | {:saving, application_quit_request_id()}
          | {:responding, application_quit_request_id(), application_quit_policy_intent(),
             application_quit_response_outcome()}
          | {:proceeding, application_quit_request_id()}
  @type last_test_command :: {String.t(), String.t()} | nil

  @type t :: %__MODULE__{
          timer: reference() | nil,
          swap_dir: String.t() | nil,
          session_dir: String.t() | nil,
          session_started?: boolean(),
          pending_quit: pending_quit(),
          application_quit: application_quit(),
          last_test_command: last_test_command()
        }

  defstruct timer: nil,
            swap_dir: nil,
            session_dir: nil,
            session_started?: false,
            pending_quit: nil,
            application_quit: :idle,
            last_test_command: nil

  @doc "Creates a new session state from startup options."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      swap_dir: Keyword.get(opts, :swap_dir),
      session_dir: Keyword.get(opts, :session_dir)
    }
  end

  @doc "Latches completion of the one-time editor startup workflow."
  @spec complete_startup(t(), t()) :: t()
  def complete_startup(%__MODULE__{} = current, %__MODULE__{} = started) do
    %{
      started
      | session_started?: true,
        pending_quit: current.pending_quit,
        application_quit: current.application_quit,
        last_test_command: current.last_test_command
    }
  end

  @doc "Requests quit confirmation for the editor or all editor instances."
  @spec request_quit(t(), :quit | :quit_all) :: t()
  def request_quit(%__MODULE__{} = session, request) when request in [:quit, :quit_all],
    do: %{session | pending_quit: request}

  @doc "Clears a completed or canceled quit request."
  @spec clear_quit_request(t()) :: t()
  def clear_quit_request(%__MODULE__{} = session), do: %{session | pending_quit: nil}

  @doc "Begins one correlated native application-quit attempt."
  @spec begin_application_quit(t(), application_quit_request_id()) ::
          {:started | :duplicate | :stale, t()}
  def begin_application_quit(%__MODULE__{application_quit: :idle} = session, request_id)
      when request_id in 0..0xFFFFFFFF,
      do: {:started, %{session | application_quit: {:requesting, request_id}}}

  def begin_application_quit(
        %__MODULE__{application_quit: {_, request_id}} = session,
        request_id
      ),
      do: {:duplicate, session}

  def begin_application_quit(
        %__MODULE__{application_quit: {:responding, request_id, _intent, _outcome}} = session,
        request_id
      ),
      do: {:duplicate, session}

  def begin_application_quit(%__MODULE__{} = session, request_id)
      when request_id in 0..0xFFFFFFFF,
      do: {:stale, session}

  @doc "Moves the matching native quit request to its decision prompt."
  @spec await_application_quit_decision(t(), application_quit_request_id()) :: {:ok, t()} | :stale
  def await_application_quit_decision(
        %__MODULE__{application_quit: {:requesting, request_id}} = session,
        request_id
      ),
      do: {:ok, %{session | application_quit: {:awaiting_decision, request_id}}}

  def await_application_quit_decision(%__MODULE__{}, _request_id), do: :stale

  @doc "Accepts Save for the matching native quit request."
  @spec start_application_quit_save(t(), application_quit_request_id()) :: {:ok, t()} | :stale
  def start_application_quit_save(
        %__MODULE__{application_quit: {:awaiting_decision, request_id}} = session,
        request_id
      ),
      do: {:ok, %{session | application_quit: {:saving, request_id}}}

  def start_application_quit_save(%__MODULE__{}, _request_id), do: :stale

  @doc "Reserves one lifecycle response before attempting nonblocking transport admission."
  @spec prepare_application_quit_response(
          t(),
          application_quit_request_id(),
          application_quit_policy_intent(),
          application_quit_response_outcome()
        ) :: {:ok, t()} | :stale
  def prepare_application_quit_response(
        %__MODULE__{application_quit: {phase, request_id}} = session,
        request_id,
        :inventory,
        :needs_decision
      )
      when phase in [:requesting, :awaiting_decision],
      do:
        {:ok,
         %{session | application_quit: {:responding, request_id, :inventory, :needs_decision}}}

  def prepare_application_quit_response(
        %__MODULE__{application_quit: {:requesting, request_id}} = session,
        request_id,
        :inventory,
        :proceeding
      ),
      do: {:ok, %{session | application_quit: {:responding, request_id, :inventory, :proceeding}}}

  def prepare_application_quit_response(
        %__MODULE__{application_quit: {:saving, request_id}} = session,
        request_id,
        :save,
        :proceeding
      ),
      do: {:ok, %{session | application_quit: {:responding, request_id, :save, :proceeding}}}

  def prepare_application_quit_response(
        %__MODULE__{application_quit: {:awaiting_decision, request_id}} = session,
        request_id,
        :discard,
        :proceeding
      ),
      do: {:ok, %{session | application_quit: {:responding, request_id, :discard, :proceeding}}}

  def prepare_application_quit_response(
        %__MODULE__{application_quit: {:awaiting_decision, request_id}} = session,
        request_id,
        :cancel,
        :cancelled
      ),
      do: {:ok, %{session | application_quit: {:responding, request_id, :cancel, :cancelled}}}

  def prepare_application_quit_response(
        %__MODULE__{application_quit: {:saving, request_id}} = session,
        request_id,
        :save,
        :save_failed
      ),
      do: {:ok, %{session | application_quit: {:responding, request_id, :save, :save_failed}}}

  def prepare_application_quit_response(%__MODULE__{}, _request_id, _intent, _outcome), do: :stale

  @doc "Reopens the policy workflow before retrying an undelivered Proceeding response."
  @spec reconcile_application_quit_proceeding(t(), application_quit_request_id()) ::
          {:inventory | :save | :discard, t()} | :stale
  def reconcile_application_quit_proceeding(
        %__MODULE__{
          application_quit: {:responding, request_id, :inventory, :proceeding}
        } = session,
        request_id
      ),
      do: {:inventory, %{session | application_quit: {:requesting, request_id}}}

  def reconcile_application_quit_proceeding(
        %__MODULE__{application_quit: {:responding, request_id, :save, :proceeding}} = session,
        request_id
      ),
      do: {:save, %{session | application_quit: {:saving, request_id}}}

  def reconcile_application_quit_proceeding(
        %__MODULE__{application_quit: {:responding, request_id, :discard, :proceeding}} = session,
        request_id
      ),
      do: {:discard, session}

  def reconcile_application_quit_proceeding(%__MODULE__{}, _request_id), do: :stale

  @doc "Completes the matching lifecycle response only after transport admission."
  @spec complete_application_quit_response(
          t(),
          application_quit_request_id(),
          application_quit_response_outcome()
        ) :: {:ok, t(), application_quit_policy_intent()} | :stale
  def complete_application_quit_response(
        %__MODULE__{application_quit: {:responding, request_id, intent, :needs_decision}} =
          session,
        request_id,
        :needs_decision
      ),
      do: {:ok, %{session | application_quit: {:awaiting_decision, request_id}}, intent}

  def complete_application_quit_response(
        %__MODULE__{application_quit: {:responding, request_id, intent, :proceeding}} = session,
        request_id,
        :proceeding
      ),
      do: {:ok, %{session | application_quit: {:proceeding, request_id}}, intent}

  def complete_application_quit_response(
        %__MODULE__{application_quit: {:responding, request_id, intent, outcome}} = session,
        request_id,
        outcome
      )
      when outcome in [:cancelled, :save_failed],
      do: {:ok, %{session | application_quit: :idle}, intent}

  def complete_application_quit_response(%__MODULE__{}, _request_id, _outcome), do: :stale

  @doc "Accepts Discard or a clean quit and records that orderly shutdown is proceeding."
  @spec proceed_application_quit(t(), application_quit_request_id()) :: {:ok, t()} | :stale
  def proceed_application_quit(
        %__MODULE__{application_quit: {phase, request_id}} = session,
        request_id
      )
      when phase in [:requesting, :awaiting_decision, :saving],
      do: {:ok, %{session | application_quit: {:proceeding, request_id}}}

  def proceed_application_quit(%__MODULE__{}, _request_id), do: :stale

  @doc "Cancels or fails the matching native quit request and makes retry possible."
  @spec cancel_application_quit(t(), application_quit_request_id()) :: {:ok, t()} | :stale
  def cancel_application_quit(
        %__MODULE__{application_quit: {phase, request_id}} = session,
        request_id
      )
      when phase in [:requesting, :awaiting_decision, :saving],
      do: {:ok, %{session | application_quit: :idle}}

  def cancel_application_quit(
        %__MODULE__{application_quit: {:responding, request_id, _intent, _outcome}} = session,
        request_id
      ),
      do: {:ok, %{session | application_quit: :idle}}

  def cancel_application_quit(%__MODULE__{}, _request_id), do: :stale

  @doc "Remembers the command and project root used by the last test run."
  @spec remember_test_command(t(), last_test_command()) :: t()
  def remember_test_command(%__MODULE__{} = session, command),
    do: %{session | last_test_command: command}

  @doc "Returns keyword options for `Minga.Session` functions."
  @spec session_opts(t()) :: keyword()
  def session_opts(%__MODULE__{session_dir: dir}) do
    [session_dir: dir]
  end

  @doc "Returns keyword options for swap recovery functions."
  @spec swap_opts(t()) :: keyword()
  def swap_opts(%__MODULE__{swap_dir: dir}) do
    [swap_dir: dir]
  end

  # ── Timer intent ───────────────────────────────────────────────────────────

  @session_save_interval_ms 30_000

  @doc "Returns the interval used by the session workflow's periodic save timer."
  @spec timer_interval() :: pos_integer()
  def timer_interval, do: @session_save_interval_ms

  @doc "Returns a pure instruction for starting the periodic save timer."
  @spec start_timer(t()) :: {:start_timer, t()} | {:no_timer, t()}
  def start_timer(%__MODULE__{session_dir: nil} = session), do: {:no_timer, session}
  def start_timer(%__MODULE__{} = session), do: {:start_timer, session}

  @doc "Returns a pure instruction for canceling the save timer."
  @spec cancel_timer(t()) :: {:cancel_timer, t(), reference() | nil}
  def cancel_timer(%__MODULE__{timer: nil} = session), do: {:cancel_timer, session, nil}

  def cancel_timer(%__MODULE__{timer: ref} = session) when is_reference(ref) do
    {:cancel_timer, %{session | timer: nil}, ref}
  end

  @doc "Returns a pure instruction for restarting the save timer."
  @spec restart_timer(t()) :: {:restart_timer, t(), reference() | nil}
  def restart_timer(%__MODULE__{timer: ref} = session) when is_reference(ref),
    do: {:restart_timer, %{session | timer: nil}, ref}

  def restart_timer(%__MODULE__{} = session), do: {:restart_timer, session, nil}

  @doc "Records a timer reference created by the session workflow."
  @spec accept_timer(t(), reference()) :: t()
  def accept_timer(%__MODULE__{} = session, ref) when is_reference(ref),
    do: %{session | timer: ref}

  @doc "Returns true if session persistence is enabled (session_dir is set)."
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{session_dir: nil}), do: false
  def enabled?(%__MODULE__{}), do: true

  @doc "Returns true if swap file recovery is enabled (swap_dir is set)."
  @spec swap_enabled?(t()) :: boolean()
  def swap_enabled?(%__MODULE__{swap_dir: nil}), do: false
  def swap_enabled?(%__MODULE__{}), do: true
end
