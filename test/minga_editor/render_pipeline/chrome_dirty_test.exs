defmodule MingaEditor.RenderPipeline.ChromeDirtyTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers

  describe "chrome_fingerprint/1" do
    test "same input produces same fingerprint" do
      state = TestHelpers.base_state()
      input = Input.from_editor_state(state)

      fp1 = Input.chrome_fingerprint(input)
      fp2 = Input.chrome_fingerprint(input)

      assert fp1 == fp2
    end

    test "changing vim mode changes fingerprint" do
      state = TestHelpers.base_state()
      input = Input.from_editor_state(state)
      fp_normal = Input.chrome_fingerprint(input)

      # Simulate mode change
      ws = input.workspace
      editing = %{ws.editing | mode: :insert}
      input2 = %{input | workspace: %{ws | editing: editing}}
      fp_insert = Input.chrome_fingerprint(input2)

      assert fp_normal != fp_insert
    end

    test "moving cursor changes fingerprint" do
      state = TestHelpers.base_state()
      buf = state.workspace.buffers.active

      input1 = Input.from_editor_state(state)
      fp1 = Input.chrome_fingerprint(input1)

      # Move cursor in the buffer
      Minga.Buffer.move_to(buf, {1, 0})

      input2 = Input.from_editor_state(state)
      fp2 = Input.chrome_fingerprint(input2)

      assert fp1 != fp2
    end

    test "changing file tree changes fingerprint" do
      state = TestHelpers.base_state()
      input = Input.from_editor_state(state)
      fp1 = Input.chrome_fingerprint(input)

      # Simulate file tree focus change
      ws = input.workspace
      ft = %{ws.file_tree | focused: true}
      input2 = %{input | workspace: %{ws | file_tree: ft}}
      fp2 = Input.chrome_fingerprint(input2)

      assert fp1 != fp2
    end

    test "unchanged input between frames produces stable fingerprint" do
      state = TestHelpers.base_state()
      input = Input.from_editor_state(state)

      # Simulate two frames with no state changes
      fp_frame1 = Input.chrome_fingerprint(input)
      fp_frame2 = Input.chrome_fingerprint(input)

      assert fp_frame1 == fp_frame2
    end
  end

  describe "chrome skip integration" do
    test "second render with unchanged state skips chrome rebuild" do
      state = TestHelpers.base_state()

      # First render: builds chrome fresh, caches fingerprint
      _state = TestHelpers.run_pipeline(state)
      fp_after_first = Process.get(:chrome_prev_fingerprint)
      chrome_after_first = Process.get(:chrome_prev_result)

      assert fp_after_first != nil, "fingerprint should be cached after first render"
      assert chrome_after_first != nil, "chrome result should be cached after first render"

      # Second render: fingerprint should match, reusing cached chrome
      _state = TestHelpers.run_pipeline(state)
      fp_after_second = Process.get(:chrome_prev_fingerprint)
      chrome_after_second = Process.get(:chrome_prev_result)

      assert fp_after_second == fp_after_first,
             "fingerprint should be stable across unchanged frames"

      # Same object reference means chrome was reused, not rebuilt
      assert chrome_after_second === chrome_after_first
    end

    test "render after cursor move rebuilds chrome" do
      state = TestHelpers.base_state()
      buf = state.workspace.buffers.active

      # First render
      _state = TestHelpers.run_pipeline(state)
      fp_before = Process.get(:chrome_prev_fingerprint)

      # Move cursor (changes status bar data)
      Minga.Buffer.move_to(buf, {1, 0})

      # Second render: fingerprint should differ, forcing rebuild
      _state = TestHelpers.run_pipeline(state)
      fp_after = Process.get(:chrome_prev_fingerprint)

      assert fp_before != fp_after, "cursor move should change chrome fingerprint"
    end
  end
end
