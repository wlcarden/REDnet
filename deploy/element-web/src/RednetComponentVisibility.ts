/*
REDnet soft-fork — hide the native room/space creation UI.

Room and space creation is locked SERVER-SIDE to the system accounts
(deploy/synapse-modules/rednet_room_policy.py): members request rooms via
`!gov request` and organizers create them via `!gov room` / `!gov space` in the
Gov Bot DM. Nobody uses Element's native creator. But stock Element still renders
Create Room / Create Space / Explore buttons, which now dead-end in a 403 — and
the space-creation flow spins rather than surfacing the error. Hide them so the
UI matches the policy instead of offering a broken affordance.

Wired via customisations.json, which overrides src/customisations/ComponentVisibility.ts.
Pinned to Element v1.11.86 — re-verify the enum + customisation path on upgrade,
like integration.patch (README).
*/
import { UIComponent } from "../settings/UIFeature";

// Sentinel: a distinctive module-load side effect the Dockerfile greps for in the
// built bundle, to prove this customisation was actually wired (mirrors the
// onboarding-sentinel pattern). Also a runtime breadcrumb in the browser console.
// eslint-disable-next-line no-console
console.info(
  "REDnet: native room/space creation hidden — use !gov (rednet_room_policy)",
);

const HIDDEN: Set<UIComponent> = new Set([
  UIComponent.CreateRooms, // "+" room creation
  UIComponent.CreateSpaces, // create-space button + dialog
  UIComponent.ExploreRooms, // the room directory is intentionally empty (rooms unlisted)
]);

function shouldShowComponent(component: UIComponent): boolean {
  return !HIDDEN.has(component);
}

export interface IComponentVisibilityCustomisations {
  shouldShowComponent?: typeof shouldShowComponent;
}

export const ComponentVisibilityCustomisations: IComponentVisibilityCustomisations =
  {
    shouldShowComponent,
  };
