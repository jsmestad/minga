defmodule MingaEditor.Commands.StartBufferTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias MingaEditor.Commands

  @moduletag :tmp_dir

  describe "start_buffer/1" do
    test "returns an existing registered file buffer instead of starting a duplicate", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "already-open.ex")
      File.write!(path, "already open")
      existing = start_supervised!({Buffer, file_path: path})

      assert {:ok, ^existing} = Commands.start_buffer(path)
      assert {:ok, ^existing} = Buffer.pid_for_path(path)
    end
  end
end
