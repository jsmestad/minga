defmodule R0.Receipt do
  @moduledoc "Assertion receipts and bounded message waits for this disposable experiment."
  @type label :: String.t()
  @spec log(label(), term()) :: :ok
  def log(id, value),
    do:
      IO.puts("#{id} #{inspect(value, limit: :infinity, printable_limit: :infinity, width: 200)}")

  @spec equal(label(), value, value) :: value when value: var
  def equal(id, actual, expected) do
    if actual != expected,
      do: raise("#{id}: expected #{inspect(expected)}, got #{inspect(actual)}")

    log(id, %{assertion: :pass, observed: actual})
    actual
  end

  @spec await(term()) :: :ok
  def await(pattern) do
    receive do
      ^pattern -> :ok
    after
      5000 -> raise "barrier missing: #{inspect(pattern)}"
    end
  end
end

defmodule R0.Gate do
  @moduledoc "Host-owned pre-helper barrier used to control callback ordering."
  @type context :: %{required(:barrier) => boolean(), optional(atom()) => term()}
  @spec before_helper(context()) :: :ok
  # A supported host-owned barrier. Definition code creates no worker or closure.
  def before_helper(%{barrier: true, harness: harness, operation: op}) do
    send(harness, {:before_helper, op, self()})

    receive do
      {:continue, ^op} -> :ok
    after
      5000 -> raise "helper barrier not released"
    end
  end

  def before_helper(_), do: :ok
end

defmodule R0.Artifact do
  @moduledoc "Prepared three-module artifacts and non-destructive OTP batch installation."
  @type revision :: :v1 | :v2 | :rejected | :v3
  @type beam :: %{module: module(), path: String.t(), binary: binary(), md5: binary()}
  @type t :: %{revision: revision(), source: atom(), binaries: [beam()]}
  @type fingerprint :: [{module(), String.t()}]
  @modules [R0Definition.Helper, R0Definition.Left, R0Definition.Right]
  @spec modules() :: [module()]
  def modules, do: @modules
  @spec read(String.t(), revision()) :: t()
  def read(root, revision) do
    binaries =
      for module <- @modules do
        path =
          Path.join([
            root,
            "artifacts",
            Atom.to_string(revision),
            Atom.to_string(module) <> ".beam"
          ])

        binary = File.read!(path)
        {:ok, {^module, md5}} = :beam_lib.md5(binary)
        %{module: module, path: path, binary: binary, md5: md5}
      end

    %{revision: revision, source: :fixture_source, binaries: binaries}
  end

  @spec fingerprint(t()) :: fingerprint()
  def fingerprint(artifact) do
    for item <- artifact.binaries, do: {item.module, Base.encode16(item.md5, case: :lower)}
  end

  @spec current() :: fingerprint()
  def current do
    for module <- @modules, do: {module, Base.encode16(module.module_info(:md5), case: :lower)}
  end

  @spec batch(t(), (-> term())) :: :ok
  def batch(artifact, gate \\ fn -> :ok end) do
    for item <- artifact.binaries do
      true = :code.soft_purge(item.module)
    end

    inventory =
      for item <- artifact.binaries, do: {item.module, String.to_charlist(item.path), item.binary}

    {:ok, prepared} = :code.prepare_loading(inventory)
    gate.()
    :ok = :code.finish_loading(prepared)
    R0.Receipt.equal("OTP_BATCH_#{artifact.revision}", current(), fingerprint(artifact))
    :ok
  end
end

