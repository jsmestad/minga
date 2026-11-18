defmodule MingaAgent.OAuth.StoreTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias Minga.Buffer.ControllableFileSystem
  alias MingaAgent.{Credentials, OAuth}
  alias MingaAgent.OAuth.Store

  @other %{"other-provider" => %{"token" => "unrelated-fixture"}}

  @tag :tmp_dir
  test "a refresh through a symlink cannot race login or revoke the same file", %{tmp_dir: dir} do
    real = Path.join(dir, "real")
    File.mkdir_p!(Path.join(real, "child"))
    File.ln_s!("real/child", Path.join(dir, "directory-link"))
    alias_path = Path.join(dir, "oauth-link.json")
    File.ln_s!("directory-link/../oauth.json", alias_path)
    target = Path.join(real, "oauth.json")
    raw_target = dir <> "/directory-link/../oauth.json"
    decoy = Path.join(dir, "oauth.json")
    assert :ok = OAuth.write_oauth_file(tokens("decoy-expired", 1), decoy)
    decoy_bytes = File.read!(decoy)
    api_keys = Path.join(dir, "minga/credentials.json")
    File.mkdir_p!(Path.dirname(api_keys))
    api_bytes = ~s({"anthropic":"unrelated-key","openai_codex":"legacy-fixture"})
    File.write!(api_keys, api_bytes)
    File.write!(target, JSON.encode!(@other))

    assert :ok = OAuth.write_oauth_file(tokens("expired", 1), alias_path)
    before = File.read!(target)
    caller = self()

    refresh =
      Task.async(fn ->
        Store.resolve(raw_target,
          oauth_http_options: [plug: &refresh_response(&1, caller), retry: false]
        )
      end)

    assert_receive {:refresh_started, worker}, 5_000

    assert {:error, "OAuth credentials are busy. Try again after the current request finishes."} =
             OAuth.write_oauth_file(tokens("new-account-token", nil), target)

    assert {:error, :oauth_file_busy} =
             Credentials.revoke("openai_codex", revoke_paths(dir, target))

    assert File.read!(target) == before
    assert File.read!(api_keys) == api_bytes

    send(worker, :complete_refresh)

    assert {:ok, %{source: :oauth_refresh, token: "refreshed-token", oauth_file: ^raw_target}} =
             Task.await(refresh)

    assert JSON.decode!(File.read!(target))["openai-codex"]["access"] == "refreshed-token"
    assert :ok = OAuth.write_oauth_file(tokens("new-account-token", nil), raw_target)

    assert {:ok, %{account_id: "fixture-account", oauth_path: ^raw_target} = pin} =
             Credentials.pin_oauth(:openai_codex, raw_target)

    assert %{oauth_ref: ^pin} = Credentials.snapshot(revoke_paths(dir, raw_target))
    assert {:ok, options} = Credentials.request_options(pin, [])
    assert options[:access_token] == "new-account-token"

    refute MingaAgent.ModelSelection.Credential.OAuth.new(pin.account_id, decoy).source_id ==
             pin.source_id

    malformed_api_bytes = "{\"anthropic\":\"unrelated-key\""
    File.write!(api_keys, malformed_api_bytes)
    assert :ok = Credentials.revoke("openai_codex", revoke_paths(dir, raw_target))
    assert File.read!(api_keys) == malformed_api_bytes
    assert File.read_link!(alias_path) == "directory-link/../oauth.json"
    assert JSON.decode!(File.read!(target)) == @other
    assert File.read!(decoy) == decoy_bytes
  end

  @tag :tmp_dir
  test "failed precommit steps leave bytes and permissions intact", %{tmp_dir: dir} do
    path = Path.join(dir, "oauth.json")
    prior = JSON.encode!(@other)
    File.write!(path, prior)
    File.chmod!(path, 0o640)

    for stage <- [:open, :open_permissions, :write, :flush, :rename] do
      assert {:error, "OAuth credential storage failed."} =
               OAuth.write_oauth_file(tokens("new-account-token", nil), path,
                 file_system: ControllableFileSystem,
                 fail_at: stage
               )

      assert File.read!(path) == prior
      assert band(File.stat!(path).mode, 0o777) == 0o640
      assert File.ls!(dir) == ["oauth.json"]
    end
  end

  @tag :tmp_dir
  test "malformed input cannot be erased by install or revoke and is not exposed in errors", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "oauth.json")

    for bytes <- [~s({"access":"private-fixture-value"), "[]"] do
      File.write!(path, bytes)

      assert {:error, "OAuth credential storage failed."} =
               OAuth.write_oauth_file(tokens("new", nil), path)

      assert {:error, :invalid_oauth_file} =
               Credentials.revoke("openai_codex", revoke_paths(dir, path))

      assert {:error, :oauth_resolution_failed} = Credentials.pin_oauth(:openai_codex, path)
      assert File.read!(path) == bytes
    end
  end

  @tag :tmp_dir
  test "install restores private permissions even when the tokens have not changed", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "oauth.json")
    tokens = tokens("same-token", nil)
    assert :ok = OAuth.write_oauth_file(tokens, path)
    File.chmod!(path, 0o644)
    assert :ok = OAuth.write_oauth_file(tokens, path)
    assert band(File.stat!(path).mode, 0o777) == 0o600
  end

  @spec revoke_paths(String.t(), String.t()) :: keyword()
  defp revoke_paths(dir, path), do: [config_dir: dir, oauth_path: path]

  @spec tokens(String.t(), integer() | nil) :: OAuth.token_response()
  defp tokens(access, expiry),
    do: %{
      access: access,
      refresh: "fixture-refresh",
      expires: expiry,
      account_id: "fixture-account"
    }

  @spec refresh_response(Plug.Conn.t(), pid()) :: Plug.Conn.t()
  defp refresh_response(conn, caller) do
    send(caller, {:refresh_started, self()})

    receive do
      :complete_refresh ->
        Req.Test.json(conn, %{
          "access_token" => "refreshed-token",
          "refresh_token" => "replacement-fixture-refresh",
          "expires_in" => 3600
        })
    after
      10_000 -> raise "timeout waiting for concurrent credential operation"
    end
  end
end
