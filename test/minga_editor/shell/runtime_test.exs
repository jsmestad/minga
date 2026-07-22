defmodule MingaEditor.Shell.RuntimeTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Identity
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Test.FakeShell
  alias MingaEditor.Test.FakeShellAlt

  @workspace %SessionState{}

  setup_all do
    {:module, FakeShell} = Code.ensure_loaded(FakeShell)
    {:module, FakeShellAlt} = Code.ensure_loaded(FakeShellAlt)
    :ok
  end

  test "construction exposes one resolved active shell value" do
    entry = entry(:fake, FakeShell, 7)
    runtime = Runtime.new(entry, %{marker: :active})

    assert Runtime.entry(runtime) == entry
    assert Runtime.id(runtime) == :fake
    assert Runtime.module(runtime) == FakeShell
    assert Runtime.state(runtime) == %{marker: :active}
    assert Runtime.stash(runtime) == %{}
    assert Runtime.matches_identity?(runtime, Runtime.identity(runtime))
  end

  test "activation stashes outgoing state and restores only the exact registration" do
    fake = entry(:fake, FakeShell, 1)
    alternate = entry(:alternate, FakeShellAlt, 2)

    runtime =
      fake
      |> Runtime.new(%{marker: :fake})
      |> Runtime.activate(alternate, %{marker: :alternate})

    assert Runtime.state(runtime) == %{marker: :alternate}
    assert stashed(runtime, fake).state == %{marker: :fake}

    restored = Runtime.activate(runtime, fake, %{marker: :new_default})
    assert Runtime.state(restored) == %{marker: :fake}
    refute stashed_id?(restored, :fake)
    assert stashed(restored, alternate).state == %{marker: :alternate}
  end

  test "reused ids with stale module, source, or generation never restore old state" do
    original = entry(:fake, FakeShell, 1)
    alternate = entry(:alternate, FakeShellAlt, 2)

    for replacement <- [
          entry(:fake, FakeShell, 9),
          entry(:fake, FakeShellAlt, 1),
          %Entry{entry(:fake, FakeShell, 1) | source: {:extension, :replacement}}
        ] do
      runtime =
        original
        |> Runtime.new(%{marker: :stale})
        |> Runtime.activate(alternate, %{})
        |> Runtime.activate(replacement, %{marker: :fresh})

      assert Runtime.state(runtime) == %{marker: :fresh}
      refute stashed_id?(runtime, :fake)
    end
  end

  test "registration validation preserves exact identity and resets changed identity" do
    original = entry(:fake, FakeShell, 1)
    runtime = Runtime.new(original, %{marker: :active})

    assert {^runtime, :current} =
             Runtime.validate_registration(runtime, original, %{marker: :unused})

    replacement = entry(:fake, FakeShellAlt, 2)

    assert {reset, :reset} =
             Runtime.validate_registration(runtime, replacement, %{marker: :reset})

    assert Runtime.entry(reset) == replacement
    assert Runtime.state(reset) == %{marker: :reset}
    assert Runtime.stash(reset) == %{}
  end

  test "fallback after active registration removal restores an exact default stash" do
    default = entry(:traditional, FakeShell, 1, :builtin)
    extension = entry(:fake, FakeShellAlt, 2)

    runtime =
      default
      |> Runtime.new(%{marker: :default})
      |> Runtime.activate(extension, %{marker: :extension})

    fallback = Runtime.fallback_from_removed(runtime, default, %{marker: :new_default})
    assert Runtime.entry(fallback) == default
    assert Runtime.state(fallback) == %{marker: :default}
    refute stashed_id?(fallback, :traditional)
    refute stashed_id?(fallback, :fake)
  end

  test "active events route through the active entry contract" do
    runtime = Runtime.new(entry(:fake, FakeShell, 1), %{events: []})

    assert {updated, @workspace} = Runtime.route_event(runtime, @workspace, :refresh)
    assert Runtime.state(updated).events == [:refresh]
  end

  test "active agent events preserve identity and return persistence changes" do
    entry = entry(:fake, FakeShell, 1)
    old_state = %{events: [], record_agent_events?: true}
    runtime = Runtime.new(entry, old_state)

    assert {updated, @workspace, {%Entry{} = changed_entry, ^old_state, new_state}} =
             Runtime.route_agent_event(runtime, @workspace, self(), :background)

    assert changed_entry == entry
    assert Runtime.entry(updated) == entry
    assert Runtime.state(updated) == new_state
    assert new_state.events == [:background]
  end

  test "stashed agent events use each stashed entry and skip removed registrations" do
    fake = entry(:fake, FakeShell, 1)
    alternate = entry(:alternate, FakeShellAlt, 2)

    runtime =
      fake
      |> Runtime.new(%{events: [], record_agent_events?: true})
      |> Runtime.activate(alternate, %{events: []})

    {updated, @workspace, changes} =
      Runtime.route_stashed_agent_event(runtime, [fake], @workspace, self(), :background)

    assert Runtime.entry(updated) == alternate
    assert Runtime.state(updated) == %{events: []}
    assert stashed(updated, fake).state.events == [:background]
    assert [{%Entry{module: FakeShell}, _old_state, _new_state}] = changes

    {unchanged, @workspace, []} =
      Runtime.route_stashed_agent_event(runtime, [], @workspace, self(), :ignored)

    assert Runtime.stash(unchanged) == Runtime.stash(runtime)
  end

  test "persisted state is accepted only for the exact active or stashed registration" do
    fake = entry(:fake, FakeShell, 1)
    alternate = entry(:alternate, FakeShellAlt, 2)

    active = Runtime.new(fake, %{marker: :before})
    persisted = Runtime.accept_persisted_state(active, fake, %{marker: :persisted})
    assert Runtime.state(persisted) == %{marker: :persisted}

    stale = entry(:fake, FakeShell, 9)
    assert Runtime.accept_persisted_state(active, stale, %{marker: :stale}) == active

    stashed = Runtime.activate(active, alternate, %{marker: :alternate})
    stashed = Runtime.accept_persisted_state(stashed, fake, %{marker: :persisted_stash})
    assert Runtime.state(stashed) == %{marker: :alternate}
    assert stashed(stashed, fake).state == %{marker: :persisted_stash}
  end

  test "extension ownership uses its contract without Traditional state fields" do
    session = self()
    extension = entry(:extension, FakeShellAlt, 1)
    shell_state = %{owned_sessions: [session], extension_only: :state}
    runtime = Runtime.new(extension, shell_state)

    assert Runtime.owns_agent_session?(runtime, [extension], session)

    stashed_runtime = Runtime.activate(runtime, entry(:active, FakeShell, 2), %{})
    assert Runtime.owns_agent_session?(stashed_runtime, [extension], session)
    refute Runtime.owns_agent_session?(stashed_runtime, [extension], spawn(fn -> :ok end))
  end

  test "session extraction and installation use an extension shell's state shape" do
    extension = entry(:extension, FakeShellAlt, 1)
    runtime = Runtime.new(extension, %{extension_only: :state})

    assert Runtime.active_session(runtime) == nil

    installed = Runtime.set_tab_session(runtime, :extension_slot, self())

    assert Runtime.active_session(installed) == self()
    assert Runtime.state(installed) == %{extension_only: :state, session_slot: self()}
    assert Runtime.owns_agent_session?(installed, [extension], self())
  end

  test "rejected stashed callbacks leave runtime state unchanged" do
    stashed_entry = entry(:fake, FakeShell, 1)

    runtime =
      stashed_entry
      |> Runtime.new(%{mutate_rejected_callback?: true})
      |> Runtime.activate(entry(:active, FakeShellAlt, 2), %{})

    assert {^runtime, false, []} =
             Runtime.route_stashed_session_down(runtime, [stashed_entry], self(), :foreign)

    refute Map.has_key?(stashed(runtime, stashed_entry).state, :foreign_mutation)
  end

  test "active and stashed session lifecycle routes through exact entry contracts" do
    old_pid = self()

    new_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(new_pid), do: send(new_pid, :stop) end)

    fake = entry(:fake, FakeShell, 1)
    alternate = entry(:alternate, FakeShellAlt, 2)

    active = Runtime.new(fake, %{session: old_pid})

    assert {down, true, {%Entry{module: FakeShell}, _old, _new}} =
             Runtime.route_session_down(active, old_pid, :boom)

    assert Runtime.state(down).session_down?

    runtime = Runtime.activate(active, alternate, %{session: old_pid})

    assert {restarted, true, changes} =
             Runtime.route_session_restarted(runtime, [fake], old_pid, new_pid, :restart)

    assert Runtime.state(restarted).session == new_pid
    assert stashed(restarted, fake).state.session == new_pid
    assert [_, _] = changes

    stashed_runtime =
      fake
      |> Runtime.new(%{session: old_pid})
      |> Runtime.activate(alternate, %{session: new_pid})

    assert {stashed_down, true, [_change]} =
             Runtime.route_stashed_session_down(stashed_runtime, [fake], old_pid, :boom)

    assert stashed(stashed_down, fake).state.session_down?

    assert {disconnected, true, [_change]} =
             Runtime.route_stashed_remote_session_disconnected(stashed_runtime, [fake], old_pid)

    assert stashed(disconnected, fake).state.remote_disconnected?
  end

  @spec stashed(Runtime.t(), Entry.t()) :: MingaEditor.Shell.StateStash.t()
  defp stashed(%Runtime{} = runtime, %Entry{} = entry) do
    Map.fetch!(Runtime.stash(runtime), Identity.new(entry))
  end

  @spec stashed_id?(Runtime.t(), atom()) :: boolean()
  defp stashed_id?(%Runtime{} = runtime, id) do
    Enum.any?(Runtime.stash(runtime), fn {%Identity{id: stashed_id}, _state} ->
      stashed_id == id
    end)
  end

  defp entry(id, module, generation, source \\ {:extension, :runtime_test}) do
    %Entry{
      id: id,
      source: source,
      module: module,
      display_name: Atom.to_string(id),
      description: "Runtime test shell",
      capabilities: [:gui, :tui],
      default?: source == :builtin,
      generation: generation
    }
  end
end
