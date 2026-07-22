defmodule MingaEditor.HighlightSyncEvictionTest do
  @moduledoc "Tests parser-manager ownership and editor presentation cleanup."

  use ExUnit.Case, async: true

  alias MingaEditor.State.Buffers
  alias MingaEditor.Session.State, as: SessionState
  alias Minga.Parser.BufferConfig
  alias Minga.Parser.Manager
  alias MingaEditor.HighlightSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.UI.Highlight
  alias MingaEditor.VimState

  setup do
    name = Module.concat(__MODULE__, "Parser#{System.unique_integer([:positive])}")
    manager = start_supervised!({Manager, name: name, parser_path: "/missing/minga-parser"})
    Process.put(:parser_manager, manager)
    :ok
  end

  describe "evict_inactive/2" do
    test "evicts stale manager registrations and their presentation caches" do
      stale = tracked_pid()
      id = register(stale)

      state =
        base_state()
        |> then(fn state ->
          %{
            state
            | parser:
                MingaEditor.State.Parser.accept_highlighting(state.parser, %Highlighting{
                  highlights: %{stale => Highlight.new()}
                })
          }
        end)
        |> then(fn state ->
          %{
            state
            | parser:
                MingaEditor.State.Parser.accept_injection_ranges(state.parser, %{
                  stale => [:range]
                })
          }
        end)

      receive do
      after
        2 -> :ok
      end

      new_state = HighlightSync.evict_inactive(state, ttl_ms: 0)

      assert Manager.buffer_id(stale, manager()) == nil
      assert Manager.resolve_buffer(id, manager()) == nil
      refute Map.has_key?(new_state.parser.highlighting.highlights, stale)
      refute Map.has_key?(new_state.parser.injection_ranges, stale)
    end

    test "keeps active and explicitly protected registrations" do
      active = tracked_pid()
      protected = tracked_pid()
      active_id = register(active)
      protected_id = register(protected)
      state = base_state() |> put_active(active)

      receive do
      after
        2 -> :ok
      end

      _state = HighlightSync.evict_inactive(state, ttl_ms: 0, protected_pids: [protected])

      assert Manager.buffer_id(active, manager()) == active_id
      assert Manager.buffer_id(protected, manager()) == protected_id
    end

    test "returns state unchanged when no buffers are tracked" do
      state = base_state()
      assert HighlightSync.evict_inactive(state, ttl_ms: 0) == state
    end
  end

  describe "manager-backed identity" do
    test "parser identity remains outside editor presentation state" do
      buffer = tracked_pid()
      state = base_state() |> put_active(buffer)
      id = register(buffer)

      assert Manager.buffer_id(buffer, manager()) == id

      assert state.parser.highlighting |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               [:highlights, :syntax_overrides]
    end

    test "registrations allocate stable monotonic IDs" do
      first = tracked_pid()
      second = tracked_pid()

      first_id = register(first)
      assert register(first) == first_id
      assert register(second) == first_id + 1
    end
  end

  describe "close_buffer/2" do
    test "unregisters manager state and removes both presentation stores" do
      buffer_pid = tracked_pid()
      id = register(buffer_pid)

      state =
        base_state()
        |> then(fn state ->
          %{
            state
            | parser:
                MingaEditor.State.Parser.accept_highlighting(state.parser, %Highlighting{
                  highlights: %{buffer_pid => Highlight.new()}
                })
          }
        end)
        |> then(fn state ->
          %{
            state
            | parser:
                MingaEditor.State.Parser.accept_injection_ranges(state.parser, %{
                  buffer_pid => [:range]
                })
          }
        end)

      new_state = HighlightSync.close_buffer(state, buffer_pid)

      assert Manager.buffer_id(buffer_pid, manager()) == nil
      assert Manager.resolve_buffer(id, manager()) == nil
      refute Map.has_key?(new_state.parser.highlighting.highlights, buffer_pid)
      refute Map.has_key?(new_state.parser.injection_ranges, buffer_pid)
    end

    test "cleans presentation caches even without a parser registration" do
      buffer_pid = tracked_pid()

      state =
        base_state()
        |> then(fn state ->
          %{
            state
            | parser:
                MingaEditor.State.Parser.accept_highlighting(state.parser, %Highlighting{
                  highlights: %{buffer_pid => Highlight.new()}
                })
          }
        end)
        |> then(fn state ->
          %{
            state
            | parser:
                MingaEditor.State.Parser.accept_injection_ranges(state.parser, %{
                  buffer_pid => [:range]
                })
          }
        end)

      new_state = HighlightSync.close_buffer(state, buffer_pid)

      refute Map.has_key?(new_state.parser.highlighting.highlights, buffer_pid)
      refute Map.has_key?(new_state.parser.injection_ranges, buffer_pid)
    end
  end

  defp base_state do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      parser: %MingaEditor.State.Parser{parser_manager: manager()},
      workspace: %MingaEditor.Session.State{editing: VimState.new()}
    }
  end

  defp manager, do: Process.get(:parser_manager)

  defp register(pid) do
    Manager.register_buffer(pid, %BufferConfig{language: "elixir"}, server: manager())
  end

  defp tracked_pid do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end

  defp put_active(state, pid),
    do: %{
      state
      | workspace:
          SessionState.set_buffers(
            state.workspace,
            Buffers.set_active_override(state.workspace.buffers, pid)
          )
    }
end
