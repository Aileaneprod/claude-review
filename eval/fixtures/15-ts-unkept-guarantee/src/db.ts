export interface User {
  id: string;
  email: string;
}

export interface Account {
  id: string;
  userId: string;
  providerId: "credential" | "google" | "github";
  /** Set when the user chose a password; null until then. */
  passwordHash: string | null;
}

export interface Db {
  users: { findByEmail(email: string): Promise<User | null> };
  accounts: { listByUser(userId: string): Promise<Account[]> };
}

export declare const db: Db;
