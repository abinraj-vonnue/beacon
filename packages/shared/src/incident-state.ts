export type IncidentState = {
  consecutiveFailures: number;
  incidentOpen: boolean;
};
export type IncidentAction = "open" | "close" | "none";

export type IncidentTransition = {
  state: IncidentState;
  action: IncidentAction;
};
const FAILURE_THRESHOLD = 3;

export function nextState(
  previous: IncidentState,
  ok: boolean,
): IncidentTransition {
  if (ok) {
    return {
      state: {
        consecutiveFailures: 0,
        incidentOpen: false,
      },
      action: previous.incidentOpen ? "close" : "none",
    };
  }
  const consecutiveFailures = previous.consecutiveFailures + 1;
  const shouldOpen =
    !previous.incidentOpen && consecutiveFailures >= FAILURE_THRESHOLD;

  return {
    state: {
      consecutiveFailures,
      incidentOpen: previous.incidentOpen || shouldOpen,
    },
    action: shouldOpen ? "open" : "none",
  };
}