defmodule R0.Installer do
  @moduledoc "One host-owned installation attempt surviving admission-owner death."
  @type phase :: :before_install | :after_install | :during_restoration | :after_accept
  @type outcome ::
          :accepted
          | :restored
          | :owner_dead_before_install
          | :owner_dead_after_install
          | :owner_dead_during_restoration
          | :owner_dead_after_accept
  @spec run(pid(), pid(), pid(), reference(), R0.Artifact.t(), R0.Artifact.t(), phase() | nil) ::
          {:installer_done, reference(), pid(), outcome()}
  def run(owner, ledger, harness, token, candidate, accepted, pause_at) do
    monitor = Process.monitor(owner)
    receive do: (:start -> :ok)
    pause(ledger, harness, token, :before_install, pause_at)

    outcome =
      if Process.alive?(owner) do
        :ok = R0.Artifact.batch(candidate)
        Agent.update(ledger, &%{&1 | current: candidate})
        pause(ledger, harness, token, :after_install, pause_at)
        settle(owner, ledger, harness, token, candidate, accepted, pause_at)
      else
        :owner_dead_before_install
      end

    Process.demonitor(monitor, [:flush])

    Agent.update(ledger, fn state ->
      phase = if outcome in [:accepted, :restored], do: :idle, else: :interrupted
      %{state | phase: phase, installer_done: true, outcome: outcome}
    end)

    send(harness, {:installer_done, token, self(), outcome})
  end

  @spec settle(pid(), pid(), pid(), reference(), R0.Artifact.t(), R0.Artifact.t(), phase() | nil) ::
          outcome()
  defp settle(owner, ledger, harness, token, candidate, accepted, pause_at) do
    if Process.alive?(owner) do
      valid = R0Definition.Helper.valid?()

      R0.Receipt.log("GLOBAL_DEFINITION_VALIDATION", %{revision: candidate.revision, valid: valid})

      if valid do
        :ok = GenServer.call(owner, {:accept, token, candidate})
        pause(ledger, harness, token, :after_accept, pause_at)

        if Process.alive?(owner) do
          :ok = GenServer.call(owner, {:ack, token})
          :accepted
        else
          :owner_dead_after_accept
        end
      else
        Agent.update(ledger, &%{&1 | phase: :restoring})

        :ok =
          R0.Artifact.batch(accepted, fn ->
            pause(ledger, harness, token, :during_restoration, pause_at)
          end)

        Agent.update(ledger, &%{&1 | current: accepted})

        if Process.alive?(owner) do
          :ok = GenServer.call(owner, {:restored, token})
          :restored
        else
          :owner_dead_during_restoration
        end
      end
    else
      :owner_dead_after_install
    end
  end

  @spec pause(pid(), pid(), reference(), phase(), phase() | nil) :: :ok | nil
  defp pause(ledger, harness, token, phase, pause_at) do
    Agent.update(ledger, &%{&1 | phase: phase})

    R0.Receipt.log("PHASE", %{
      phase: phase,
      token: token,
      installer: self(),
      executable: R0.Artifact.current()
    })

    if phase == pause_at do
      send(harness, {:phase, token, phase, self()})

      receive do
        {:continue, ^token, ^phase} -> :ok
      after
        5000 -> raise "installer barrier not released"
      end
    end
  end
end

