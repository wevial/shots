import type { AppContext } from "../native.ts";

export interface ClassifyInput {
  imagePath: string;
  ocrText: string;
  appContext: AppContext | null;
  captureType: string | null;
  dimensions: { width: number; height: number } | null;
  categories: string[];
  categoryHints?: Record<string, string>;
}

export interface ClassifyResult {
  category: string;
  tags: string[];
  title: string;
  confidence: number;
}

export type ClassifyOutcome =
  | { ok: true; result: ClassifyResult; detail?: string }
  | { ok: false; kind: "unavailable" | "error" | "timeout" | "invalid"; message: string };

export interface Backend {
  name: string;
  /** Cloud backends send content off the machine and obey allowCloud / the denylist. */
  cloud: boolean;
  classify(input: ClassifyInput): Promise<ClassifyOutcome>;
}
