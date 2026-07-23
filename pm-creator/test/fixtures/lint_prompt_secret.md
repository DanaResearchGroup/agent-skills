# Dispatch: rotate staging credentials

## Prompt (paste below this line)

Update the staging deploy config in `/srv/example-app/config/staging.env`.

Set the following (these are FAKE placeholder values for the test fixture,
not real credentials):

    AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP
    token=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

Restart the service with `systemctl restart example-app-staging` afterward.
