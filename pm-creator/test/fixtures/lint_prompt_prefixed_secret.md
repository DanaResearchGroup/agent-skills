# Dispatch: rotate CI credentials

## Prompt (paste below this line)

Update the CI environment in `/srv/example-app/.env`.

Set the following (these are OBVIOUSLY FAKE placeholder values for the test
fixture, not real credentials):

    GH_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    GITHUB_PAT=github_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    SLACK_BOT_TOKEN=xoxb-FAKE-FAKE-FAKE-xxxxxxxxxxxxxxxxxxxxxxxx
    api_key: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

Restart the service with `systemctl restart example-app-ci` afterward.
