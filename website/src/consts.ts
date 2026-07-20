export const APP_NAME = "autorota";
export const STORE_NAME = "Rota";
export const EMAIL = "fongo02@proton.me";
export const PERSONAL_SITE = "https://fongo.uk";

// Set to the App Store product URL at launch; null renders the "coming soon" pill.
export const APP_STORE_URL: string | null = null;

export const TAGLINE = "The week's rota, built in a tap.";
export const SUBLINE =
  "autorota turns your team's availability into a fair, editable schedule you can export and share. No accounts, no tracking, no fuss.";

// import.meta.env.BASE_URL is '/autorota'; normalize so href('/support') is safe either way.
const BASE = import.meta.env.BASE_URL.replace(/\/$/, "");
export const href = (path: string) => `${BASE}${path === "/" ? "/" : path}`;
