import { useCachedPromise } from "@raycast/utils";
import { loadSessions } from "./session";

/** Shared session loader with cached-then-revalidate behavior for every command. */
export function useSessions() {
  return useCachedPromise(loadSessions, [], { keepPreviousData: true });
}
