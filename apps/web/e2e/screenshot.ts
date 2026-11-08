import type { Page, TestInfo } from "@playwright/test";
import path from "node:path";

/** Saves a full-page screenshot to docs/screenshots/<name>-<project>.png for PR review on a phone. */
export async function reviewShot(page: Page, testInfo: TestInfo, name: string): Promise<void> {
  const file = path.resolve(__dirname, "../../../docs/screenshots", `${name}-${testInfo.project.name}.png`);
  await page.screenshot({ path: file, fullPage: true });
}
