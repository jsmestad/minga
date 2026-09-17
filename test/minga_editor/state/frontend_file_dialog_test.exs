defmodule MingaEditor.State.FrontendFileDialogTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Frontend

  @request_id 17
  @stale_id 18
  @next_request_id 73

  test "begin_file_dialog/2 covers every source tag for Open and Save As" do
    buffer = self()

    Enum.each(file_dialog_states(buffer), fn
      {:idle, frontend} ->
        for {request, expected_pending} <- [
              {:open, {:open, @next_request_id}},
              {{:save_as, buffer}, {:save_as, @next_request_id, buffer}}
            ] do
          assert {:ok, @next_request_id, pending} =
                   Frontend.begin_file_dialog(frontend, request)

          assert pending.file_dialog == expected_pending
          assert pending.next_file_dialog_request_id == @next_request_id + 1
        end

      {_source_tag, frontend} ->
        for request <- [:open, {:save_as, buffer}] do
          assert {:error, :busy} = Frontend.begin_file_dialog(frontend, request)
        end
    end)
  end

  test "take_file_dialog/2 only clears matching pending ownership" do
    Enum.each(file_dialog_states(self()), fn
      {:idle, frontend} ->
        assert :stale = Frontend.take_file_dialog(frontend, @request_id)
        assert :stale = Frontend.take_file_dialog(frontend, @stale_id)

      {_source_tag, frontend} ->
        assert :stale = Frontend.take_file_dialog(frontend, @stale_id)
        expected_request = frontend.file_dialog

        assert {:ok, ^expected_request, cleared} =
                 Frontend.take_file_dialog(frontend, @request_id)

        assert cleared.file_dialog == :idle
        assert cleared.next_file_dialog_request_id == @next_request_id
    end)
  end

  test "cancel_file_dialog/2 covers matching and stale ids for every source tag" do
    Enum.each(file_dialog_states(self()), fn {_source_tag, frontend} ->
      stale = Frontend.cancel_file_dialog(frontend, @stale_id)
      assert stale == frontend
      assert stale.next_file_dialog_request_id == @next_request_id

      cancelled = Frontend.cancel_file_dialog(frontend, @request_id)
      assert cancelled == %{frontend | file_dialog: :idle}
      assert cancelled.next_file_dialog_request_id == @next_request_id
    end)
  end

  test "clear_file_dialog/1 clears every source tag without advancing request ids" do
    Enum.each(file_dialog_states(self()), fn {_source_tag, frontend} ->
      cleared = Frontend.clear_file_dialog(frontend)
      assert cleared == %{frontend | file_dialog: :idle}
      assert cleared.next_file_dialog_request_id == @next_request_id
    end)
  end

  test "begin_file_dialog/2 wraps request ids without reuse" do
    frontend = %Frontend{next_file_dialog_request_id: 0xFFFFFFFF}

    assert {:ok, 0xFFFFFFFF, pending} =
             Frontend.begin_file_dialog(frontend, {:save_as, self()})

    assert pending.file_dialog == {:save_as, 0xFFFFFFFF, self()}
    assert pending.next_file_dialog_request_id == 1
  end

  defp file_dialog_states(buffer) do
    [
      {:idle,
       %Frontend{
         file_dialog: :idle,
         next_file_dialog_request_id: @next_request_id
       }},
      {:open,
       %Frontend{
         file_dialog: {:open, @request_id},
         next_file_dialog_request_id: @next_request_id
       }},
      {:save_as,
       %Frontend{
         file_dialog: {:save_as, @request_id, buffer},
         next_file_dialog_request_id: @next_request_id
       }}
    ]
  end
end
