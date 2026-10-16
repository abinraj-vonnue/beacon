import assert from "node:assert/strict";
import test from "node:test";
import { nextState } from "@beacon/shared";

test("opens only on the third consecutive failure and does not reopen an open incident", () => {
  const afterFirstFailure = nextState(
    { consecutiveFailures: 0, incidentOpen: false },
    false,
  );
  const afterSecondFailure = nextState(afterFirstFailure.state, false);
  const afterThirdFailure = nextState(afterSecondFailure.state, false);
  const whileStillOpen = nextState(afterThirdFailure.state, false);

  assert.equal(afterFirstFailure.action, "none");
  assert.equal(afterSecondFailure.action, "none");
  assert.equal(afterThirdFailure.action, "open");
  assert.equal(whileStillOpen.action, "none");
});

test("resolves an open incident after a successful check", () => {
  assert.deepEqual(
    nextState({ consecutiveFailures: 4, incidentOpen: true }, true),
    {
      state: { consecutiveFailures: 0, incidentOpen: false },
      action: "close",
    },
  );
});
