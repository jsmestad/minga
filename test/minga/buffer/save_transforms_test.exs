defmodule Minga.Buffer.SaveTransformsTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess

  @moduletag :tmp_dir

  test "trim-only save preserves loaded CRLF bytes and blank lines", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "trim-crlf.txt")
    File.write!(path, "α  \r\n  \r\n你好\t\r\n")
    buffer = start_file_buffer(path)

    assert :ok =
             BufferProcess.save_if_version(buffer, BufferProcess.version(buffer),
               trim_trailing_whitespace: true
             )

    assert File.read!(path) == "α\r\n\r\n你好\r\n"
  end

  test "final-newline-only saves choose CRLF, LF, mixed-file last separator, or default LF", %{
    tmp_dir: tmp_dir
  } do
    cases = [
      {"crlf.txt", "alpha\r\nbeta", "alpha\r\nbeta\r\n"},
      {"lf.txt", "alpha\nbeta", "alpha\nbeta\n"},
      {"mixed.txt", "alpha\nbeta\r\ngamma", "alpha\nbeta\r\ngamma\r\n"},
      {"no-separator.txt", "alpha", "alpha\n"},
      {"existing-crlf.txt", "alpha\r\n", "alpha\r\n"},
      {"existing-lf.txt", "alpha\n", "alpha\n"},
      {"empty.txt", "", ""}
    ]

    for {name, input, expected} <- cases do
      path = Path.join(tmp_dir, name)
      File.write!(path, input)
      buffer = start_file_buffer(path)

      assert :ok =
               BufferProcess.save_if_version(buffer, BufferProcess.version(buffer),
                 insert_final_newline: true
               )

      assert File.read!(path) == expected
    end
  end

  test "combined transforms preserve mixed separators across repeated saves", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "mixed-repeat.txt")
    File.write!(path, "first  \r\nsecond\t\nthird  ")
    buffer = start_file_buffer(path)
    options = [trim_trailing_whitespace: true, insert_final_newline: true]

    assert :ok = BufferProcess.save_if_version(buffer, BufferProcess.version(buffer), options)
    expected = "first\r\nsecond\nthird\n"
    assert File.read!(path) == expected

    assert :ok = BufferProcess.save_if_version(buffer, BufferProcess.version(buffer), options)
    assert File.read!(path) == expected
  end

  test "disabled save transforms retain the loaded file bytes", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "disabled.txt")
    content = "α  \r\n\t\n你好\r\n"
    File.write!(path, content)
    buffer = start_file_buffer(path)

    assert :ok = BufferProcess.save_if_version(buffer, BufferProcess.version(buffer), [])
    assert File.read!(path) == content
  end

  @spec start_file_buffer(String.t()) :: pid()
  defp start_file_buffer(path) do
    start_supervised!({BufferProcess, file_path: path}, id: {BufferProcess, make_ref()})
  end
end