defmodule R0.Owner do
  @moduledoc "Prototype callback admission, per-instance usability and result publication."
  use GenServer
  @type instance_id :: :modern | :legacy
  @type model :: %{schema: pos_integer(), n: integer(), kind: instance_id()}
  @type instance :: %{
          data: model(),
          status: :usable | :unavailable,
          attempted: R0.Artifact.revision()
        }
  @type request :: %{
          source: atom(),
          revision: R0.Artifact.revision(),
          entry: module(),
          instance: instance_id(),
          input: integer(),
          input_identity: reference(),
          barrier: boolean()
        }
  @type envelope :: %{
          source: atom(),
          revision: R0.Artifact.revision(),
          entry: module(),
          instance: instance_id(),
          input: integer(),
          input_identity: reference(),
          barrier: boolean(),
          operation: reference(),
          epoch: reference()
        }
  @type computation ::
          {:ok, model(), {R0.Artifact.revision(), R0.Artifact.revision(), integer()}}
          | {:error, :legacy_schema}
  @type publication :: {:published, computation()} | {:error, atom()}
  @type state :: %{
          ledger: pid(),
          harness: pid(),
          phase: :open | :unavailable | :draining | :installing | :settled,
          accepted: R0.Artifact.t() | nil,
          models: %{instance_id() => instance()},
          epoch: reference(),
          active: map(),
          pending: %{reference() => {envelope(), computation()}},
          attempt: map() | nil
        }
  @spec start(pid(), pid()) :: GenServer.on_start()
  def start(ledger, harness), do: GenServer.start(__MODULE__, {ledger, harness})
  @impl true
  @spec init({pid(), pid()}) :: {:ok, state()}
  def init({ledger, harness}) do
    provenance = Agent.get(ledger, & &1)
    # No boot-from-empty path. Only an acknowledged, quiescent, matching artifact opens.
    installer_stopped =
      provenance != nil and
        (provenance.installer == nil or not Process.alive?(provenance.installer))

    open =
      provenance != nil and provenance.phase == :idle and provenance.installer_done and
        installer_stopped and provenance.acknowledged and
        R0.Artifact.current() == R0.Artifact.fingerprint(provenance.accepted)

    models = if provenance, do: provenance.models, else: %{}

    {:ok,
     %{
       ledger: ledger,
       harness: harness,
       phase: if(open, do: :open, else: :unavailable),
       accepted: if(provenance, do: provenance.accepted, else: nil),
       models: models,
       epoch: make_ref(),
       active: %{},
       pending: %{},
       attempt: nil
     }}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call(:state, _, state), do: {:reply, state, state}

  def handle_call({:invoke, request}, _, %{phase: :open} = state) do
    model = Map.fetch!(state.models, request.instance)

    case {request.source == state.accepted.source, request.revision == state.accepted.revision,
          model.status == :unavailable and model.attempted == state.accepted.revision} do
      {true, true, false} ->
        operation = make_ref()
        envelope = Map.merge(request, %{operation: operation, epoch: state.epoch})
        owner = self()

        {pid, monitor} =
          spawn_monitor(fn ->
            context = Map.merge(envelope, %{harness: state.harness})

            result =
              case R0Definition.Left.upgrade(model.data) do
                {:ok, upgraded} ->
                  {:ok, upgraded, apply(request.entry, :run, [upgraded, request.input, context])}

                {:error, reason} ->
                  {:error, reason}
              end

            send(owner, {:computed, envelope, result})
          end)

        active =
          Map.put(state.active, operation, %{pid: pid, monitor: monitor, envelope: envelope})

        {:reply, {:ok, envelope, pid}, %{state | active: active}}

      {false, _, _} ->
        {:reply, {:error, :wrong_source}, state}

      {_, false, _} ->
        {:reply, {:error, :stale_request}, state}

      _ ->
        {:reply, {:error, :instance_unavailable}, state}
    end
  end

  def handle_call({:invoke, _}, _, state), do: {:reply, {:error, state.phase}, state}

  def handle_call({:publish, envelope, result}, _, state) do
    pending = Map.get(state.pending, envelope.operation)

    valid =
      pending == {envelope, result} and envelope.epoch == state.epoch and
        state.phase == :open and envelope.source == state.accepted.source and
        envelope.revision == state.accepted.revision

    if valid do
      instance = Map.fetch!(state.models, envelope.instance)

      updated =
        case result do
          {:ok, data, _} ->
            %{instance | data: data, status: :usable, attempted: envelope.revision}

          {:error, _} ->
            %{instance | status: :unavailable, attempted: envelope.revision}
        end

      models = Map.put(state.models, envelope.instance, updated)
      Agent.update(state.ledger, &%{&1 | models: models})

      {:reply, {:published, result},
       %{state | models: models, pending: Map.delete(state.pending, envelope.operation)}}
    else
      {:reply, {:error, :stale_or_uncorrelated}, state}
    end
  end

  def handle_call({:update, candidate, bound, pause_at}, _, %{phase: :open} = state) do
    inventory = Enum.map(candidate.binaries, & &1.module)

    if candidate.source != state.accepted.source or inventory != R0.Artifact.modules() do
      {:reply, {:error, :source_module_collision}, state}
    else
      token = make_ref()
      timer = Process.send_after(self(), {:drain_bound, token}, bound)
      attempt = %{token: token, candidate: candidate, timer: timer, pause_at: pause_at}
      Agent.update(state.ledger, &%{&1 | phase: :draining, attempt: token, acknowledged: false})
      state = %{state | phase: :draining, attempt: attempt}
      {:reply, {:ok, token}, maybe_install(state)}
    end
  end

  def handle_call({:update, _, _, _}, _, state), do: {:reply, {:error, state.phase}, state}

  def handle_call(
        {:accept, token, candidate},
        _,
        %{phase: :installing, attempt: %{token: token}} = state
      ) do
    Agent.update(state.ledger, &%{&1 | accepted: candidate, phase: :accepted_unacked})
    {:reply, :ok, %{state | accepted: candidate}}
  end

  def handle_call({operation, token}, _, %{phase: :installing, attempt: %{token: token}} = state)
      when operation in [:ack, :restored] do
    Agent.update(state.ledger, &%{&1 | acknowledged: true})
    # Admission opens only after the installer has terminated, handled by :DOWN.
    {:reply, :ok, %{state | phase: :settled}}
  end

  def handle_call({operation, _}, _, state) when operation in [:ack, :restored],
    do: {:reply, {:error, :obsolete_attempt}, state}

  def handle_call({:accept, _, _}, _, state), do: {:reply, {:error, :obsolete_attempt}, state}
  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:computed, envelope, result}, state) do
    case Map.get(state.active, envelope.operation) do
      %{envelope: ^envelope} ->
        send(state.harness, {:queued_result, envelope, result})

        {:noreply,
         %{state | pending: Map.put(state.pending, envelope.operation, {envelope, result})}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case Enum.find(state.active, fn {_, item} -> item.monitor == monitor and item.pid == pid end) do
      {operation, _} ->
        if reason != :normal, do: raise("callback failed: #{inspect(reason)}")
        {:noreply, maybe_install(%{state | active: Map.delete(state.active, operation)})}

      nil ->
        if state.phase == :settled and state.attempt.installer == pid and
             state.attempt.monitor == monitor and reason == :normal do
          send(state.harness, {:owner_open, state.attempt.token, state.accepted.revision})
          {:noreply, %{state | phase: :open, attempt: nil}}
        else
          {:noreply, %{state | phase: :unavailable}}
        end
    end
  end

  def handle_info({:drain_bound, token}, %{phase: :draining, attempt: %{token: token}} = state) do
    Agent.update(state.ledger, &%{&1 | phase: :idle, acknowledged: true, attempt: nil})
    send(state.harness, {:drain_rejected, token})
    {:noreply, %{state | phase: :open, attempt: nil}}
  end

  def handle_info({:drain_bound, _}, state), do: {:noreply, state}
  @spec maybe_install(state()) :: state()
  defp maybe_install(%{phase: :draining, active: active} = state) when map_size(active) == 0 do
    attempt = state.attempt
    Process.cancel_timer(attempt.timer)
    owner = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        R0.Installer.run(
          owner,
          state.ledger,
          state.harness,
          attempt.token,
          attempt.candidate,
          state.accepted,
          attempt.pause_at
        )
      end)

    Agent.update(state.ledger, &%{&1 | installer: pid, installer_done: false})
    send(pid, :start)

    %{
      state
      | phase: :installing,
        attempt: Map.merge(attempt, %{installer: pid, monitor: monitor})
    }
  end

  defp maybe_install(state), do: state
