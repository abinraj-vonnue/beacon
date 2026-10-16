# beacon

## Worker

Build and start the worker from the repository root:

```sh
npm run build:worker
npm start --workspace=worker
```

The worker loads `DATABASE_URL` from the repository `.env` file when started
through the workspace command. `WEBHOOK_URL` is optional.

The worker claims one monitor at a time with a 90-second lease. Monitor checks
time out after at most 60 seconds. If result processing fails, the worker moves
the monitor's next check to five seconds later so it can retry promptly.

Incident webhooks are best effort. They are sent after the database transaction
commits; delivery failures and unsuccessful HTTP responses are logged and are
not retried. Durable webhook delivery is deferred to a later reliability
improvement.

Run the worker tests with `npm test`.
