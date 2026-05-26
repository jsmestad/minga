defmodule MingaAgent.Tools.FetchUrl do
  @moduledoc """
  Fetches a URL and returns readable text for agent context.

  HTML responses are converted to simple Markdown-like text so documentation pages are readable without exposing raw markup. Non-HTML text responses are returned as-is. Results are capped to keep tool output from overwhelming the context window.
  """

  import Bitwise

  @default_timeout_ms 10_000
  @default_max_bytes 100_000
  @hard_timeout_ms 30_000
  @hard_max_bytes @default_max_bytes
  @allowed_schemes ~w(http https)
  @blocked_hosts ~w(localhost localhost.localdomain)

  @typedoc "Fetcher used by tests to avoid real network calls."
  @type fetcher :: (String.t(), keyword() -> {:ok, map()} | {:error, term()})

  @typedoc "Resolver used by tests to avoid real DNS calls."
  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})

  @typep fetch_result :: {:ok, String.t()} | {:error, term()}

  @typedoc "Validated request details used to pin the actual HTTP request."
  @type request_context :: %{
          request_url: String.t(),
          host_header: String.t(),
          connect_hostname: String.t()
        }

  @doc "Fetches the URL described by tool arguments."
  @spec execute(map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(args), do: execute(args, &fetch/2)

  @doc false
  @spec execute(map(), fetcher()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(args, fetcher), do: execute(args, fetcher, &resolve_host_addresses/1)

  @doc false
  @spec execute(map(), fetcher(), resolver()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"url" => url} = args, fetcher, resolver)
      when is_binary(url) and is_function(fetcher, 2) and is_function(resolver, 1) do
    with {:ok, timeout_ms} <- timeout_ms(args),
         {:ok, max_bytes} <- max_bytes(args) do
      timeout_ms
      |> run_with_deadline(url, fn ->
        fetch_pipeline(url, resolver, fetcher, timeout_ms, max_bytes)
      end)
      |> normalize_fetch_result(url)
    end
  end

  def execute(_args, _fetcher, _resolver), do: {:error, "url is required"}

  @spec fetch_pipeline(String.t(), resolver(), fetcher(), pos_integer(), pos_integer()) ::
          fetch_result()
  defp fetch_pipeline(url, resolver, fetcher, timeout_ms, max_bytes) do
    with {:ok, request_context} <- prepare_request_context(url, resolver),
         {:ok, response} <- perform_fetch(request_context, timeout_ms, max_bytes, fetcher) do
      response_to_result(response, max_bytes)
    end
  end

  @spec normalize_fetch_result(fetch_result(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp normalize_fetch_result({:error, message}, _url) when is_binary(message),
    do: {:error, message}

  defp normalize_fetch_result({:error, reason}, url),
    do: {:error, "failed to fetch #{redacted_url(url)}: #{format_error(reason)}"}

  defp normalize_fetch_result({:ok, message}, _url), do: {:ok, message}

  @spec run_with_deadline(pos_integer(), String.t(), (-> fetch_result())) :: fetch_result()
  defp run_with_deadline(timeout_ms, url, fun) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = safe_run(fun, url)
        send(parent, {:fetch_url_result, ref, result})
      end)

    receive do
      {:fetch_url_result, ^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        flush_down(monitor_ref, pid)
        {:error, {:timeout, timeout_ms}}
    end
  end

  @spec flush_down(reference(), pid()) :: :ok
  defp flush_down(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      20 -> :ok
    end
  end

  @spec safe_run((-> fetch_result()), String.t()) :: fetch_result()
  defp safe_run(fun, url) do
    fun.()
  rescue
    exception ->
      {:error, "failed to fetch #{redacted_url(url)}: #{Exception.message(exception)}"}
  catch
    kind, reason ->
      {:error, "failed to fetch #{redacted_url(url)}: #{format_error({kind, reason})}"}
  end

  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp fetch(url, opts) do
    max_fetch_bytes = Keyword.fetch!(opts, :max_fetch_bytes)

    opts =
      opts
      |> Keyword.delete(:max_fetch_bytes)
      |> Keyword.put(:into, bounded_body_collector(max_fetch_bytes))

    Req.get(url, opts)
  end

  @spec perform_fetch(request_context(), pos_integer(), pos_integer(), fetcher()) ::
          {:ok, map()} | {:error, term()}
  defp perform_fetch(
         %{request_url: request_url} = request_context,
         timeout_ms,
         max_bytes,
         fetcher
       ) do
    fetcher.(request_url, request_opts(request_context, timeout_ms, max_bytes))
  end

  @spec request_opts(request_context(), pos_integer(), pos_integer()) :: keyword()
  defp request_opts(
         %{host_header: host_header, connect_hostname: connect_hostname},
         timeout_ms,
         max_bytes
       ) do
    [
      headers: [{"host", host_header}],
      connect_options: [hostname: connect_hostname, timeout: timeout_ms],
      receive_timeout: timeout_ms,
      pool_timeout: timeout_ms,
      retry: false,
      max_retries: 0,
      decode_body: false,
      redirect: false,
      max_fetch_bytes: max_bytes + 1
    ]
  end

  @spec prepare_request_context(String.t(), resolver()) ::
          {:ok, request_context()} | {:error, String.t()}
  defp prepare_request_context(url, resolver) do
    url
    |> URI.parse()
    |> validate_uri(url, resolver)
  end

  @spec build_request_context(URI.t(), String.t(), String.t()) :: {:ok, request_context()}
  defp build_request_context(uri, request_host, connect_hostname) do
    request_uri = %{uri | host: request_host}

    {:ok,
     %{
       request_url: URI.to_string(request_uri),
       host_header: host_header_value(uri),
       connect_hostname: connect_hostname
     }}
  end

  @spec host_header_value(URI.t()) :: String.t()
  defp host_header_value(%URI{host: host, port: port, scheme: scheme}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    if is_nil(port) or URI.default_port(scheme) == port do
      host
    else
      "#{host}:#{port}"
    end
  end

  @spec bounded_body_collector(pos_integer()) :: function()
  defp bounded_body_collector(max_fetch_bytes) do
    fn {:data, data}, {req, resp} ->
      body = resp |> Map.get(:body, "") |> response_body_to_binary()
      next_body = body <> data
      resp = %{resp | body: utf8_prefix(next_body, max_fetch_bytes)}

      if byte_size(next_body) > max_fetch_bytes,
        do: {:halt, {req, resp}},
        else: {:cont, {req, resp}}
    end
  end

  @spec response_body_to_binary(term()) :: binary()
  defp response_body_to_binary(body) when is_binary(body), do: body
  defp response_body_to_binary(_body), do: ""

  @spec validate_uri(URI.t(), String.t(), resolver()) ::
          {:ok, request_context()} | {:error, String.t()}
  defp validate_uri(%URI{scheme: scheme, host: host} = uri, url, resolver)
       when scheme in @allowed_schemes and is_binary(host) and host != "" do
    if String.contains?(host, " ") do
      {:error, "invalid URL: #{redacted_url(url)}"}
    else
      validate_host(uri, host, resolver)
    end
  end

  defp validate_uri(%URI{scheme: nil}, _url, _resolver),
    do: {:error, "url must include http:// or https://"}

  defp validate_uri(%URI{scheme: scheme}, _url, _resolver) when scheme not in @allowed_schemes,
    do: {:error, "unsupported URL scheme: #{scheme}"}

  defp validate_uri(_uri, url, _resolver), do: {:error, "invalid URL: #{redacted_url(url)}"}

  @spec validate_host(URI.t(), String.t(), resolver()) ::
          {:ok, request_context()} | {:error, String.t()}
  defp validate_host(uri, host, resolver) do
    normalized = String.downcase(host)
    validate_unblocked_host(blocked_hostname?(normalized), uri, host, normalized, resolver)
  end

  @spec validate_unblocked_host(boolean(), URI.t(), String.t(), String.t(), resolver()) ::
          {:ok, request_context()} | {:error, String.t()}
  defp validate_unblocked_host(true, _uri, host, _normalized, _resolver),
    do: {:error, "blocked URL host: #{host}"}

  defp validate_unblocked_host(false, uri, host, normalized, resolver) do
    normalized
    |> String.to_charlist()
    |> :inet.parse_address()
    |> validate_host_address(uri, host, resolver)
  end

  @spec validate_host_address(
          {:ok, :inet.ip_address()} | {:error, :einval},
          URI.t(),
          String.t(),
          resolver()
        ) ::
          {:ok, request_context()} | {:error, String.t()}
  defp validate_host_address({:ok, address}, uri, host, _resolver) do
    case validate_public_ip(address, host) do
      :ok -> build_request_context(uri, host, host)
      {:error, message} -> {:error, message}
    end
  end

  defp validate_host_address({:error, :einval}, uri, host, resolver),
    do: validate_resolved_host(uri, host, resolver)

  @spec blocked_hostname?(String.t()) :: boolean()
  defp blocked_hostname?(host),
    do: host in @blocked_hosts or String.ends_with?(host, ".localhost")

  @spec validate_resolved_host(URI.t(), String.t(), resolver()) ::
          {:ok, request_context()} | {:error, String.t()}
  defp validate_resolved_host(uri, host, resolver) do
    case resolver.(host) do
      {:ok, []} ->
        {:error, "DNS lookup failed for #{host}: no DNS records found"}

      {:ok, addresses} when is_list(addresses) ->
        validate_resolved_addresses(uri, host, addresses)

      {:error, reason} ->
        {:error, "DNS lookup failed for #{host}: #{format_dns_error(reason)}"}

      other ->
        {:error, "DNS lookup failed for #{host}: #{inspect(other)}"}
    end
  end

  @spec validate_resolved_addresses(URI.t(), String.t(), [:inet.ip_address()]) ::
          {:ok, request_context()} | {:error, String.t()}
  defp validate_resolved_addresses(uri, host, addresses) do
    case Enum.find(addresses, &private_or_reserved_ip?/1) do
      nil ->
        address = List.first(addresses)
        build_request_context(uri, format_ip_address(address), host)

      address ->
        {:error, "blocked resolved URL host: #{host} -> #{format_ip_address(address)}"}
    end
  end

  @spec resolve_host_addresses(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  defp resolve_host_addresses(host) do
    host_chars = String.to_charlist(host)

    addresses =
      Enum.uniq(:inet_res.lookup(host_chars, :in, :a) ++ :inet_res.lookup(host_chars, :in, :aaaa))

    case addresses do
      [] -> {:error, :nxdomain}
      _ -> {:ok, addresses}
    end
  end

  @spec validate_public_ip(:inet.ip_address(), String.t()) :: :ok | {:error, String.t()}
  defp validate_public_ip(address, host) do
    if private_or_reserved_ip?(address),
      do: {:error, "blocked URL host: #{host}"},
      else: :ok
  end

  @spec private_or_reserved_ip?(:inet.ip_address()) :: boolean()
  defp private_or_reserved_ip?({first, second, _third, _fourth}) do
    first in [0, 10, 127] or first >= 224 or
      {first, second} in [
        {169, 254},
        {192, 168},
        {192, 0},
        {198, 18},
        {198, 19},
        {198, 51},
        {203, 0}
      ] or (first == 172 and second in 16..31) or (first == 100 and second in 64..127)
  end

  defp private_or_reserved_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_or_reserved_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_or_reserved_ip?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: private_or_reserved_ip?(embedded_ipv4(high, low))

  defp private_or_reserved_ip?({0, 0, 0, 0, 0, 0, high, low}),
    do: private_or_reserved_ip?(embedded_ipv4(high, low))

  defp private_or_reserved_ip?(
         {first, _second, _third, _fourth, _fifth, _sixth, _seventh, _eighth}
       )
       when (first &&& 0xFE00) == 0xFC00, do: true

  defp private_or_reserved_ip?(
         {first, _second, _third, _fourth, _fifth, _sixth, _seventh, _eighth}
       )
       when (first &&& 0xFFC0) == 0xFE80, do: true

  defp private_or_reserved_ip?(
         {first, _second, _third, _fourth, _fifth, _sixth, _seventh, _eighth}
       )
       when (first &&& 0xFF00) == 0xFF00, do: true

  defp private_or_reserved_ip?(_address), do: false

  @spec embedded_ipv4(non_neg_integer(), non_neg_integer()) :: :inet.ip4_address()
  defp embedded_ipv4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  @spec format_ip_address(:inet.ip_address()) :: String.t()
  defp format_ip_address(address), do: address |> :inet.ntoa() |> to_string()

  @spec format_dns_error(term()) :: String.t()
  defp format_dns_error(:nxdomain), do: "no DNS records found"
  defp format_dns_error(reason), do: format_error(reason)

  @spec timeout_ms(map()) :: {:ok, pos_integer()} | {:error, String.t()}
  defp timeout_ms(args) do
    case positive_integer_arg(args, "timeout_ms", @default_timeout_ms) do
      {:ok, value} when value <= @hard_timeout_ms -> {:ok, value}
      {:ok, _value} -> {:error, "timeout_ms must be at most #{@hard_timeout_ms}"}
      {:error, _message} = error -> error
    end
  end

  @spec max_bytes(map()) :: {:ok, pos_integer()} | {:error, String.t()}
  defp max_bytes(args) do
    case positive_integer_arg(args, "max_bytes", @default_max_bytes) do
      {:ok, value} when value <= @hard_max_bytes -> {:ok, value}
      {:ok, _value} -> {:error, "max_bytes must be at most #{@hard_max_bytes}"}
      {:error, _message} = error -> error
    end
  end

  @spec positive_integer_arg(map(), String.t(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, String.t()}
  defp positive_integer_arg(args, key, default) do
    case Map.get(args, key) do
      nil -> {:ok, default}
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) -> parse_positive_integer(value, key)
      _value -> {:error, "#{key} must be a positive integer"}
    end
  end

  @spec parse_positive_integer(String.t(), String.t()) ::
          {:ok, pos_integer()} | {:error, String.t()}
  defp parse_positive_integer(value, key) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, "#{key} must be a positive integer"}
    end
  end

  @spec response_to_result(map(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  defp response_to_result(%{status: status} = response, max_bytes)
       when is_integer(status) and status >= 200 and status < 300 do
    body = response |> Map.get(:body, "") |> body_to_text()
    content_type = response |> Map.get(:headers, %{}) |> content_type()
    text = if html_response?(content_type, body), do: html_to_text(body), else: body
    cap_text(text, max_bytes)
  end

  defp response_to_result(%{status: status} = response, _max_bytes) when is_integer(status) do
    body = response |> Map.get(:body, "") |> body_to_text() |> trim_for_error()
    {:error, "fetch failed with HTTP #{status}: #{body}"}
  end

  defp response_to_result(_response, _max_bytes),
    do: {:error, "fetch failed: invalid HTTP response"}

  @spec body_to_text(term()) :: String.t()
  defp body_to_text(body) when is_binary(body), do: trim_invalid_utf8(body)
  defp body_to_text(body), do: inspect(body, pretty: true, limit: :infinity)

  @spec content_type(map() | [{String.t(), String.t()}]) :: String.t()
  defp content_type(headers) when is_map(headers) do
    headers
    |> Enum.find_value("", fn {key, value} ->
      matching_header_value(key, value, "content-type")
    end)
    |> normalize_header_value()
  end

  defp content_type(headers) when is_list(headers) do
    headers
    |> Enum.find_value("", fn {key, value} ->
      matching_header_value(key, value, "content-type")
    end)
    |> normalize_header_value()
  end

  defp content_type(_headers), do: ""

  @spec matching_header_value(term(), term(), String.t()) :: term() | nil
  defp matching_header_value(key, value, target) when is_binary(key) do
    if String.downcase(key) == target, do: value, else: nil
  end

  defp matching_header_value(_key, _value, _target), do: nil

  @spec normalize_header_value(term()) :: String.t()
  defp normalize_header_value([value | _rest]) when is_binary(value), do: String.downcase(value)
  defp normalize_header_value(value) when is_binary(value), do: String.downcase(value)
  defp normalize_header_value(_value), do: ""

  @spec html_response?(String.t(), String.t()) :: boolean()
  defp html_response?(content_type, _body) when is_binary(content_type) and content_type != "" do
    String.contains?(content_type, "html")
  end

  defp html_response?(_content_type, body) do
    trimmed = body |> String.trim_leading() |> String.downcase()
    String.starts_with?(trimmed, ["<!doctype html", "<html"])
  end

  @spec html_to_text(String.t()) :: String.t()
  defp html_to_text(html) do
    html
    |> remove_ignored_html()
    |> replace_pre_blocks()
    |> replace_inline_code()
    |> replace_headings()
    |> replace_structural_tags()
    |> strip_remaining_tags()
    |> decode_entities()
    |> normalize_text_with_code_fences()
  end

  @spec remove_ignored_html(String.t()) :: String.t()
  defp remove_ignored_html(html) do
    Regex.replace(
      ~r/<(script|style|nav|header|footer|svg|noscript|form|aside)\b[^>]*>.*?<\/\1>/is,
      html,
      ""
    )
  end

  @spec replace_pre_blocks(String.t()) :: String.t()
  defp replace_pre_blocks(html) do
    Regex.replace(~r/<pre\b[^>]*>(.*?)<\/pre>/is, html, fn _match, code ->
      code = code |> strip_remaining_tags() |> decode_entities() |> String.trim("\n")
      "\n\n```\n#{code}\n```\n\n"
    end)
  end

  @spec replace_inline_code(String.t()) :: String.t()
  defp replace_inline_code(html) do
    Regex.replace(~r/<code\b[^>]*>(.*?)<\/code>/is, html, fn _match, code ->
      code = code |> strip_remaining_tags() |> decode_entities() |> String.trim()
      "`#{code}`"
    end)
  end

  @spec replace_headings(String.t()) :: String.t()
  defp replace_headings(html) do
    Regex.replace(~r/<h([1-6])\b[^>]*>(.*?)<\/h\1>/is, html, fn _match, level, text ->
      marks = String.duplicate("#", String.to_integer(level))
      "\n\n#{marks} #{text}\n\n"
    end)
  end

  @spec replace_structural_tags(String.t()) :: String.t()
  defp replace_structural_tags(html) do
    html
    |> then(&Regex.replace(~r/<br\s*\/?\s*>/i, &1, "\n"))
    |> then(&Regex.replace(~r/<li\b[^>]*>/i, &1, "\n- "))
    |> then(&Regex.replace(~r/<\/(li|ul|ol)>/i, &1, "\n"))
    |> then(&Regex.replace(~r/<\/(p|div|section|article|blockquote|tr)>/i, &1, "\n\n"))
    |> then(&Regex.replace(~r/<(p|div|section|article|blockquote|tr)\b[^>]*>/i, &1, "\n\n"))
    |> then(&Regex.replace(~r/<\/(td|th)>/i, &1, "\t"))
  end

  @spec strip_remaining_tags(String.t()) :: String.t()
  defp strip_remaining_tags(html), do: Regex.replace(~r/<[^>]+>/, html, "")

  @spec decode_entities(String.t()) :: String.t()
  defp decode_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> decode_decimal_entities()
    |> decode_hex_entities()
  end

  @spec decode_decimal_entities(String.t()) :: String.t()
  defp decode_decimal_entities(text) do
    Regex.replace(~r/&#(\d+);/, text, fn _match, code -> codepoint_to_string(code, 10) end)
  end

  @spec decode_hex_entities(String.t()) :: String.t()
  defp decode_hex_entities(text) do
    Regex.replace(~r/&#x([0-9a-fA-F]+);/, text, fn _match, code ->
      codepoint_to_string(code, 16)
    end)
  end

  @spec codepoint_to_string(String.t(), 10 | 16) :: String.t()
  defp codepoint_to_string(code, base) do
    case Integer.parse(code, base) do
      {integer, ""} when integer in 0..0x10FFFF -> <<integer::utf8>>
      _ -> ""
    end
  rescue
    ArgumentError -> ""
  end

  @spec normalize_text_with_code_fences(String.t()) :: String.t()
  defp normalize_text_with_code_fences(text) do
    text
    |> String.split("```", trim: false)
    |> Enum.with_index()
    |> Enum.map_join("```", fn {part, index} -> normalize_text_part(part, rem(index, 2)) end)
    |> String.trim()
  end

  @spec normalize_text_part(String.t(), 0 | 1) :: String.t()
  defp normalize_text_part(part, 1), do: part

  defp normalize_text_part(part, 0) do
    part
    |> String.split("\n")
    |> Enum.map(&normalize_text_line/1)
    |> collapse_blank_lines([])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  @spec normalize_text_line(String.t()) :: String.t()
  defp normalize_text_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/[ \t]+/, " ")
  end

  @spec collapse_blank_lines([String.t()], [String.t()]) :: [String.t()]
  defp collapse_blank_lines([], acc), do: acc
  defp collapse_blank_lines(["", "" | rest], acc), do: collapse_blank_lines(["" | rest], acc)
  defp collapse_blank_lines([line | rest], acc), do: collapse_blank_lines(rest, [line | acc])

  @spec cap_text(String.t(), pos_integer()) :: {:ok, String.t()}
  defp cap_text(text, max_bytes) when byte_size(text) <= max_bytes, do: {:ok, text}

  defp cap_text(text, max_bytes) do
    prefix = utf8_prefix(text, max_bytes)
    {:ok, prefix <> "\n\n[truncated at #{div(max_bytes, 1000)}KB]"}
  end

  @spec utf8_prefix(binary(), pos_integer()) :: binary()
  defp utf8_prefix(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp utf8_prefix(binary, max_bytes),
    do: binary |> binary_part(0, max_bytes) |> trim_invalid_utf8()

  @spec trim_invalid_utf8(binary()) :: String.t()
  defp trim_invalid_utf8(binary) when byte_size(binary) == 0, do: ""

  defp trim_invalid_utf8(binary) do
    if String.valid?(binary),
      do: binary,
      else: binary |> binary_part(0, byte_size(binary) - 1) |> trim_invalid_utf8()
  end

  @spec trim_for_error(String.t()) :: String.t()
  defp trim_for_error(body) do
    body
    |> utf8_prefix(500)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> error_preview()
  end

  @spec error_preview(String.t()) :: String.t()
  defp error_preview(""), do: "no response body"
  defp error_preview(body), do: body

  @spec redacted_url(String.t()) :: String.t()
  defp redacted_url(url) do
    url
    |> URI.parse()
    |> redacted_uri()
    |> URI.to_string()
  end

  @spec redacted_uri(URI.t()) :: URI.t()
  defp redacted_uri(%URI{} = uri), do: %{uri | userinfo: nil, query: nil, fragment: nil}

  @spec format_error(term()) :: String.t()
  defp format_error({:timeout, timeout_ms}), do: "request timed out after #{timeout_ms}ms"
  defp format_error({:exit, reason}), do: format_error(reason)
  defp format_error({:throw, reason}), do: format_error(reason)
  defp format_error(%Req.TransportError{reason: :timeout}), do: "request timed out"
  defp format_error(%Req.TransportError{reason: :nxdomain}), do: "DNS lookup failed"
  defp format_error(%Req.TransportError{reason: reason}), do: inspect(reason)
  defp format_error(%{reason: :timeout}), do: "request timed out"
  defp format_error(%{reason: :nxdomain}), do: "DNS lookup failed"
  defp format_error(%{reason: reason}), do: inspect(reason)
  defp format_error(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format_error(reason), do: inspect(reason)
end
