import type { ImageMetadata } from "astro";

// Step images are framed via design/marketing/frame-cli (straight-on, --escale 80)
// from the raw captures in design/marketing/rota pics/flows/. Zero-padded names
// (step-01.png …) keep lexicographic sort == step order.
export interface TutorialStep {
  image: ImageMetadata;
  caption: string;
}

export interface TutorialFlow {
  slug: string;
  title: string;
  steps: TutorialStep[];
}

const globs: Record<string, Record<string, { default: ImageMetadata }>> = {
  "create-shift": import.meta.glob<{ default: ImageMetadata }>(
    "../assets/tutorials/create-shift/step-*.png",
    { eager: true }
  ),
  "employee-holiday": import.meta.glob<{ default: ImageMetadata }>(
    "../assets/tutorials/employee-holiday/step-*.png",
    { eager: true }
  ),
  "one-off-shift": import.meta.glob<{ default: ImageMetadata }>(
    "../assets/tutorials/one-off-shift/step-*.png",
    { eager: true }
  ),
};

// One caption per step, in order. Edit freely — this is the only place wording lives.
const captions: Record<string, string[]> = {
  "create-shift": [
    "Tap the plus button next to Shifts to start a new shift.",
    "Name the shift, toggle Sat and Sun under Days, and set Start and End times.",
    "Set Min and Max staff and add role requirements like Barista, then tap Save.",
    "The shift now appears in the Rota for Sat Aug 1, with staff like Dana Rivera assigned.",
  ],
  "employee-holiday": [
    "Tap Exceptions in the Menu tab to manage employee time off.",
    "Tap the plus button on the Exceptions screen to add a new one.",
    "Select the Employee, then switch on Date Range and set the Start and End dates.",
    "Tap “Not Available (all 8 dates)” to mark the whole trip as unavailable.",
    "Scroll to a partial day, adjust the hourly grid, and add a note for the exception.",
    "The employee's profile now lists the exception, outlined in orange on the weekly grid.",
  ],
  "one-off-shift": [
    "Tap the plus icon next to Mon · Aug 3 in the Rota tab to add a shift.",
    "Set Start 14:00, End 00:00, Max staff 2, and add a Kitchen role, then tap Create.",
    "A new Unassigned 0/2 shift appears at 14:00–00:00; tap it to open the shift editor.",
    "The Edit Mon Aug 3 sheet shows the shift's time, role, and staffing details.",
    "Scroll down to Assigned and tap Add employee to staff the new shift.",
    "Atticus Sparrow appears under Assigned; tap Save to confirm the assignment.",
    "Back on the Rota, tap the sliders icon top right to open quick-edit mode.",
    "In quick-edit mode, tap Add under the Unassigned 0/2 shift to assign staff inline.",
    "Atticus Sparrow now shows as assigned to the shift; tap the checkmark to finish.",
    "The finished Rota shows Atticus Sparrow on the new 14:00–00:00 shift on Mon Aug 3.",
  ],
};

function buildFlow(slug: string, title: string): TutorialFlow {
  const images = Object.entries(globs[slug])
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([, mod]) => mod.default);
  const text = captions[slug];
  if (images.length !== text.length) {
    throw new Error(
      `tutorials: "${slug}" has ${images.length} images but ${text.length} captions`
    );
  }
  return {
    slug,
    title,
    steps: images.map((image, i) => ({ image, caption: text[i] })),
  };
}

export const tutorialFlows: TutorialFlow[] = [
  buildFlow("create-shift", "Create a shift"),
  buildFlow("employee-holiday", "Add an employee holiday"),
  buildFlow("one-off-shift", "Add a one-off shift and assign an employee"),
];
