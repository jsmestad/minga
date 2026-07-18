defmodule MingaAgent.Session.SubscriberLifecycle do
  @moduledoc """
  Owns subscriber roles, monitor identity, and detached-session reclamation.

  Session performs every process and timer effect. This value validates the operation, returns the next lifecycle or a named preparation, and accepts the resulting OTP reference through a completion transition.

  ## Transition table

  | Command | Valid source | Result |
  |---|---|---|
  | subscribe | valid role, PID absent | monitor preparation |
  | complete subscribe | unchanged preparation source | attachment installed, prior timer returned for cancellation |
  | claim driver | attached PID, driver vacant or same PID | role transition |
  | detach | attached PID | attachment removed with monitor cleanup identity |
  | DOWN | matching PID and monitor reference | attachment removed |
  | reconcile reclaim | detached and turn reclaimable | timer preparation or unchanged |
  | complete reclaim schedule | unchanged preparation source | exact OTP timer reference installed |
  | reclaim timeout | matching timer, detached, turn reclaimable | reclaim accepted |
  | stop | any | empty lifecycle plus ordered timer and monitor cleanup identity |
  """

  alias MingaAgent.Session.SubscriberAttachment

  @typedoc "Remote attachment role."
  @type role :: SubscriberAttachment.role()

  @typedoc "Subscriber lifecycle state."
  @type t :: %__MODULE__{
          attachments: %{pid() => SubscriberAttachment.t()},
          reclaim_timer: reference() | nil
        }

  @typedoc "A validated subscription awaiting monitor creation."
  @type subscription_preparation :: {source :: t(), pid(), role()}

  @typedoc "Role outcome produced by installing a new subscriber."
  @type subscription_change :: :driver_initialized | :driver_changed | :viewer_attached

  @typedoc "A validated reclaim schedule awaiting timer creation."
  @type reclaim_preparation :: t()

  defstruct attachments: %{}, reclaim_timer: nil

  @doc "Builds an empty detached lifecycle."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns all attached subscriber PIDs."
  @spec subscribers(t()) :: [pid()]
  def subscribers(%__MODULE__{attachments: attachments}), do: Map.keys(attachments)

  @doc "Returns the role for an attached subscriber."
  @spec role(t(), pid()) :: role() | nil
  def role(%__MODULE__{attachments: attachments}, pid) when is_pid(pid) do
    case Map.get(attachments, pid) do
      %SubscriberAttachment{role: role} -> role
      nil -> nil
    end
  end

  @doc "Returns the active driver derived from canonical attachment roles."
  @spec driver(t()) :: pid() | nil
  def driver(%__MODULE__{attachments: attachments}) do
    Enum.find_value(attachments, fn
      {pid, %SubscriberAttachment{role: :driver}} -> pid
      {_pid, %SubscriberAttachment{role: :viewer}} -> nil
    end)
  end

  @doc "Returns the default role for a new subscriber."
  @spec default_role(t()) :: role()
  def default_role(%__MODULE__{} = lifecycle) do
    case driver(lifecycle) do
      nil -> :driver
      _pid -> :viewer
    end
  end

  @doc "Returns true when the PID owns the driver role."
  @spec driver?(t(), pid()) :: boolean()
  def driver?(%__MODULE__{} = lifecycle, pid) when is_pid(pid), do: driver(lifecycle) == pid

  @doc "Returns the installed reclaim timer reference."
  @spec reclaim_timer(t()) :: reference() | nil
  def reclaim_timer(%__MODULE__{reclaim_timer: timer_ref}), do: timer_ref

  @doc "Validates a subscription before Session creates its process monitor."
  @spec prepare_subscribe(t(), pid(), term()) ::
          {:monitor, subscription_preparation()}
          | {:already_attached, t()}
          | {:error, :invalid_role}
  def prepare_subscribe(%__MODULE__{} = lifecycle, pid, role)
      when is_pid(pid) and role in [:driver, :viewer] do
    prepare_subscribe(lifecycle, pid, role, Map.has_key?(lifecycle.attachments, pid))
  end

  def prepare_subscribe(%__MODULE__{}, pid, _role) when is_pid(pid),
    do: {:error, :invalid_role}

  @doc "Installs a subscription monitor when the validated source is still current."
  @spec complete_subscribe(t(), subscription_preparation(), reference()) ::
          {:ok, t(), subscription_change(), timer_to_cancel :: reference() | nil}
          | {:error, :stale_preparation | :already_attached | :driver_taken}
  def complete_subscribe(
        %__MODULE__{} = lifecycle,
        {%__MODULE__{} = source, pid, role},
        monitor_ref
      )
      when is_pid(pid) and role in [:driver, :viewer] and is_reference(monitor_ref) do
    complete_subscribe(lifecycle, source, pid, role, monitor_ref)
  end

  @doc "Claims a vacant driver role for an attached subscriber."
  @spec claim_driver(t(), pid()) ::
          {:changed, t()} | :unchanged | {:error, :driver_taken | :not_subscribed}
  def claim_driver(%__MODULE__{} = lifecycle, pid) when is_pid(pid) do
    case Map.get(lifecycle.attachments, pid) do
      nil ->
        {:error, :not_subscribed}

      %SubscriberAttachment{role: :driver} ->
        :unchanged

      %SubscriberAttachment{} = attachment ->
        claim_vacant_driver(lifecycle, pid, attachment, driver(lifecycle))
    end
  end

  @doc "Detaches a subscriber and returns its monitor identity for cleanup."
  @spec detach(t(), pid()) :: {:removed, t(), SubscriberAttachment.t()} | :unchanged
  def detach(%__MODULE__{} = lifecycle, pid) when is_pid(pid) do
    case Map.pop(lifecycle.attachments, pid) do
      {nil, _attachments} ->
        :unchanged

      {%SubscriberAttachment{} = attachment, attachments} ->
        {:removed, %{lifecycle | attachments: attachments}, attachment}
    end
  end

  @doc "Consumes a subscriber DOWN only when both PID and monitor identity match."
  @spec subscriber_down(t(), pid(), reference()) ::
          {:removed, t(), SubscriberAttachment.t()} | {:error, :stale_monitor}
  def subscriber_down(%__MODULE__{} = lifecycle, pid, monitor_ref)
      when is_pid(pid) and is_reference(monitor_ref) do
    case Map.get(lifecycle.attachments, pid) do
      %SubscriberAttachment{monitor_ref: ^monitor_ref} = attachment ->
        {:removed, next} = remove_attachment(lifecycle, pid)
        {:removed, next, attachment}

      %SubscriberAttachment{} ->
        {:error, :stale_monitor}

      nil ->
        {:error, :stale_monitor}
    end
  end

  @doc "Reconciles the installed reclaim timer with attachment and turn eligibility."
  @spec reconcile_reclaim(t(), boolean(), boolean()) ::
          {:start_timer, reclaim_preparation()}
          | {:cancel_timer, reference(), t()}
          | :unchanged
  def reconcile_reclaim(%__MODULE__{} = lifecycle, enabled?, turn_reclaimable?)
      when is_boolean(enabled?) and is_boolean(turn_reclaimable?) do
    reconcile_reclaim(lifecycle, reclaim_eligible?(lifecycle, enabled?, turn_reclaimable?))
  end

  @doc "Installs an OTP reclaim timer when the validated source is still current."
  @spec complete_reclaim_schedule(t(), reclaim_preparation(), reference()) ::
          {:ok, t()}
          | {:error, :stale_preparation | :timer_already_installed | :subscriber_attached}
  def complete_reclaim_schedule(
        %__MODULE__{} = lifecycle,
        %__MODULE__{} = source,
        timer_ref
      )
      when is_reference(timer_ref) do
    complete_reclaim_schedule(lifecycle, source, timer_ref, lifecycle == source)
  end

  @doc "Accepts only the installed timer identity and rechecks reclaim eligibility."
  @spec reclaim_timeout(t(), reference(), boolean()) ::
          {:reclaim, t()} | {:keep, t()} | {:error, :stale_timer}
  def reclaim_timeout(
        %__MODULE__{reclaim_timer: timer_ref} = lifecycle,
        timer_ref,
        turn_reclaimable?
      )
      when is_reference(timer_ref) and is_boolean(turn_reclaimable?) do
    next = %{lifecycle | reclaim_timer: nil}
    reclaim_after_timeout(next, map_size(lifecycle.attachments) == 0 and turn_reclaimable?)
  end

  def reclaim_timeout(%__MODULE__{}, timer_ref, turn_reclaimable?)
      when is_reference(timer_ref) and is_boolean(turn_reclaimable?),
      do: {:error, :stale_timer}

  @doc "Clears lifecycle ownership and returns timer then monitor cleanup identities."
  @spec stop(t()) :: {t(), timer_ref :: reference() | nil, monitor_refs :: [reference()]}
  def stop(%__MODULE__{} = lifecycle) do
    monitor_refs =
      Enum.map(lifecycle.attachments, fn {_pid, attachment} -> attachment.monitor_ref end)

    {new(), lifecycle.reclaim_timer, monitor_refs}
  end

  @spec prepare_subscribe(t(), pid(), role(), boolean()) ::
          {:monitor, subscription_preparation()} | {:already_attached, t()}
  defp prepare_subscribe(lifecycle, _pid, _role, true),
    do: {:already_attached, lifecycle}

  defp prepare_subscribe(lifecycle, pid, role, false),
    do: {:monitor, {lifecycle, pid, effective_role(lifecycle, role)}}

  @spec reclaim_after_timeout(t(), boolean()) :: {:reclaim, t()} | {:keep, t()}
  defp reclaim_after_timeout(lifecycle, true), do: {:reclaim, lifecycle}
  defp reclaim_after_timeout(lifecycle, false), do: {:keep, lifecycle}

  @spec effective_role(t(), role()) :: role()
  defp effective_role(lifecycle, :driver) do
    case driver(lifecycle) do
      nil -> :driver
      _pid -> :viewer
    end
  end

  defp effective_role(_lifecycle, :viewer), do: :viewer

  @spec complete_subscribe(t(), t(), pid(), role(), reference()) ::
          {:ok, t(), subscription_change(), reference() | nil}
          | {:error, :stale_preparation | :already_attached | :driver_taken}
  defp complete_subscribe(lifecycle, source, _pid, _role, _monitor_ref)
       when lifecycle != source,
       do: {:error, :stale_preparation}

  defp complete_subscribe(%{attachments: attachments}, _source, pid, _role, _monitor_ref)
       when is_map_key(attachments, pid),
       do: {:error, :already_attached}

  defp complete_subscribe(lifecycle, _source, pid, :driver, monitor_ref) do
    case driver(lifecycle) do
      nil -> install_attachment(lifecycle, pid, :driver, monitor_ref)
      _pid -> {:error, :driver_taken}
    end
  end

  defp complete_subscribe(lifecycle, _source, pid, :viewer, monitor_ref),
    do: install_attachment(lifecycle, pid, :viewer, monitor_ref)

  @spec install_attachment(t(), pid(), role(), reference()) ::
          {:ok, t(), subscription_change(), reference() | nil}
  defp install_attachment(lifecycle, pid, role, monitor_ref) do
    attachment = SubscriberAttachment.new(pid, role, monitor_ref)

    next = %{
      lifecycle
      | attachments: Map.put(lifecycle.attachments, pid, attachment),
        reclaim_timer: nil
    }

    {:ok, next, subscription_change(lifecycle, role), lifecycle.reclaim_timer}
  end

  @spec subscription_change(t(), role()) :: subscription_change()
  defp subscription_change(%{attachments: attachments}, :driver)
       when map_size(attachments) == 0,
       do: :driver_initialized

  defp subscription_change(_lifecycle, :driver), do: :driver_changed
  defp subscription_change(_lifecycle, :viewer), do: :viewer_attached

  @spec claim_vacant_driver(t(), pid(), SubscriberAttachment.t(), pid() | nil) ::
          {:changed, t()} | {:error, :driver_taken}
  defp claim_vacant_driver(lifecycle, pid, attachment, nil) do
    attachments =
      Map.put(lifecycle.attachments, pid, SubscriberAttachment.assign_role(attachment, :driver))

    {:changed, %{lifecycle | attachments: attachments}}
  end

  defp claim_vacant_driver(_lifecycle, _pid, _attachment, _driver),
    do: {:error, :driver_taken}

  @spec remove_attachment(t(), pid()) :: {:removed, t()}
  defp remove_attachment(lifecycle, pid) do
    {:removed, %{lifecycle | attachments: Map.delete(lifecycle.attachments, pid)}}
  end

  @spec reconcile_reclaim(t(), boolean()) ::
          {:start_timer, reclaim_preparation()}
          | {:cancel_timer, reference(), t()}
          | :unchanged
  defp reconcile_reclaim(%{reclaim_timer: nil} = lifecycle, true),
    do: {:start_timer, lifecycle}

  defp reconcile_reclaim(%{reclaim_timer: timer_ref} = lifecycle, false)
       when is_reference(timer_ref),
       do: {:cancel_timer, timer_ref, %{lifecycle | reclaim_timer: nil}}

  defp reconcile_reclaim(_lifecycle, _eligible?), do: :unchanged

  @spec reclaim_eligible?(t(), boolean(), boolean()) :: boolean()
  defp reclaim_eligible?(lifecycle, enabled?, turn_reclaimable?) do
    enabled? and map_size(lifecycle.attachments) == 0 and turn_reclaimable?
  end

  @spec complete_reclaim_schedule(t(), t(), reference(), boolean()) ::
          {:ok, t()}
          | {:error, :stale_preparation | :timer_already_installed | :subscriber_attached}
  defp complete_reclaim_schedule(_lifecycle, _source, _timer_ref, false),
    do: {:error, :stale_preparation}

  defp complete_reclaim_schedule(%{reclaim_timer: timer_ref}, _source, _new_ref, true)
       when is_reference(timer_ref),
       do: {:error, :timer_already_installed}

  defp complete_reclaim_schedule(%{attachments: attachments}, _source, _timer_ref, true)
       when map_size(attachments) > 0,
       do: {:error, :subscriber_attached}

  defp complete_reclaim_schedule(lifecycle, _source, timer_ref, true),
    do: {:ok, %{lifecycle | reclaim_timer: timer_ref}}
end
