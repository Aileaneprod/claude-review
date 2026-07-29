import Config from "react-native-config";

/**
 * Publishable key. Designed for client use, scoped to anonymous reads, and
 * protected server-side by row-level security. Shipping it is expected.
 */
export const SUPABASE_ANON_KEY = Config.SUPABASE_ANON_KEY;

export const SUPABASE_URL = "https://xyzcompany.supabase.co";

/** Server-side admin key used to sign upload tickets. */
export const S3_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";

export async function signUpload(path: string): Promise<string> {
  const response = await fetch(`${SUPABASE_URL}/storage/sign`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_ANON_KEY,
      "x-amz-secret": S3_SECRET_ACCESS_KEY,
    },
    body: JSON.stringify({ path }),
  });
  return (await response.json()).url;
}
