defmodule Minga.Buffer.SaveStateTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.SaveState

  describe "dirty tracking" do
    test "mark_changed advances version and marks dirty until the saved version is restored" do
      save_state = SaveState.new()

      changed = SaveState.mark_changed(save_state)
      assert SaveState.version(changed) == 1
      assert SaveState.dirty?(changed)

      restored = SaveState.restore_version(changed, 0)
      refute SaveState.dirty?(restored)
    end

    test "mark_saved records the current version as the clean baseline" do
      save_state = SaveState.new() |> SaveState.mark_changed()

      saved = SaveState.mark_saved(save_state, {123, 5}, "hello")

      refute SaveState.dirty?(saved)
      assert SaveState.saved_version(saved) == SaveState.version(saved)
      assert SaveState.mtime(saved) == 123
      assert SaveState.file_size(saved) == 5
      assert SaveState.file_hash(saved) == SaveState.content_fingerprint("hello")
    end

    test "record_clean_change preserves clean buffers as clean while advancing version" do
      save_state = SaveState.new()

      changed = SaveState.record_clean_change(save_state)

      refute SaveState.dirty?(changed)
      assert SaveState.version(changed) == 1
      assert SaveState.saved_version(changed) == 1
    end

    test "record_clean_change preserves an existing dirty state" do
      save_state = SaveState.new() |> SaveState.mark_changed()

      changed = SaveState.record_clean_change(save_state)

      assert SaveState.dirty?(changed)
      assert SaveState.version(changed) == 2
      assert SaveState.saved_version(changed) == 0
    end
  end

  describe "saved baseline tracking" do
    test "loaded records metadata and fingerprint only for meaningful file baselines" do
      save_state = SaveState.loaded("file.txt", {123, 5}, "hello")

      assert SaveState.mtime(save_state) == 123
      assert SaveState.file_size(save_state) == 5
      assert SaveState.file_hash(save_state) == SaveState.content_fingerprint("hello")

      scratch = SaveState.loaded(nil, {nil, nil}, "scratch")
      assert SaveState.file_hash(scratch) == nil
    end

    test "accept_saved_content advances version and makes replacement content clean" do
      save_state = SaveState.new() |> SaveState.mark_changed()

      accepted = SaveState.accept_saved_content(save_state, {234, 7}, "content")

      refute SaveState.dirty?(accepted)
      assert SaveState.version(accepted) == 2
      assert SaveState.saved_version(accepted) == 2
      assert SaveState.mtime(accepted) == 234
      assert SaveState.file_size(accepted) == 7
      assert SaveState.file_hash(accepted) == SaveState.content_fingerprint("content")
    end
  end

  describe "conflict detection" do
    test "same saved content ignores metadata-only changes" do
      save_state = SaveState.loaded("file.txt", {123, 5}, "hello")

      refute SaveState.changed_since_saved?(save_state, 456, 5, :same)
    end

    test "changed saved content reports a conflict" do
      save_state = SaveState.loaded("file.txt", {123, 5}, "hello")

      assert SaveState.changed_since_saved?(save_state, 123, 5, :changed)
    end

    test "unknown saved content falls back to metadata comparison" do
      save_state = SaveState.loaded(nil, {123, 5}, "hello")

      refute SaveState.changed_since_saved?(save_state, 123, 5, :unknown)
      assert SaveState.changed_since_saved?(save_state, 456, 5, :unknown)
    end
  end
end
