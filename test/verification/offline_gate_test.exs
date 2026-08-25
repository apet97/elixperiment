defmodule PumbleAutomation.Verification.OfflineGateTest do
  @moduledoc """
  The offline acceptance script, receipt schema, and skip scanner.
  """

  use ExUnit.Case, async: true

  @receipt_keys ~w(
    schema_version git_sha lockfile_sha256 elixir otp recorded_at
    test_count doctest_count live_certification docker container_image_id
    container_revision working_tree gates_passed
  )

  @verify Path.expand("../../scripts/verify.sh", __DIR__)
  @ci Path.expand("../../.github/workflows/ci.yml", __DIR__)
  @docs Path.expand("../../docs/engineering/verification.md", __DIR__)
  @forbid Path.expand("../../scripts/forbid_skipped_tests.sh", __DIR__)
  @writer Path.expand("../../scripts/write_offline_receipt.exs", __DIR__)
  @container_smoke Path.expand("../../scripts/container-smoke.sh", __DIR__)

  test "verify.sh names every offline gate and excludes live certification" do
    source = File.read!(@verify)

    for gate <- [
          "mix format --check-formatted",
          "mix compile --warnings-as-errors",
          "forbid_skipped_tests",
          "ecto.drop",
          "mix test",
          "mix credo --strict",
          "mix dialyzer",
          "mix sobelow --config",
          "mix hex.audit",
          "deps.unlock --check-unused",
          "mix assets.build",
          "git diff --check",
          "verify-ui.sh",
          "gitleaks detect",
          "mix release",
          "release-migration-integration.sh",
          "container-smoke.sh",
          "write_offline_receipt"
        ] do
      assert source =~ gate, "verify.sh is missing #{inspect(gate)}"
    end

    assert source =~ "live certification: excluded"
    assert source =~ "all 19 gates passed"
    assert source =~ "VERIFY_TEST_LOG"
    assert source =~ ~s(unlink "$offline_receipt")
    assert source =~ "VERIFY_DOCKER_STATUS=\"smoke_passed\""
    assert source =~ "VERIFY_CONTAINER_IMAGE_ID"
    assert source =~ "container-smoke-image-id"
    assert source =~ "docker image inspect --format '{{.Id}}'"
    assert source =~ "^sha256:[0-9a-f]{64}$"
    assert source =~ "git status --porcelain"
    refute source =~ "^Result:"
    refute source =~ "PUMBLE_API_KEY"
    refute source =~ "PUMBLE_CLIENT_SECRET"
  end

  test "container smoke captures one immutable image ID and exercises that ID" do
    source = File.read!(@container_smoke)

    assert source =~ ~S|image_id=$(docker image inspect --format '{{.Id}}' "$image")|
    assert source =~ ~S|docker history --no-trunc "$image_id"|
    assert source =~ ~S|printf '%s\n' "$image_id" >"$result_tmp"|
    assert length(Regex.scan(~r/"\$image"/, source)) == 4

    assert source =~ """
           --format json \\
               "$image_id"
           """

    refute source =~ """
           --format json \\
               "$image"
           """
  end

  test "CI uploads the receipt and runs the same verify.sh" do
    source = File.read!(@ci)
    assert source =~ "./scripts/verify.sh"
    assert source =~ "offline-acceptance-receipt"
    assert source =~ "tmp/offline_acceptance_receipt.json"
    assert source =~ "gitleaks"
  end

  test "the verification guide documents the one command and the receipt" do
    source = File.read!(@docs)
    assert source =~ "./scripts/verify.sh"
    assert source =~ "./scripts/verify-ui.sh"
    assert source =~ "tmp/offline_acceptance_receipt.json"
    assert source =~ "live certification"
    assert source =~ "schema_version"
    assert source =~ "all 19 gates passed"
  end

  test "the receipt schema has the required keys and excludes live work" do
    receipt = %{
      "schema_version" => 3,
      "git_sha" => String.duplicate("a", 40),
      "lockfile_sha256" => String.duplicate("b", 64),
      "elixir" => "1.20.3",
      "otp" => "29",
      "recorded_at" => "2026-08-22T20:00:00Z",
      "test_count" => 1,
      "doctest_count" => 1,
      "live_certification" => "excluded",
      "docker" => "smoke_passed",
      "container_image_id" => "sha256:" <> String.duplicate("c", 64),
      "container_revision" => String.duplicate("a", 40),
      "working_tree" => "clean",
      "gates_passed" => ["format", "test"]
    }

    encoded = Jason.encode!(receipt)
    decoded = Jason.decode!(encoded)
    assert Enum.sort(Map.keys(decoded)) == Enum.sort(@receipt_keys)
    assert decoded["live_certification"] == "excluded"
    assert decoded["schema_version"] == 3
    assert decoded["container_image_id"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert File.read!(@writer) =~ "live_certification: \"excluded\""
  end

  test "the receipt writer parses a stock ExUnit summary and fails closed otherwise" do
    log = Path.join(System.tmp_dir!(), "verify-test-#{System.unique_integer([:positive])}.log")
    out = Path.join(System.tmp_dir!(), "receipt-#{System.unique_integer([:positive])}.json")
    empty = Path.join(System.tmp_dir!(), "verify-empty-#{System.unique_integer([:positive])}.log")
    docker_dir = fake_docker_dir()
    image_id = "sha256:" <> String.duplicate("c", 64)
    sha = git_sha()
    path = docker_dir <> ":" <> System.get_env("PATH", "")

    File.write!(log, """
    Finished in 63.3 seconds (14.6s async, 48.7s sync)

    \e[32mResult: 2177 passed (1 doctest, 2176 tests)\e[0m
    """)

    File.write!(empty, "Finished in 0.0 seconds\n")

    try do
      {output, status} =
        System.cmd("mix", ["run", @writer],
          env: [
            {"PATH", path},
            {"MIX_ENV", "test"},
            {"VERIFY_TEST_SUMMARY", nil},
            {"VERIFY_TEST_LOG", log},
            {"VERIFY_RECEIPT_PATH", out},
            {"VERIFY_GATES", "format,test"},
            {"VERIFY_DOCKER_STATUS", "smoke_passed"},
            {"VERIFY_CONTAINER_IMAGE_ID", image_id},
            {"VERIFY_CONTAINER_IMAGE_TAG", "pumble-automation:offline-test"},
            {"VERIFY_CONTAINER_REVISION", sha},
            {"TEST_DOCKER_IMAGE_ID", image_id},
            {"TEST_DOCKER_TAG_IMAGE_ID", image_id},
            {"TEST_DOCKER_REVISION", sha},
            {"VERIFY_WORKING_TREE_STATUS", "clean"}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      receipt = Jason.decode!(File.read!(out))
      assert receipt["test_count"] == 2176
      assert receipt["doctest_count"] == 1
      assert receipt["live_certification"] == "excluded"
      assert receipt["container_image_id"] == image_id
      assert receipt["container_revision"] == receipt["git_sha"]
      assert receipt["working_tree"] == "clean"

      File.write!(log, """
      Finished in 12.3 seconds (10.1s async, 2.2s sync)
      2172 tests, 1 doctest, 0 failures
      """)

      {classic_out, classic_status} =
        System.cmd("mix", ["run", @writer],
          env: [
            {"PATH", path},
            {"MIX_ENV", "test"},
            {"VERIFY_TEST_SUMMARY", nil},
            {"VERIFY_TEST_LOG", log},
            {"VERIFY_RECEIPT_PATH", out},
            {"VERIFY_GATES", "format,test"},
            {"VERIFY_DOCKER_STATUS", "smoke_passed"},
            {"VERIFY_CONTAINER_IMAGE_ID", image_id},
            {"VERIFY_CONTAINER_IMAGE_TAG", "pumble-automation:offline-test"},
            {"VERIFY_CONTAINER_REVISION", sha},
            {"TEST_DOCKER_IMAGE_ID", image_id},
            {"TEST_DOCKER_TAG_IMAGE_ID", image_id},
            {"TEST_DOCKER_REVISION", sha},
            {"VERIFY_WORKING_TREE_STATUS", "clean"}
          ],
          stderr_to_stdout: true
        )

      assert classic_status == 0, classic_out
      classic = Jason.decode!(File.read!(out))
      assert classic["test_count"] == 2172
      assert classic["doctest_count"] == 1

      File.write!(log, "10 tests, 2 failures\n")

      {failed_summary, failed_status} =
        System.cmd("mix", ["run", @writer],
          env: [
            {"PATH", path},
            {"MIX_ENV", "test"},
            {"VERIFY_TEST_SUMMARY", nil},
            {"VERIFY_TEST_LOG", log},
            {"VERIFY_RECEIPT_PATH", out},
            {"VERIFY_GATES", "format"},
            {"VERIFY_DOCKER_STATUS", "smoke_passed"},
            {"VERIFY_CONTAINER_IMAGE_ID", image_id},
            {"VERIFY_CONTAINER_IMAGE_TAG", "pumble-automation:offline-test"},
            {"VERIFY_CONTAINER_REVISION", sha},
            {"TEST_DOCKER_IMAGE_ID", image_id},
            {"TEST_DOCKER_TAG_IMAGE_ID", image_id},
            {"TEST_DOCKER_REVISION", sha},
            {"VERIFY_WORKING_TREE_STATUS", "clean"}
          ],
          stderr_to_stdout: true
        )

      assert failed_status != 0
      assert failed_summary =~ "reports failures"

      {failed, nonzero} =
        System.cmd("mix", ["run", @writer],
          env: [
            {"PATH", path},
            {"MIX_ENV", "test"},
            {"VERIFY_TEST_SUMMARY", nil},
            {"VERIFY_TEST_LOG", empty},
            {"VERIFY_RECEIPT_PATH", out},
            {"VERIFY_GATES", "format"},
            {"VERIFY_DOCKER_STATUS", "smoke_passed"},
            {"VERIFY_CONTAINER_IMAGE_ID", image_id},
            {"VERIFY_CONTAINER_IMAGE_TAG", "pumble-automation:offline-test"},
            {"VERIFY_CONTAINER_REVISION", sha},
            {"TEST_DOCKER_IMAGE_ID", image_id},
            {"TEST_DOCKER_TAG_IMAGE_ID", image_id},
            {"TEST_DOCKER_REVISION", sha},
            {"VERIFY_WORKING_TREE_STATUS", "clean"}
          ],
          stderr_to_stdout: true
        )

      assert nonzero != 0
      assert failed =~ "no ExUnit summary"
    after
      File.rm(log)
      File.rm(out)
      File.rm(empty)
      File.rm_rf(docker_dir)
    end
  end

  test "the receipt writer validates the exercised Docker image binding before writing" do
    log = Path.join(System.tmp_dir!(), "verify-image-#{System.unique_integer([:positive])}.log")
    docker_dir = fake_docker_dir()
    image_id = "sha256:" <> String.duplicate("c", 64)
    other_image_id = "sha256:" <> String.duplicate("d", 64)
    sha = git_sha()

    File.write!(log, "Result: 1 passed\n")

    base_env = [
      {"PATH", docker_dir <> ":" <> System.get_env("PATH", "")},
      {"MIX_ENV", "test"},
      {"VERIFY_TEST_SUMMARY", nil},
      {"VERIFY_TEST_LOG", log},
      {"VERIFY_GATES", "container-smoke"},
      {"VERIFY_DOCKER_STATUS", "smoke_passed"},
      {"VERIFY_CONTAINER_IMAGE_ID", image_id},
      {"VERIFY_CONTAINER_IMAGE_TAG", "pumble-automation:offline-test"},
      {"VERIFY_CONTAINER_REVISION", sha},
      {"TEST_DOCKER_IMAGE_ID", image_id},
      {"TEST_DOCKER_TAG_IMAGE_ID", image_id},
      {"TEST_DOCKER_REVISION", sha},
      {"TEST_DOCKER_FAIL", nil},
      {"VERIFY_WORKING_TREE_STATUS", "clean"}
    ]

    cases = [
      {"missing image ID", [{"VERIFY_CONTAINER_IMAGE_ID", nil}],
       "invalid or missing VERIFY_CONTAINER_IMAGE_ID"},
      {"malformed image ID", [{"VERIFY_CONTAINER_IMAGE_ID", "sha256:ABC"}],
       "invalid or missing VERIFY_CONTAINER_IMAGE_ID"},
      {"immutable identity drift", [{"TEST_DOCKER_IMAGE_ID", other_image_id}],
       "Docker image identity changed"},
      {"tag drift", [{"TEST_DOCKER_TAG_IMAGE_ID", other_image_id}], "Docker image tag changed"},
      {"revision drift", [{"TEST_DOCKER_REVISION", String.duplicate("e", 40)}],
       "container revision is not the tested commit"},
      {"inspect failure", [{"TEST_DOCKER_FAIL", "true"}], "Docker image ID inspection failed"}
    ]

    try do
      for {name, overrides, expected_error} <- cases do
        out =
          Path.join(
            System.tmp_dir!(),
            "receipt-image-#{System.unique_integer([:positive])}.json"
          )

        try do
          File.write!(out, "stale receipt\n")

          env =
            base_env
            |> Map.new()
            |> Map.merge(Map.new(overrides))
            |> Map.put("VERIFY_RECEIPT_PATH", out)
            |> Map.to_list()

          {output, status} =
            System.cmd("mix", ["run", @writer], env: env, stderr_to_stdout: true)

          assert status != 0, "#{name} unexpectedly wrote a receipt"
          assert output =~ expected_error, "#{name} returned: #{output}"
          refute File.exists?(out), "#{name} left a stale receipt behind"
        after
          File.rm(out)
        end
      end
    after
      File.rm(log)
      File.rm_rf(docker_dir)
    end
  end

  test "the skip scanner fails closed on a planted tag and passes the real tree" do
    dir = Path.join(System.tmp_dir!(), "offline-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    planted = Path.join(dir, "planted_test.exs")
    tag = "@" <> "tag :skip"
    File.write!(planted, "defmodule PlantedSkip do\n  #{tag}\n  test \"x\", do: :ok\nend\n")

    try do
      {output, status} =
        System.cmd(@forbid, [dir],
          env: [{"PATH", System.get_env("PATH", "")}],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "skip/only tags are forbidden"

      {clean, zero} =
        System.cmd(@forbid, ["test"],
          env: [{"PATH", System.get_env("PATH", "")}],
          stderr_to_stdout: true
        )

      assert zero == 0, clean
    after
      File.rm_rf(dir)
    end
  end

  defp fake_docker_dir do
    dir = Path.join(System.tmp_dir!(), "offline-docker-#{System.unique_integer([:positive])}")
    docker = Path.join(dir, "docker")
    File.mkdir_p!(dir)

    File.write!(docker, """
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ "${TEST_DOCKER_FAIL:-false}" == true ]]; then
      exit 1
    fi

    [[ $# -eq 5 && "$1" == image && "$2" == inspect && "$3" == --format ]]
    format=$4
    reference=$5

    if [[ "$format" == '{{.Id}}' ]]; then
      if [[ "$reference" == "${VERIFY_CONTAINER_IMAGE_TAG:-}" ]]; then
        printf '%s\n' "${TEST_DOCKER_TAG_IMAGE_ID:?}"
      else
        printf '%s\n' "${TEST_DOCKER_IMAGE_ID:?}"
      fi
    elif [[ "$format" == *org.opencontainers.image.revision* ]]; then
      printf '%s\n' "${TEST_DOCKER_REVISION:?}"
    else
      exit 64
    fi
    """)

    File.chmod!(docker, 0o755)
    dir
  end

  defp git_sha do
    {sha, 0} =
      System.cmd("git", ["rev-parse", "HEAD"],
        env: [{"SAC_WS_API_KEY", nil}, {"PUMBLE_API_KEY", nil}]
      )

    String.trim(sha)
  end
end