end

# Fixed schedules, not a loader library. Each interrupted schedule gets a fresh OS VM.
defmodule R0.Schedule do
  @moduledoc "Fixed coherent-update and owner-interruption schedules, not a loader API."
  @type artifacts :: %{R0.Artifact.revision() => R0.Artifact.t()}
  alias R0.Receipt, as: R

  @spec request(R0.Artifact.revision(), module(), R0.Owner.instance_id(), boolean()) ::
          R0.Owner.request()
  def request(revision, entry \\ R0Definition.Left, instance \\ :modern, barrier \\ false) do
    %{
      source: :fixture_source,
      revision: revision,
      entry: entry,
      instance: instance,
      input: 3,
      input_identity: make_ref(),
      barrier: barrier
    }
  end

  @spec queued(pid(), R0.Owner.request()) :: {R0.Owner.envelope(), pid()}
  def queued(owner, request) do
    {:ok, envelope, pid} = GenServer.call(owner, {:invoke, request})
    {envelope, pid}
  end

  @spec result(R0.Owner.envelope()) :: R0.Owner.computation()
  def result(envelope) do
    receive do
      {:queued_result, ^envelope, result} -> result
    after
      5000 -> raise "result missing"
    end
  end

  @spec use(pid(), R0.Artifact.revision(), module(), R0.Owner.instance_id()) ::
          R0.Owner.publication()
  def use(owner, revision, entry \\ R0Definition.Left, instance \\ :modern) do
    {envelope, _} = queued(owner, request(revision, entry, instance))
    result = result(envelope)
    GenServer.call(owner, {:publish, envelope, result})
  end

  @spec update(pid(), R0.Artifact.t(), R0.Installer.phase() | nil) :: reference()
  def update(owner, artifact, pause_at \\ nil) do
    {:ok, token} = GenServer.call(owner, {:update, artifact, 5000, pause_at})
    token
  end

  @spec settled(reference(), R0.Artifact.revision(), R0.Installer.outcome()) :: :ok
  def settled(token, revision, outcome) do
    receive do
      {:installer_done, ^token, _, ^outcome} -> :ok
    after
      5000 -> raise "installer missing"
    end

    R.await({:owner_open, token, revision})
  end

  @spec fresh(pid(), R0.Artifact.revision(), integer(), R0.Owner.instance_id()) :: [
          R0.Owner.publication()
        ]
  def fresh(owner, revision, n \\ 7, instance \\ :modern) do
    factor = %{v1: 1, v2: 2, v3: 3}[revision]

    for {entry, base} <- [{R0Definition.Left, 100}, {R0Definition.Right, 1000}] do
      expected =
        {:published,
         {:ok, %{schema: factor, n: n, kind: instance},
          {revision, revision, factor * base + factor * 10 + n + 3}}}

      R.equal(
        "FRESH_#{revision}_#{entry}_#{instance}",
        use(owner, revision, entry, instance),
        expected
      )
    end
  end

  @spec coherent(pid(), artifacts()) :: [module()]
  def coherent(owner, artifacts) do
    fresh(owner, :v1)
    # Compute a real result now, deliberately leave it queued until after replacement.
    {old_envelope, _} = queued(owner, request(:v1))
    old_result = result(old_envelope)
    # Both entries stop before a remote helper call while v1 remains current.
    held =
      for entry <- [R0Definition.Left, R0Definition.Right] do
        {envelope, pid} = queued(owner, request(:v1, entry, :modern, true))
        R.await({:before_helper, envelope.operation, pid})
        {envelope, pid, entry}
      end

    token = update(owner, artifacts.v2, :before_install)
    R.equal("DRAIN_WAIT", GenServer.call(owner, :state).phase, :draining)

    R.equal(
      "DRAIN_EXECUTABLE_UNCHANGED",
      R0.Artifact.current(),
      R0.Artifact.fingerprint(artifacts.v1)
    )

    R.equal(
      "ADMISSION_CLOSED",
      GenServer.call(owner, {:invoke, request(:v1)}),
      {:error, :draining}
    )

    R.equal(
      "SECOND_INSTALL_REJECTED",
      GenServer.call(owner, {:update, artifacts.v3, 5000, nil}),
      {:error, :draining}
    )

    for {envelope, pid, entry} <- held do
      send(pid, {:continue, envelope.operation})
      computed = result(envelope)
      base = if entry == R0Definition.Left, do: 100, else: 1000

      R.equal(
        "DRAIN_COHERENT_#{entry}",
        computed,
        {:ok, %{schema: 1, n: 7, kind: :modern}, {:v1, :v1, base + 20}}
      )
    end

    receive do
      {:phase, ^token, :before_install, installer} ->
        R.equal("INSTALL_ONLY_AFTER_DRAIN", map_size(GenServer.call(owner, :state).active), 0)
        send(installer, {:continue, token, :before_install})
    after
      5000 -> raise "drained installer missing"
    end

    settled(token, :v2, :accepted)
    fresh(owner, :v2)

    R.equal(
      "STALE_QUEUED_RESULT",
      GenServer.call(owner, {:publish, old_envelope, old_result}),
      {:error, :stale_or_uncorrelated}
    )

    R.equal(
      "STALE_QUEUED_REQUEST",
      GenServer.call(owner, {:invoke, request(:v1)}),
      {:error, :stale_request}
    )

    {envelope, _} = queued(owner, request(:v2))
    computed = result(envelope)
    forged = %{envelope | input_identity: make_ref()}

    R.equal(
      "WRONG_INPUT_CORRELATION",
      GenServer.call(owner, {:publish, forged, computed}),
      {:error, :stale_or_uncorrelated}
    )

    R.equal(
      "VALID_INPUT_CORRELATION",
      GenServer.call(owner, {:publish, envelope, computed}),
      {:published, computed}
    )

    legacy = GenServer.call(owner, :state).models.legacy.data

    R.equal(
      "INSTANCE_UPGRADE_FAILED",
      use(owner, :v2, R0Definition.Left, :legacy),
      {:published, {:error, :legacy_schema}}
    )

    R.equal(
      "INSTANCE_ORIGINAL_RETAINED",
      GenServer.call(owner, :state).models.legacy.data,
      legacy
    )

    R.equal(
      "INSTANCE_UNAVAILABLE",
      GenServer.call(owner, {:invoke, request(:v2, R0Definition.Right, :legacy)}),
      {:error, :instance_unavailable}
    )

    fresh(owner, :v2)
    token = update(owner, artifacts.rejected, :during_restoration)

    receive do
      {:phase, ^token, :during_restoration, installer} ->
        R.equal(
          "REJECTION_CANDIDATE_ACTUALLY_CURRENT",
          R0.Artifact.current(),
          R0.Artifact.fingerprint(artifacts.rejected)
        )

        R.equal(
          "RESTORATION_ADMISSION_CLOSED",
          GenServer.call(owner, {:invoke, request(:v2)}),
          {:error, :installing}
        )

        send(installer, {:continue, token, :during_restoration})
    after
      5000 -> raise "restoration barrier missing"
    end

    settled(token, :v2, :restored)
    fresh(owner, :v2)

    R.equal(
      "RESTORATION_PRESERVES_FAILED_INSTANCE",
      GenServer.call(owner, :state).models.legacy.data,
      legacy
    )

    token = update(owner, artifacts.v3)
    settled(token, :v3, :accepted)
    fresh(owner, :v3)
    fresh(owner, :v3, 11, :legacy)

    R.equal(
      "RECOVERED_ORIGINAL_DATA",
      GenServer.call(owner, :state).models.legacy.data.n,
      legacy.n
    )

    # A zero-millisecond deadline fires while a callback is held, not a timing sleep.
    {envelope, pid} = queued(owner, request(:v3, R0Definition.Left, :modern, true))
    R.await({:before_helper, envelope.operation, pid})
    {:ok, token} = GenServer.call(owner, {:update, artifacts.v2, 0, nil})
    R.await({:drain_rejected, token})

    R.equal(
      "DRAIN_BOUND_NO_INSTALL",
      R0.Artifact.current(),
      R0.Artifact.fingerprint(artifacts.v3)
    )

    send(pid, {:continue, envelope.operation})
    computed = result(envelope)

    R.equal(
      "DRAIN_BOUND_CALLBACK_SURVIVED",
      GenServer.call(owner, {:publish, envelope, computed}),
      {:published, computed}
    )

    collision = %{artifacts.v2 | source: :other_source}

    R.equal(
      "SOURCE_MODULE_COLLISION",
      GenServer.call(owner, {:update, collision, 5000, nil}),
      {:error, :source_module_collision}
    )

    inventory_collision = %{artifacts.v2 | binaries: tl(artifacts.v2.binaries)}

    R.equal(
      "MODULE_INVENTORY_COLLISION",
      GenServer.call(owner, {:update, inventory_collision, 5000, nil}),
      {:error, :source_module_collision}
    )

    fresh(owner, :v3)

    R.equal(
      "STABLE_MODULE_INVENTORY",
      Enum.filter(:code.all_loaded(), fn {module, _} ->
        String.starts_with?(Atom.to_string(module), "Elixir.R0Definition.")
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort(),
      R0.Artifact.modules()
    )
  end

  @spec interrupted(pid(), pid(), artifacts(), R0.Installer.phase()) :: :ok
  def interrupted(owner, ledger, artifacts, phase) do
    candidate = if phase == :during_restoration, do: artifacts.rejected, else: artifacts.v2
    token = update(owner, candidate, phase)

    installer =
      receive do
        {:phase, ^token, ^phase, installer} -> installer
      after
        5000 -> raise "death phase missing"
      end

    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    R.await({:DOWN, monitor, :process, owner, :killed})
    R.equal("DEATH_#{phase}_SURVIVING_INSTALLER", Process.alive?(installer), true)
    {:ok, replacement} = R0.Owner.start(ledger, self())

    R.equal(
      "DEATH_#{phase}_REPLACEMENT_CLOSED",
      GenServer.call(replacement, {:invoke, request(:v1)}),
      {:error, :unavailable}
    )

    R.equal(
      "DEATH_#{phase}_OLD_AUTHORITY_REJECTED",
      GenServer.call(replacement, {:accept, token, candidate}),
      {:error, :obsolete_attempt}
    )

    R.equal(
      "DEATH_#{phase}_RACING_INSTALL_REJECTED",
      GenServer.call(replacement, {:update, artifacts.v3, 5000, nil}),
      {:error, :unavailable}
    )

    live = Agent.get(ledger, & &1)

    misleading = %{
      live
      | phase: :idle,
        installer_done: true,
        acknowledged: true,
        accepted: live.current
    }

    {:ok, misleading_ledger} = Agent.start_link(fn -> misleading end)
    {:ok, guarded} = R0.Owner.start(misleading_ledger, self())

    R.equal(
      "DEATH_#{phase}_LIVE_INSTALLER_FLAG_INSUFFICIENT",
      GenServer.call(guarded, {:invoke, request(live.current.revision)}),
      {:error, :unavailable}
    )

    installer_monitor = Process.monitor(installer)
    send(installer, {:continue, token, phase})

    outcome =
      receive do
        {:installer_done, ^token, ^installer, outcome} -> outcome
      after
        5000 -> raise "interrupted installer missing"
      end

    R.await({:DOWN, installer_monitor, :process, installer, :normal})

    expected_revision =
      %{before_install: :v1, after_install: :v2, during_restoration: :v1, after_accept: :v2}[
        phase
      ]

    expected_accepted = if phase == :after_accept, do: :v2, else: :v1

    R.equal(
      "DEATH_#{phase}_EXECUTABLE",
      R0.Artifact.current(),
      R0.Artifact.fingerprint(artifacts[expected_revision])
    )

    provenance = Agent.get(ledger, & &1)
    R.equal("DEATH_#{phase}_ACCEPTED_PROVENANCE", provenance.accepted.revision, expected_accepted)
    R.equal("DEATH_#{phase}_NO_ACK_INVENTED", provenance.acknowledged, false)

    R.equal(
      "DEATH_#{phase}_STILL_UNAVAILABLE",
      GenServer.call(replacement, {:invoke, request(expected_revision)}),
      {:error, :unavailable}
    )

    {:ok, second_replacement} = R0.Owner.start(ledger, self())

    R.equal(
      "DEATH_#{phase}_RESTART_NOT_EMPTY",
      GenServer.call(second_replacement, {:invoke, request(expected_revision)}),
      {:error, :unavailable}
    )

    {:ok, empty} = Agent.start_link(fn -> nil end)
    {:ok, empty_owner} = R0.Owner.start(empty, self())

    R.equal(
      "DEATH_#{phase}_EMPTY_PROVENANCE_CLOSED",
      GenServer.call(empty_owner, {:invoke, request(expected_revision)}),
      {:error, :unavailable}
    )

    wrong = if expected_revision == :v1, do: artifacts.v2, else: artifacts.v1

    mismatch = %{
      provenance
      | phase: :idle,
        installer_done: true,
        acknowledged: true,
        accepted: wrong
    }

    {:ok, mismatch_ledger} = Agent.start_link(fn -> mismatch end)
    {:ok, mismatch_owner} = R0.Owner.start(mismatch_ledger, self())

    R.equal(
      "DEATH_#{phase}_ARTIFACT_MISMATCH_CLOSED",
      GenServer.call(mismatch_owner, {:invoke, request(wrong.revision)}),
      {:error, :unavailable}
    )

    R.log("DEATH_SUMMARY", %{
      phase: phase,
      outcome: outcome,
      current: expected_revision,
      accepted: expected_accepted,
      acknowledged: provenance.acknowledged,
      replacement: :unavailable,
      installer: :terminated,
      artifact_fingerprint: R0.Artifact.current(),
      attempt: token
    })
  end
end

[root, mode] = System.argv()
R0.Receipt.equal("PIN_ELIXIR", System.version(), "1.20.5")
R0.Receipt.equal("PIN_OTP", :erlang.system_info(:otp_release), ~c"29")

{:ok, otp_version} =
  File.read(Path.join([:code.root_dir() |> List.to_string(), "releases", "29", "OTP_VERSION"]))

R0.Receipt.equal("PIN_ERLANG", String.trim(otp_version), "29.1.2")

R0.Receipt.equal(
  "EXECUTING_VM_STARTED_UNLOADED",
  Enum.map(R0.Artifact.modules(), &:code.is_loaded/1),
  [false, false, false]
)

R0.Receipt.log("DECLARED_BEFORE_EXECUTION", %{
  no_on_load: true,
  no_runtime_modules: true,
  no_escaped_callbacks_or_processes: true,
  no_dependency_replacement: true,
  no_validation_external_effects: true,
  no_force_purge: true,
  trust: :full_os_user_not_sandbox,
  provenance: :vm_local_only,
  mode: mode,
  pid: System.pid()
})

artifacts = Map.new([:v1, :v2, :rejected, :v3], &{&1, R0.Artifact.read(root, &1)})
:ok = R0.Artifact.batch(artifacts.v1)

models = %{
  modern: %{data: %{schema: 1, n: 7, kind: :modern}, status: :usable, attempted: :v1},
  legacy: %{data: %{schema: 1, n: 11, kind: :legacy}, status: :usable, attempted: :v1}
}

{:ok, ledger} =
  Agent.start_link(fn ->
    %{
      accepted: artifacts.v1,
      current: artifacts.v1,
      phase: :idle,
      installer: nil,
      installer_done: true,
      acknowledged: true,
      attempt: nil,
      outcome: :bootstrap,
      models: models
    }
  end)

{:ok, owner} = R0.Owner.start(ledger, self())

case mode do
  "coherent" -> R0.Schedule.coherent(owner, artifacts)
  phase -> R0.Schedule.interrupted(owner, ledger, artifacts, String.to_existing_atom(phase))
end

R0.Receipt.log("FIXTURE_COMPLETE", %{mode: mode, result: :pass})
