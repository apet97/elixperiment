defmodule PumbleAutomation.Installations.PolicyTest do
  @moduledoc """
  The role matrix, as a table.

  The matrix is written out capability by capability rather than derived from
  the module under test, because a test that computes the expected answer the
  same way the code does agrees with any bug the code has. Every capability the
  policy defines must appear in the table, which is itself asserted, so adding a
  capability without deciding who holds it fails here.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Installations.Policy
  alias PumbleAutomation.Scope

  # role => the capabilities that role holds, and only those.
  @matrix %{
    "viewer" => ~w(read_workflows read_executions)a,
    "editor" =>
      ~w(read_workflows read_executions manage_workflows test_workflows activate_workflows
         retry_execution cancel_execution)a,
    "owner" =>
      ~w(read_workflows read_executions manage_workflows test_workflows activate_workflows
         retry_execution cancel_execution manage_members manage_credentials manage_secrets
         destructive_lifecycle resolve_uncertainty)a
  }

  describe "the role matrix" do
    test "covers every capability the policy defines" do
      assert Enum.sort(@matrix["owner"]) == Policy.capabilities()
    end

    for {role, allowed} <- @matrix do
      test "#{role} holds exactly the capabilities the matrix gives it" do
        role = unquote(role)
        allowed = unquote(allowed)

        for capability <- Policy.capabilities() do
          expected = capability in allowed

          assert Policy.can?(role, capability) == expected,
                 "#{role} #{if expected, do: "should", else: "should not"} hold #{capability}"

          assert Policy.can?(scope(role), capability) == expected
        end
      end
    end

    test "the roles nest: viewer is inside editor is inside owner" do
      assert MapSet.subset?(
               set(Policy.capabilities("viewer")),
               set(Policy.capabilities("editor"))
             )

      assert MapSet.subset?(set(Policy.capabilities("editor")), set(Policy.capabilities("owner")))
    end

    test "an unknown role and an unknown capability both deny" do
      refute Policy.can?("admin", :read_workflows)
      refute Policy.can?("owner", :become_root)
      refute Policy.can?(nil, :read_workflows)
      assert Policy.capabilities("admin") == []
    end
  end

  describe "authorize/2" do
    test "answers :ok for a capability the role holds" do
      assert Policy.authorize(scope("editor"), :manage_workflows) == :ok
    end

    test "answers a permission error naming what was required" do
      assert {:error, error} = Policy.authorize(scope("editor"), :manage_secrets)
      assert error.class == :permission
      assert error.code == :capability_denied
      assert error.details.required == :manage_secrets
    end
  end

  describe "authorize_tenant/2" do
    test "answers :ok for the scope's own installation" do
      scope = scope("viewer")
      assert Policy.authorize_tenant(scope, scope.installation_id) == :ok
    end

    test "another tenant's resource is indistinguishable from one that does not exist" do
      scope = scope("owner")

      {:error, other_tenant} = Policy.authorize_tenant(scope, Ecto.UUID.generate())
      missing = Policy.not_found()

      assert other_tenant.class == :not_found
      assert other_tenant.class == missing.class
      assert other_tenant.code == missing.code
      assert other_tenant.message == missing.message
      assert other_tenant.details == missing.details
    end

    test "an owner of one workspace is not an owner of another" do
      scope = scope("owner")
      assert {:error, error} = Policy.authorize_tenant(scope, Ecto.UUID.generate())
      assert error.class == :not_found
    end
  end

  describe "the scope struct" do
    test "carries the tenant, the member, and the role" do
      scope = scope("editor")

      assert %Scope{role: "editor"} = scope
      assert is_binary(scope.installation_id)
      assert is_binary(scope.member_id)
    end

    test "cannot be built without all three" do
      assert_raise ArgumentError, fn ->
        struct!(Scope, installation_id: Ecto.UUID.generate())
      end
    end
  end

  defp scope(role) do
    %Scope{
      installation_id: Ecto.UUID.generate(),
      member_id: Ecto.UUID.generate(),
      role: role
    }
  end

  defp set(capabilities), do: MapSet.new(capabilities)
end
