import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

// Support + privacy pages — the App Store Connect required URLs.
const docs = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/docs" }),
  schema: z.object({
    title: z.string(),
    description: z.string().max(160),
    lastUpdated: z.coerce.date(),
  }),
});

export const collections = { docs };
