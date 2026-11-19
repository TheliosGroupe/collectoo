import { defineConfig, devices } from "@playwright/test";

const port = Number(process.env.WEB_PORT ?? 3100);

/**
 * M2c-6b-3a-2 (plan m2c-6b-3 §3.7): `switch-on.spec.ts` turns the cancellation after download on for its own run, on
 * the local stack only. It is never run by the desktop and mobile projects; its one project runs after both, as one
 * serial test (never two flips at once), which opens a desktop and a mobile context itself and saves its screenshots
 * under the desktop and mobile names.
 */
const SWITCH_ON = /switch-on\.spec\.ts$/;

export default defineConfig({
  testDir: "e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: process.env.CI ? "github" : "list",
  use: { baseURL: `http://127.0.0.1:${port}`, trace: "off" },
  projects: [
    { name: "desktop", use: { ...devices["Desktop Chrome"] }, testIgnore: SWITCH_ON },
    { name: "mobile", use: { ...devices["Pixel 7"] }, testIgnore: SWITCH_ON },
    { name: "switch-on", use: { ...devices["Desktop Chrome"] }, testMatch: SWITCH_ON, dependencies: ["desktop", "mobile"] },
  ],
  webServer: {
    command: `npm run start -- --port ${port}`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
