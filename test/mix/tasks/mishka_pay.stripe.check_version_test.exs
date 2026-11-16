# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaPay.Stripe.CheckVersionTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.MishkaPay.Stripe.CheckVersion
  alias MishkaPay.Providers.Stripe

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  # Stripe's spec begins with its info block; only the first bytes are asked for.
  defp spec(version) do
    MishkaPay.Test.stub_http(fn conn ->
      send(self(), {:range, Plug.Conn.get_req_header(conn, "range")})

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(
        206,
        ~s({"openapi":"3.0.0","info":{"title":"Stripe API","contact":{"name":"Stripe"},"version":"#{version}","x-stripeReleasePhase":"ga"},"paths":{"/v1/acc)
      )
    end)
  end

  test "the pinned version passes, and reads only the head of the spec" do
    spec(Stripe.version())
    CheckVersion.run([])
    assert_received {:mix_shell, :info, [message]}
    assert message =~ Stripe.version()
    assert_received {:range, ["bytes=0-4095"]}
  end

  test "a newer Stripe version fails the task and names both versions" do
    spec("2027-01-27.fennel")
    error = assert_raise Mix.Error, fn -> CheckVersion.run([]) end
    assert error.message =~ "2027-01-27.fennel"
    assert error.message =~ Stripe.version()
  end

  test "a spec it cannot read fails the task" do
    MishkaPay.Test.stub_http(&Plug.Conn.send_resp(&1, 404, "Not Found"))
    assert_raise Mix.Error, ~r/could not be read/, fn -> CheckVersion.run([]) end
  end
end
