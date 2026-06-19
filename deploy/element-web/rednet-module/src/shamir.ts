/**
 * Shamir M-of-N secret sharing for Phase-2 recovery escrow.
 * Wraps shamir-secret-sharing (Privy, Cure53+Zellic audited, GF(2^8), zero deps).
 */
import { split, combine } from "shamir-secret-sharing";

export async function shamirSplit(
  secret: Uint8Array,
  totalShares: number,
  threshold: number,
): Promise<Uint8Array[]> {
  return split(secret, totalShares, threshold);
}

export async function shamirCombine(shares: Uint8Array[]): Promise<Uint8Array> {
  return combine(shares);
}

export async function shamirReshare(
  existingShares: Uint8Array[],
  newTotal: number,
  newThreshold: number,
): Promise<Uint8Array[]> {
  const secret = await combine(existingShares);
  return split(secret, newTotal, newThreshold);
}
