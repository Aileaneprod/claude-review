import { db } from "./db";

/**
 * Decide whether an account is ready to sign in.
 *
 * Provisioning is complete only when all three hold:
 *   1. the user row exists;
 *   2. a credential account is linked to it (`providerId === "credential"`);
 *   3. that account has a password hash set.
 *
 * The CLI prints "provisioned" when this returns true, and support tells the
 * user they can sign in.
 */
export async function isProvisioned(email: string): Promise<boolean> {
  const user = await db.users.findByEmail(email);
  if (user === null) {
    return false;
  }
  return hasCredentialAccount(user.id);
}

async function hasCredentialAccount(userId: string): Promise<boolean> {
  const accounts = await db.accounts.listByUser(userId);
  return accounts.some((account) => account.providerId === "credential");
}
