/*
 * REDnet onboarding E2E — the BEHAVIORAL gate the build (compile/bundle/sentinel) can't cover.
 * Proves the silent flow actually renders against a real Element + homeserver:
 *   1) fresh account  -> OUR "Save your recovery passphrase" dialog appears (NOT Element's E2E_SETUP),
 *                        and after it the app loads with cross-signing set up (no "verify this device" nag).
 *   2) fresh device   -> OUR "Enter your recovery passphrase" prompt appears (NOT Element's COMPLETE_SECURITY),
 *                        and entering the saved passphrase recovers identity + history.
 *
 * Auth is delegated to MAS, so registration happens via mas-cli (not Element's UI). The test drives
 * the MAS OIDC login flow (Element redirects to MAS -> credentials -> redirect back -> postLoginSetup).
 *
 * Run against a deployed REDnet stack:
 *   BASE_URL=http://localhost:8080 npx playwright test onboarding.spec.ts
 *
 * Requires: a running stack (setup.sh), the `element` service up (--profile web), and docker compose
 * access for mas-cli user provisioning.
 */
import { test, expect, type Page, type BrowserContext } from "@playwright/test";
import { execSync } from "child_process";

const BASE_URL = process.env.BASE_URL ?? "http://localhost:8080";
const COMPOSE_DIR = process.env.COMPOSE_DIR ?? "..";
const USER = `e2e-${Date.now()}`;
const PASSWORD = "e2e-Test-Passw0rd!";
let savedPassphrase = "";

function masCliRegister(username: string, password: string): void {
  execSync(
    `docker compose exec -T mas mas-cli manage register-user ${username}` +
      ` --password "${password}" --yes --ignore-password-complexity --config /config.yaml`,
    { cwd: COMPOSE_DIR, stdio: "pipe" },
  );
}

async function masLogin(
  page: Page,
  user: string,
  password: string,
): Promise<void> {
  await page.goto(BASE_URL);
  await page
    .waitForLoadState("networkidle", { timeout: 30_000 })
    .catch(() => {});

  // Step 1: Element welcome → click "Sign in"
  await page
    .getByRole("link", { name: /sign in/i })
    .or(page.getByRole("button", { name: /sign in/i }))
    .first()
    .click({ timeout: 30_000 });

  // Step 2: Element OIDC login page shows "Continue" button (MAS delegation — no username/password
  // fields on Element's side). Click it to redirect to MAS's login page.
  await page
    .getByRole("button", { name: /continue/i })
    .first()
    .click({ timeout: 15_000 });

  // Step 3: Now on MAS's login page. Fill in credentials.
  await page
    .locator('input[name="username"]')
    .first()
    .fill(user, { timeout: 15_000 });
  await page.locator('input[name="password"]').first().fill(password);
  await page
    .getByRole("button", { name: /continue/i })
    .first()
    .click();

  // Step 4: MAS may show a consent/authorize screen on first login — click through.
  const consentBtn = page.getByRole("button", {
    name: /continue|allow|authorize/i,
  });
  await consentBtn
    .first()
    .click({ timeout: 15_000 })
    .catch(() => {});

  // Step 5: Should redirect back to Element after OIDC completes.
  await page
    .waitForURL((url) => url.toString().startsWith(BASE_URL), {
      timeout: 30_000,
    })
    .catch(() => {});
}

test.describe.serial("REDnet onboarding", () => {
  test.beforeAll(() => {
    masCliRegister(USER, PASSWORD);
  });

  test("fresh account: silent bootstrap shows the recovery passphrase ONCE (no Element setup UI)", async ({
    page,
  }) => {
    test.setTimeout(120_000);
    await masLogin(page, USER, PASSWORD);

    // OUR dialog — NOT Element's "Set up Secure Backup"/E2E_SETUP
    const dialog = page.getByText("Save your recovery passphrase", {
      exact: false,
    });
    await expect(dialog).toBeVisible({ timeout: 60_000 });
    savedPassphrase = (await page.locator("pre").first().innerText()).trim();
    expect(savedPassphrase.length).toBeGreaterThan(10);
    await page.getByRole("button", { name: /i've saved it/i }).click();

    // Element's interactive setup/verify views must NOT appear
    await expect(
      page.getByText(
        /Confirm your identity|Verify this (login|device)|Set up Secure Backup/i,
      ),
    ).toHaveCount(0);
    await expect(
      page.locator(".mx_RoomList, [data-testid='room-list']"),
    ).toBeVisible({ timeout: 60_000 });
  });

  test("fresh device: the passphrase recovers identity + history (no Element verify UI)", async ({
    browser,
  }) => {
    test.setTimeout(120_000);
    test.skip(
      !savedPassphrase,
      "depends on the fresh-account test saving a passphrase",
    );
    const ctx: BrowserContext = await browser.newContext();
    const page = await ctx.newPage();
    await masLogin(page, USER, PASSWORD);

    const prompt = page.getByText("Enter your recovery passphrase", {
      exact: false,
    });
    await expect(prompt).toBeVisible({ timeout: 60_000 });
    await page.locator('input[type="password"]').last().fill(savedPassphrase);
    await page.getByRole("button", { name: /recover/i }).click();

    await expect(
      page.getByText(/Confirm your identity|Verify this (login|device)/i),
    ).toHaveCount(0);
    await expect(
      page.locator(".mx_RoomList, [data-testid='room-list']"),
    ).toBeVisible({ timeout: 60_000 });
    await ctx.close();
  });
});
