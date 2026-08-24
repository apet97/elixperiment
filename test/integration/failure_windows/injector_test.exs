defmodule PumbleAutomation.Integration.FailureInjectorTest do
  @moduledoc """
  The injector cannot fire unless armed, and it is not a production module.
  """

  use PumbleAutomation.DataCase, async: false

  alias PumbleAutomation.FailureInjection
  alias PumbleAutomation.FailureInjector

  setup do
    FailureInjector.disarm()
    on_exit(fn -> FailureInjector.disarm() end)
    :ok
  end

  test "an unarmed boundary is a no-op" do
    assert :ok = FailureInjection.crash(:before_claim_commit)
    assert :ok = FailureInjector.maybe_crash(:before_claim_commit)
    assert {:ok, :ok} = FailureInjection.crash_if_ambiguous({:ok, :ok})
  end

  test "every named crash window can be armed" do
    Enum.each(FailureInjector.boundaries(), fn boundary ->
      assert :ok = FailureInjector.arm(boundary, fn -> :fired end)
      assert :fired = FailureInjector.maybe_crash(boundary)
      assert :ok = FailureInjector.maybe_crash(boundary)
    end)
  end

  test "skip waits for a later hit at the same boundary" do
    assert :ok = FailureInjector.arm(:before_finalize, fn -> :second end, skip: 1)
    assert :ok = FailureInjector.maybe_crash(:before_finalize)
    assert :second = FailureInjector.maybe_crash(:before_finalize)
  end

  test "the injector lives only on the test compile path" do
    mixfile = File.read!(Path.join(File.cwd!(), "mix.exs"))
    assert mixfile =~ "elixirc_paths(:test)"
    assert mixfile =~ ~S["lib", "test/support"]
    assert mixfile =~ "elixirc_paths(_)"
    assert mixfile =~ ~S["lib"]
    refute File.exists?(Path.join(File.cwd!(), "lib/pumble_automation/failure_injector.ex"))
    assert File.exists?(Path.join(File.cwd!(), "test/support/failure_injector.ex"))
  end
end
