defmodule Minga.UI.Picker.LanguageSourceTest do
  @moduledoc "Tests for the language picker source."
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.UI.Picker.Item
  alias Minga.UI.Picker.LanguageSource

  describe "title/0" do
    test "returns Set language" do
      assert LanguageSource.title() == "Set language"
    end
  end

  describe "candidates/1" do
    test "returns all registered languages" do
      state = state_with_buffer("hello", :elixir)
      candidates = LanguageSource.candidates(state)

      assert candidates != []
      assert Enum.all?(candidates, &match?(%Item{}, &1))
    end

    test "each candidate has an icon and label" do
      state = state_with_buffer("hello", :elixir)
      candidates = LanguageSource.candidates(state)

      elixir = Enum.find(candidates, fn %Item{id: id} -> id == :elixir end)
      assert elixir != nil
      assert elixir.label =~ "Elixir"
    end

    test "current filetype is marked with a bullet" do
      state = state_with_buffer("hello", :elixir)
      candidates = LanguageSource.candidates(state)

      elixir = Enum.find(candidates, fn %Item{id: id} -> id == :elixir end)
      assert elixir.label =~ "•"

      python = Enum.find(candidates, fn %Item{id: id} -> id == :python end)
      refute python.label =~ "•"
    end

    test "shows file extensions in description" do
      state = state_with_buffer("hello", :text)
      candidates = LanguageSource.candidates(state)

      elixir = Enum.find(candidates, fn %Item{id: id} -> id == :elixir end)
      assert elixir.description =~ ".ex"
    end

    test "candidates are sorted by label" do
      state = state_with_buffer("hello", :text)
      candidates = LanguageSource.candidates(state)
      labels = Enum.map(candidates, & &1.label)
      assert labels == Enum.sort(labels)
    end
  end

  describe "on_select/2" do
    test "changes the buffer filetype" do
      state = state_with_buffer("hello world", :text)
      buf = state.workspace.buffers.active
      assert BufferServer.filetype(buf) == :text

      item = %Item{id: :python, label: "Python"}
      _new_state = LanguageSource.on_select(item, state)

      assert BufferServer.filetype(buf) == :python
    end
  end

  describe "apply_filetype_change/2" do
    alias Minga.Editor.Commands.BufferManagement

    test "changes the buffer filetype via shared function" do
      state = state_with_buffer("hello", :text)
      buf = state.workspace.buffers.active
      assert BufferServer.filetype(buf) == :text

      new_state = BufferManagement.apply_filetype_change(state, :python)
      assert BufferServer.filetype(buf) == :python
      assert new_state.shell_state.status_msg =~ "python"
    end

    test "returns error message when no active buffer" do
      state = %{
        workspace: %{buffers: %{active: nil}},
        shell_state: %Minga.Shell.Traditional.State{status_msg: nil}
      }

      new_state = BufferManagement.apply_filetype_change(state, :python)
      assert new_state.shell_state.status_msg =~ "No active buffer"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp state_with_buffer(content, filetype) do
    {:ok, buf} = BufferServer.start_link(content: content, filetype: filetype)

    %{
      workspace: %{buffers: %{active: buf, list: [buf], active_index: 0}},
      shell_state: %Minga.Shell.Traditional.State{status_msg: nil}
    }
  end
end
