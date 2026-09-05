defmodule PumbleAutomation.Security.ThreatClosureTest do
  @moduledoc """
  Current source checklist: every supported threat is mapped, production debug
  surfaces stay off, and the dangerous-pattern search stays empty.
  """

  use ExUnit.Case, async: true

  import PumbleAutomation.TenantAssertions, only: [assert_web_modules_omit_repo: 0]

  @threats [
    "Cross-workspace access",
    "OAuth CSRF",
    "Forged callback",
    "Replay",
    "Token leak",
    "SSRF",
    "Workflow bomb",
    "Recursion loop",
    "Job flood",
    "Approval spoof",
    "Scope escalation",
    "Log leakage",
    "Stored content injection",
    "Admin abuse",
    "Dependency compromise"
  ]

  @forbidden_lib [
    {~r/\bbinary_to_term\s*\(/, "binary_to_term on untrusted data"},
    {~r/String\.to_atom\s*\(/, "dynamic atom creation"},
    {~r/System\.cmd\s*\(/, "shell execution"},
    {~r/:os\.cmd\s*\(/, "shell execution"},
    {~r/Code\.eval/, "eval"},
    {~r/verify:\s*:verify_none/, "TLS verification disable"},
    {~r/verify:\s*:none\b/, "TLS verification disable"}
  ]

  @secret_env_keys ~w(
    DATABASE_URL SECRET_KEY_BASE SESSION_SIGNING_SALT
    PUMBLE_CLIENT_SECRET PUMBLE_SIGNING_SECRET PUMBLE_APP_KEY
    ENCRYPTION_KEY
  )

  describe "threat table" do
    test "every current threat has an enforcement boundary, proof, evidence, and residual risk" do
      path = Path.expand("../../docs/security/threat_model.md", __DIR__)
      body = File.read!(path)

      assert body =~ "Implementation"
      assert body =~ "Offline proof"
      assert body =~ "Residual risk"

      Enum.each(@threats, fn threat ->
        assert body =~ threat, "threat_model.md is missing #{inspect(threat)}"
      end)
    end

    test "the review artifact names an exact verified checkpoint" do
      path = Path.expand("../../docs/security/review_results.md", __DIR__)
      body = File.read!(path)

      assert body =~ "The exact clean candidate named by `tmp/offline_acceptance_receipt.json`"
      assert body =~ "all 19 local gates"
      assert body =~ "Unresolved critical:** none"
      assert body =~ "Unresolved high:** none"
      assert body =~ "mix hex.audit"
      assert body =~ "mix sobelow --config"
      assert body =~ "gitleaks"
    end
  end

  describe "dangerous-pattern search" do
    test "lib does not use the forbidden primitives" do
      root = Path.expand("../../lib", __DIR__)

      for path <- Path.wildcard(Path.join(root, "**/*.ex")),
          source = File.read!(path),
          {regex, label} <- @forbidden_lib do
        refute Regex.match?(regex, source),
               "#{Path.relative_to_cwd(path)} matches #{label}"
      end
    end

    test "templates do not call Phoenix.HTML.raw" do
      root = Path.expand("../../lib", __DIR__)

      for path <- Path.wildcard(Path.join(root, "**/*.{ex,heex}")) do
        source = File.read!(path)
        refute source =~ "Phoenix.HTML.raw", Path.relative_to_cwd(path)
      end
    end

    test "no web module names PumbleAutomation.Repo" do
      assert_web_modules_omit_repo()
    end

    test "Repo.query is only the health SELECT 1 probe" do
      root = Path.expand("../../lib", __DIR__)
      probe = Path.expand("../../lib/pumble_automation/health/repo_probe.ex", __DIR__)

      offenders =
        root
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          File.read!(path) =~ ~r/Repo\.query\s*\(/ and path != probe
        end)

      assert offenders == []
      assert File.read!(probe) =~ "SELECT 1"
    end

    test "outbound TLS owners pin verify_peer" do
      files = [
        "lib/pumble_automation/connections/safe_http/transport.ex",
        "lib/pumble_automation/pumble/client/transport.ex",
        "lib/pumble_automation/pumble/oauth_client.ex"
      ]

      Enum.each(files, fn relative ->
        source = File.read!(Path.expand("../../#{relative}", __DIR__))
        assert source =~ "verify: :verify_peer", relative
        refute source =~ "verify: :verify_none", relative
      end)
    end
  end

  describe "production debug surfaces" do
    test "prod config disables dashboard routes and forces SSL" do
      source = File.read!(Path.expand("../../config/prod.exs", __DIR__))

      assert source =~ "dev_routes, false"
      assert source =~ "force_ssl:"
      refute Application.get_env(:pumble_automation, :dev_routes)

      paths = Enum.map(PumbleAutomationWeb.Router.__routes__(), & &1.path)
      refute Enum.any?(paths, &String.contains?(&1, "dashboard"))
      refute Enum.any?(paths, &String.starts_with?(&1, "/dev"))
    end
  end

  describe "release config secret scan" do
    test "runtime production config does not embed secret_key_base" do
      source = File.read!(Path.expand("../../config/runtime.exs", __DIR__))

      refute source =~ ~r/secret_key_base:\s*"/
      assert source =~ "settings.secret_key_base"
    end

    test "env example leaves secret-class values empty" do
      source = File.read!(Path.expand("../../.env.example", __DIR__))

      Enum.each(@secret_env_keys, fn key ->
        assert source =~ ~r/^#{key}=$/m, "#{key} must be present and empty in .env.example"
      end)
    end
  end

  describe "dependency pins" do
    test "mix.lock pins the audited hackney override" do
      lock = File.read!(Path.expand("../../mix.lock", __DIR__))
      assert lock =~ ~s("hackney": {:hex, :hackney, "4.0.3")
      assert lock =~ ~s("tzdata": {:hex, :tzdata, "1.1.4")
    end

    test "gitleaks config extends the default rules" do
      source = File.read!(Path.expand("../../.gitleaks.toml", __DIR__))
      assert source =~ "useDefault = true"
      assert source =~ "config/(dev|test)"
      assert source =~ "http_test_server"
      assert source =~ "(^|/)tmp/"
    end
  end
end
