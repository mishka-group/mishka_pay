MishkaPay.Test.setup!()
# Stripe registers a moment after boot: the first test must not come first.
MishkaPay.Test.await_plugin!(MishkaPay.Providers.Stripe)

# Every module is loaded before the first test, as a release loads them at boot: a test that
# waits on work (render_async, assert_receive) then waits on the work, not on code read from
# disk the first time some test reaches it.
for {app, _description, _version} <- Application.loaded_applications() do
  app |> Application.spec(:modules) |> List.wrap() |> Code.ensure_all_loaded()
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Shop.Repo, :manual)
