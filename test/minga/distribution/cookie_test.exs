defmodule Minga.Distribution.CookieTest do
  use ExUnit.Case, async: true

  alias Minga.Distribution.Cookie

  @moduletag :tmp_dir

  test "read_file/1 accepts a regular owner-only cookie file", %{tmp_dir: dir} do
    path = temp_cookie_file(dir, "abcdefghijklmnopqrstuvwxyz123456")
    File.chmod!(path, 0o600)

    assert Cookie.read_file(path) == {:ok, "abcdefghijklmnopqrstuvwxyz123456"}
  end

  test "read_file/1 rejects group or other readable cookie files", %{tmp_dir: dir} do
    path = temp_cookie_file(dir, "abcdefghijklmnopqrstuvwxyz123456")
    File.chmod!(path, 0o644)

    assert Cookie.read_file(path) == {:error, :insecure_permissions}
  end

  test "read_file/1 rejects symlinks before following the target", %{tmp_dir: dir} do
    target = temp_cookie_file(dir, "abcdefghijklmnopqrstuvwxyz123456")
    File.chmod!(target, 0o600)
    link = target <> "-link"
    File.ln_s!(target, link)

    assert Cookie.read_file(link) == {:error, :not_regular_file}
  end

  test "to_atom/1 rejects short or invalid cookies" do
    assert Cookie.to_atom("short") == {:error, :weak_or_invalid}
    assert Cookie.to_atom("abcdefghijklmnopqrstuvwxyz12345!") == {:error, :weak_or_invalid}
  end

  test "to_atom/1 accepts 32 byte allowed cookies" do
    assert {:ok, :abcdefghijklmnopqrstuvwxyz123456} =
             Cookie.to_atom("abcdefghijklmnopqrstuvwxyz123456")
  end

  @spec temp_cookie_file(String.t(), String.t()) :: String.t()
  defp temp_cookie_file(dir, content) do
    path = Path.join(dir, "cookie")
    File.write!(path, content)
    path
  end
end
