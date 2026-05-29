defmodule MingaAgent.Tools.FetchUrlTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.FetchUrl

  test "fetches HTML, pins the request host, and keeps the original host for SNI and Host header" do
    html = """
    <!doctype html>
    <html>
      <head><style>.hidden { display: none; }</style><script>alert('no')</script></head>
      <body>
        <nav>Skip this</nav>
        <h1>API Docs</h1>
        <p>Use <code>fetch_url</code> to read docs &amp; examples.</p>
        <ul><li>First item</li><li>Second item</li></ul>
        <pre><code>mix test
    mix format</code></pre>
      </body>
    </html>
    """

    parent = self()

    fetcher = fn url, opts ->
      send(parent, {:fetch_args, url, opts})
      {:ok, %{status: 200, headers: %{"content-type" => "text/html; charset=utf-8"}, body: html}}
    end

    resolver = fn "docs.example" -> {:ok, [{93, 184, 216, 34}]} end

    assert {:ok, text} =
             FetchUrl.execute(
               %{"url" => "https://docs.example:8443/docs?token=secret"},
               fetcher,
               resolver
             )

    assert_receive {:fetch_args, "https://93.184.216.34:8443/docs?token=secret", opts}
    assert opts[:receive_timeout] == 10_000
    assert opts[:pool_timeout] == 10_000
    assert opts[:retry] == false
    assert opts[:max_retries] == 0
    assert opts[:decode_body] == false
    assert opts[:redirect] == false
    assert opts[:max_fetch_bytes] == 100_001
    assert opts[:connect_options][:hostname] == "docs.example"
    assert opts[:connect_options][:timeout] == 10_000
    assert {"host", "docs.example:8443"} in opts[:headers]
    assert text =~ "# API Docs"
    assert text =~ "Use `fetch_url` to read docs & examples."
    assert text =~ "- First item"
    assert text =~ "- Second item"
    assert text =~ "```\nmix test\nmix format\n```"
    refute text =~ "Skip this"
    refute text =~ "alert"
    refute text =~ ".hidden"
  end

  test "returns non-HTML text as-is" do
    fetcher = fn _url, _opts ->
      {:ok,
       %{status: 200, headers: %{"content-type" => ["application/json"]}, body: ~s({"ok":true})}}
    end

    resolver = fn _host -> {:ok, [{93, 184, 216, 34}]} end

    assert FetchUrl.execute(%{"url" => "https://example.test/data.json"}, fetcher, resolver) ==
             {:ok, ~s({"ok":true})}
  end

  test "enforces a wall-clock timeout when the fetcher blocks" do
    parent = self()

    fetcher = fn _url, _opts ->
      send(parent, :fetch_started)

      receive do
        :release -> {:ok, %{status: 200, headers: %{"content-type" => "text/plain"}, body: "ok"}}
      end
    end

    resolver = fn _host -> {:ok, [{93, 184, 216, 34}]} end

    start = System.monotonic_time(:millisecond)

    assert {:error, "failed to fetch https://example.test: request timed out after 200ms"} =
             FetchUrl.execute(
               %{"url" => "https://example.test", "timeout_ms" => 200},
               fetcher,
               resolver
             )

    elapsed = System.monotonic_time(:millisecond) - start
    assert elapsed < 1_000
    assert_receive :fetch_started, 500
    refute_receive :release, 50
  end

  test "resolver exceptions are contained and redacted" do
    fetcher = fn _url, _opts -> raise "should not fetch" end
    resolver = fn _host -> raise "resolver boom" end

    assert FetchUrl.execute(
             %{"url" => "https://user:secret@example.test/path?token=abc"},
             fetcher,
             resolver
           ) == {:error, "failed to fetch https://example.test/path: resolver boom"}
  end

  test "caps extracted text output without breaking UTF-8" do
    fetcher = fn _url, _opts ->
      {:ok, %{status: 200, headers: %{"content-type" => "text/plain"}, body: <<97, 255, 98>>}}
    end

    resolver = fn _host -> {:ok, [{93, 184, 216, 34}]} end

    assert {:ok, text} =
             FetchUrl.execute(
               %{"url" => "https://example.test", "max_bytes" => 5},
               fetcher,
               resolver
             )

    assert text == "a"
    assert String.valid?(text)
  end

  test "rejects timeout and max_bytes values above the hard caps" do
    fetcher = fn _url, _opts -> raise "should not fetch" end
    resolver = fn _host -> {:ok, [{93, 184, 216, 34}]} end

    assert FetchUrl.execute(
             %{"url" => "https://example.test", "timeout_ms" => 30_001},
             fetcher,
             resolver
           ) == {:error, "timeout_ms must be at most 30000"}

    assert FetchUrl.execute(
             %{"url" => "https://example.test", "max_bytes" => 100_001},
             fetcher,
             resolver
           ) == {:error, "max_bytes must be at most 100000"}
  end

  test "rejects DNS-resolved private hosts before fetching" do
    fetcher = fn _url, _opts -> raise "should not fetch" end
    resolver = fn "docs.example" -> {:ok, [{10, 0, 0, 1}]} end

    assert FetchUrl.execute(
             %{"url" => "https://docs.example/guide?token=secret"},
             fetcher,
             resolver
           ) == {:error, "blocked resolved URL host: docs.example -> 10.0.0.1"}
  end

  test "rejects DNS-resolved private IPv6 hosts before fetching" do
    fetcher = fn _url, _opts -> raise "should not fetch" end
    resolver = fn "docs.example" -> {:ok, [{0xFC00, 0, 0, 0, 0, 0, 0, 1}]} end

    assert FetchUrl.execute(
             %{"url" => "https://docs.example/guide"},
             fetcher,
             resolver
           ) == {:error, "blocked resolved URL host: docs.example -> fc00::1"}
  end

  test "rejects empty and nxdomain DNS results" do
    fetcher = fn _url, _opts -> raise "should not fetch" end
    empty_resolver = fn _host -> {:ok, []} end
    nxdomain_resolver = fn _host -> {:error, :nxdomain} end

    assert FetchUrl.execute(%{"url" => "https://docs.example/guide"}, fetcher, empty_resolver) ==
             {:error, "DNS lookup failed for docs.example: no DNS records found"}

    assert FetchUrl.execute(%{"url" => "https://docs.example/guide"}, fetcher, nxdomain_resolver) ==
             {:error, "DNS lookup failed for docs.example: no DNS records found"}
  end

  test "rejects local and private network URL hosts" do
    fetcher = fn _url, _opts -> raise "should not fetch" end

    assert FetchUrl.execute(%{"url" => "http://localhost"}, fetcher) ==
             {:error, "blocked URL host: localhost"}

    assert FetchUrl.execute(%{"url" => "http://127.0.0.1"}, fetcher) ==
             {:error, "blocked URL host: 127.0.0.1"}

    assert FetchUrl.execute(%{"url" => "http://10.0.0.4"}, fetcher) ==
             {:error, "blocked URL host: 10.0.0.4"}

    assert FetchUrl.execute(%{"url" => "http://169.254.169.254"}, fetcher) ==
             {:error, "blocked URL host: 169.254.169.254"}

    assert FetchUrl.execute(%{"url" => "http://[::1]"}, fetcher) ==
             {:error, "blocked URL host: ::1"}

    assert FetchUrl.execute(%{"url" => "http://[fc00::1]"}, fetcher) ==
             {:error, "blocked URL host: fc00::1"}

    assert FetchUrl.execute(%{"url" => "http://[fe80::1]"}, fetcher) ==
             {:error, "blocked URL host: fe80::1"}

    assert FetchUrl.execute(%{"url" => "http://[ff00::1]"}, fetcher) ==
             {:error, "blocked URL host: ff00::1"}

    assert FetchUrl.execute(%{"url" => "http://[::ffff:127.0.0.1]"}, fetcher) ==
             {:error, "blocked URL host: ::ffff:127.0.0.1"}

    assert FetchUrl.execute(%{"url" => "http://[::ffff:10.0.0.1]"}, fetcher) ==
             {:error, "blocked URL host: ::ffff:10.0.0.1"}

    assert FetchUrl.execute(%{"url" => "http://[::ffff:169.254.169.254]"}, fetcher) ==
             {:error, "blocked URL host: ::ffff:169.254.169.254"}
  end

  test "redacts userinfo and query strings in fetch errors" do
    fetcher = fn _url, _opts -> {:error, %{reason: :timeout}} end
    resolver = fn _host -> {:ok, [{93, 184, 216, 34}]} end

    assert FetchUrl.execute(
             %{"url" => "https://user:secret@example.test/path?token=abc"},
             fetcher,
             resolver
           ) == {:error, "failed to fetch https://example.test/path: request timed out"}
  end

  test "reports HTTP failures clearly" do
    fetcher = fn _url, _opts ->
      {:ok, %{status: 404, headers: %{"content-type" => "text/plain"}, body: "not found"}}
    end

    resolver = fn _host -> {:ok, [{93, 184, 216, 34}]} end

    assert FetchUrl.execute(%{"url" => "https://example.test/missing"}, fetcher, resolver) ==
             {:error, "fetch failed with HTTP 404: not found"}
  end

  test "validates URLs" do
    fetcher = fn _url, _opts -> raise "should not fetch" end

    assert FetchUrl.execute(%{}, fetcher) == {:error, "url is required"}

    assert FetchUrl.execute(%{"url" => "example.test"}, fetcher) ==
             {:error, "url must include http:// or https://"}

    assert FetchUrl.execute(%{"url" => "ftp://example.test"}, fetcher) ==
             {:error, "unsupported URL scheme: ftp"}
  end
end
