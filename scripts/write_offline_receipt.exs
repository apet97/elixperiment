# Writes tmp/offline_acceptance_receipt.json for the offline acceptance gate.
# Run with `mix run scripts/write_offline_receipt.exs` so Jason is available.

defmodule PumbleAutomation.OfflineReceipt do
  @schema_version 2
  # Elixir 1.20 prints `Result: 2177 passed (1 doctest, 2176 tests)`.
  # Older ExUnit prints `2172 tests, 1 doctest, 0 failures`.
  @result_with_doctest ~r/Result:\s+\d+ passed \((\d+) doctests?, (\d+) tests?\)/
  @result_simple ~r/Result:\s+(\d+) passed\b/
  @classic_summary ~r/(\d+) tests?(?:, (\d+) doctests?)?, (\d+) failures?/

  def write! do
    path = receipt_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(payload(), pretty: true) <> "\n")
    path
  end

  def payload do
    {test_count, doctest_count} = parse_counts()

    %{
      schema_version: @schema_version,
      git_sha: git_sha(),
      lockfile_sha256: lockfile_sha256(),
      elixir: System.version(),
      otp: System.otp_release(),
      recorded_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      test_count: test_count,
      doctest_count: doctest_count,
      live_certification: "excluded",
      docker: docker_status(),
      container_revision: container_revision(),
      working_tree: working_tree_status(),
      gates_passed: String.split(System.get_env("VERIFY_GATES", ""), ",", trim: true)
    }
  end

  defp receipt_path do
    System.get_env("VERIFY_RECEIPT_PATH") || Path.expand("tmp/offline_acceptance_receipt.json")
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp lockfile_sha256 do
    :crypto.hash(:sha256, File.read!("mix.lock")) |> Base.encode16(case: :lower)
  end

  defp parse_counts do
    text = summary_text()
    reject_failed_run!(text)

    cond do
      match = List.last(Regex.scan(@result_with_doctest, text)) ->
        [_, doctests, tests] = match
        {String.to_integer(tests), String.to_integer(doctests)}

      match = List.last(Regex.scan(@classic_summary, text)) ->
        case match do
          [_, tests, _failures] ->
            {String.to_integer(tests), 0}

          [_, tests, doctests, _failures] ->
            {String.to_integer(tests), String.to_integer(doctests)}
        end

      match = List.last(Regex.scan(@result_simple, text)) ->
        [_, tests] = match
        {String.to_integer(tests), 0}

      true ->
        Mix.raise("""
        offline receipt: no ExUnit summary in VERIFY_TEST_SUMMARY or #{test_log_path()}.
        Expected a line like "Result: 2177 passed (1 doctest, 2176 tests)" or
        "2172 tests, 1 doctest, 0 failures".
        """)
    end
  end

  defp reject_failed_run!(text) do
    if Regex.match?(~r/Failed:|Result:\s+\d+\/\d+/, text) or
         Regex.match?(~r/\d+ tests?.*, [1-9]\d* failures?/, text) do
      Mix.raise("offline receipt: ExUnit summary reports failures")
    end
  end

  defp summary_text do
    case System.get_env("VERIFY_TEST_SUMMARY") do
      summary when is_binary(summary) and summary != "" ->
        strip_ansi(summary)

      _ ->
        case File.read(test_log_path()) do
          {:ok, body} -> strip_ansi(body)
          {:error, _} -> ""
        end
    end
  end

  defp test_log_path do
    System.get_env("VERIFY_TEST_LOG") || Path.expand("tmp/verify-test.log")
  end

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\[[0-9;]*[A-Za-z]/, "")
  end

  defp docker_status do
    case System.get_env("VERIFY_DOCKER_STATUS") do
      "smoke_passed" -> "smoke_passed"
      value -> Mix.raise("offline receipt: invalid or missing VERIFY_DOCKER_STATUS: #{inspect(value)}")
    end
  end

  defp container_revision do
    revision = System.get_env("VERIFY_CONTAINER_REVISION")

    if revision == git_sha() do
      revision
    else
      Mix.raise("offline receipt: container revision is not the tested commit")
    end
  end

  defp working_tree_status do
    case System.get_env("VERIFY_WORKING_TREE_STATUS") do
      "clean" -> "clean"
      value -> Mix.raise("offline receipt: invalid or missing working-tree status: #{inspect(value)}")
    end
  end
end

path = PumbleAutomation.OfflineReceipt.write!()
IO.puts("wrote #{path}")
