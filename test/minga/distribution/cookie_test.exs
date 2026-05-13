defmodule Minga.Distribution.CookieTest do
  use ExUnit.Case, async: true

  alias Minga.Distribution.Cookie

  test "read_file/1 accepts a regular owner-only cookie file" do
    path = temp_cookie_file("abcdefghijklmnopqrstuvwxyz123456")
    File.chmod!(path, 0o600)

    assert Cookie.read_file(path) == {:ok, "abcdefghijklmnopqrstuvwxyz123456"}
  end

  test "read_file/1 rejects group or other readable cookie files" do
    path = temp_cookie_file("abcdefghijklmnopqrstuvwxyz123456")
    File.chmod!(path, 0o644)

    assert Cookie.read_file(path) == {:error, :insecure_permissions}
  end

  test "to_atom/1 rejects short or invalid cookies" do
    assert Cookie.to_atom("short") == {:error, :weak_or_invalid}
    assert Cookie.to_atom("abcdefghijklmnopqrstuvwxyz12345!") == {:error, :weak_or_invalid}
  end

  test "to_atom/1 accepts 32 byte allowed cookies" do
    assert {:ok, :abcdefghijklmnopqrstuvwxyz123456} =
             Cookie.to_atom("abcdefghijklmnopqrstuvwxyz123456")
  end

  @spec temp_cookie_file(String.t()) :: String.t()
  defp temp_cookie_file(content) do
    dir = Path.join(System.tmp_dir!(), "minga-cookie-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "cookie")
    File.write!(path, content)
    path
  end
end
